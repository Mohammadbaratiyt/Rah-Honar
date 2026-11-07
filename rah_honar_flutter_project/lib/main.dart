
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import 'package:flutter_timezone/flutter_timezone.dart';

final notifications = FlutterLocalNotificationsPlugin();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  tzdata.initializeTimeZones();
  try { final zone = await FlutterTimezone.getLocalTimezone(); tz.setLocalLocation(tz.getLocation(zone.identifier)); } catch (_) {}
  const android = AndroidInitializationSettings('@mipmap/ic_launcher');
  const settings = InitializationSettings(android: android);
  await notifications.initialize(settings);
  runApp(const RahHonarApp());
}

class RahHonarApp extends StatelessWidget {
  const RahHonarApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'راه هنر',
    theme: ThemeData(useMaterial3: true, colorSchemeSeed: const Color(0xff3e9cff), brightness: Brightness.dark),
    home: const AppHome(),
  );
}

class AppHome extends StatefulWidget {
  const AppHome({super.key});
  @override
  State<AppHome> createState() => _AppHomeState();
}

class _AppHomeState extends State<AppHome> {
  late final WebViewController controller;
  bool loading = true;
  bool permissionAsked = false;
  static const channel = MethodChannel('rah_honar/native');

  @override
  void initState() {
    super.initState();
    controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xff071426))
      ..addJavaScriptChannel('NativeApp', onMessageReceived: _onWebMessage)
      ..setNavigationDelegate(NavigationDelegate(
        onPageFinished: (_) async {
          if (mounted) setState(() => loading = false);
          if (!permissionAsked) {
            permissionAsked = true;
            final androidPlugin = notifications.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
            await androidPlugin?.requestNotificationsPermission();
            await controller.runJavaScript("if (typeof syncNativeNotifications === 'function') syncNativeNotifications();");
          }
        },
      ))
      ..loadFlutterAsset('assets/web/index.html');
  }

  Future<void> _onWebMessage(JavaScriptMessage message) async {
    try {
      final data = jsonDecode(message.message) as Map<String, dynamic>;
      if (data['type'] == 'requestNotifications') {
        final androidPlugin = notifications.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
        final granted = await androidPlugin?.requestNotificationsPermission() ?? false;
        await controller.runJavaScript("window.dispatchEvent(new CustomEvent('nativeNotificationPermission',{detail:{granted:$granted}}));");
      } else if (data['type'] == 'scheduleTasks') {
        await _scheduleTasks(data);
      }
    } catch (_) {}
  }

  Future<void> _scheduleTasks(Map<String, dynamic> data) async {
    final settings = (data['settings'] as Map?)?.cast<String, dynamic>() ?? {};
    if (settings['notify'] != true) {
      await notifications.cancelAll();
      return;
    }
    final tasks = (data['tasks'] as List?) ?? [];
    await notifications.cancelAll();
    final now = DateTime.now();
    final quietStart = _minutes(settings['quietStart']?.toString() ?? '23:00');
    final quietEnd = _minutes(settings['quietEnd']?.toString() ?? '07:00');
    for (final raw in tasks) {
      if (raw is! Map) continue;
      final t = raw.cast<String, dynamic>();
      final kind = (t['kind'] ?? '').toString();
      if (kind.contains('مرور') && settings['notifyReviews'] == false) continue;
      if (kind.contains('آزمون') && settings['notifyTests'] == false) continue;
      if (settings['notifyDaily'] == false && !kind.contains('مرور') && !kind.contains('آزمون')) continue;
      final date = DateTime.tryParse('${t['date']}T${t['start']}:00');
      if (date == null || !date.isAfter(now)) continue;
      final mins = date.hour * 60 + date.minute;
      final quiet = quietStart <= quietEnd ? (mins >= quietStart && mins < quietEnd) : (mins >= quietStart || mins < quietEnd);
      if (quiet) continue;
      final id = (t['id'].toString().hashCode & 0x7fffffff);
      await notifications.zonedSchedule(
        id,
        'وقت مطالعه است ✦',
        '${t['title'] ?? ''} · ${t['topic'] ?? ''}',
        tz.TZDateTime.from(date, tz.local),
        const NotificationDetails(android: AndroidNotificationDetails(
          'study_reminders', 'یادآوری‌های مطالعه',
          channelDescription: 'یادآوری جلسات برنامه راه هنر',
          importance: Importance.high, priority: Priority.high,
        )),
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        payload: t['id'].toString(),
      );
    }
  }

  int _minutes(String value) {
    final p = value.split(':');
    if (p.length != 2) return 0;
    return (int.tryParse(p[0]) ?? 0) * 60 + (int.tryParse(p[1]) ?? 0);
  }

  Future<bool> _back() async {
    if (await controller.canGoBack()) {
      await controller.goBack();
      return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false,
    onPopInvokedWithResult: (didPop, result) async {
      if (!didPop && await controller.canGoBack()) await controller.goBack();
      else if (!didPop && mounted) SystemNavigator.pop();
    },
    child: Scaffold(
      body: SafeArea(
        child: Stack(children: [
          WebViewWidget(controller: controller),
          if (loading) const Center(child: CircularProgressIndicator()),
        ]),
      ),
    ),
  );
}

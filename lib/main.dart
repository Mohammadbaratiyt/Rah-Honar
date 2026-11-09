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

  // flutter_timezone 4.x returns the timezone identifier as a String.
  try {
    final zone = await FlutterTimezone.getLocalTimezone();
    tz.setLocalLocation(tz.getLocation(zone));
  } catch (_) {
    // Keep the default timezone if device timezone detection fails.
  }

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
        theme: ThemeData(
          useMaterial3: true,
          colorSchemeSeed: const Color(0xff3e9cff),
          brightness: Brightness.dark,
        ),
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

  @override
  void initState() {
    super.initState();
    controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xff071426))
      ..addJavaScriptChannel('NativeApp', onMessageReceived: _onWebMessage)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) async {
            if (mounted) setState(() => loading = false);
            await controller.runJavaScript(
              "if (typeof syncNativeNotifications === 'function') syncNativeNotifications(); if (typeof refreshNotificationStatus === 'function') refreshNotificationStatus();",
            );
          },
        ),
      )
      ..loadFlutterAsset('assets/web/index.html');
  }

  Future<void> _onWebMessage(JavaScriptMessage message) async {
    try {
      final data = jsonDecode(message.message) as Map<String, dynamic>;
      if (data['type'] == 'requestNotifications') {
        final androidPlugin = notifications
            .resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin>();
        final granted =
            await androidPlugin?.requestNotificationsPermission() ?? false;
        await controller.runJavaScript(
          "window.dispatchEvent(new CustomEvent('nativeNotificationPermission',{detail:{granted:$granted}}));",
        );
      } else if (data['type'] == 'checkNotificationPermission') {
        final androidPlugin = notifications
            .resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin>();
        final enabled = await androidPlugin?.areNotificationsEnabled();
        final requested = data['requested'] == true;
        final status = enabled == true
            ? 'granted'
            : (requested ? 'denied' : 'notRequested');
        await controller.runJavaScript(
          "window.dispatchEvent(new CustomEvent('nativeNotificationStatus',{detail:{status:'$status'}}));",
        );
      } else if (data['type'] == 'scheduleTasks') {
        await _scheduleTasks(data);
      }
    } catch (_) {}
  }

  Future<void> _scheduleTasks(Map<String, dynamic> data) async {
    final settings =
        (data['settings'] as Map?)?.cast<String, dynamic>() ?? {};
    final mode = (settings['notifyMode'] ?? 'both').toString();
    if (mode == 'none') {
      await notifications.cancelAll();
      return;
    }

    final tasks = (data['tasks'] as List?) ?? [];
    await notifications.cancelAll();
    final now = DateTime.now();
    final quietStart =
        _minutes(settings['quietStart']?.toString() ?? '23:00');
    final quietEnd = _minutes(settings['quietEnd']?.toString() ?? '07:00');

    bool isQuiet(DateTime date) {
      final mins = date.hour * 60 + date.minute;
      return quietStart <= quietEnd
          ? (mins >= quietStart && mins < quietEnd)
          : (mins >= quietStart || mins < quietEnd);
    }

    for (final raw in tasks) {
      if (raw is! Map) continue;
      final task = raw.cast<String, dynamic>();
      final dateText = (task['date'] ?? '').toString();
      final startText = (task['start'] ?? '').toString();
      final endText = (task['end'] ?? '').toString();
      final title = (task['title'] ?? 'مطالعه').toString();
      final topic = (task['topic'] ?? '').toString();
      final baseId = _stableId('${task['id'] ?? '$dateText-$startText'}');

      final startDate = DateTime.tryParse('${dateText}T$startText:00');
      final endDate = DateTime.tryParse('${dateText}T$endText:00');
      if (startDate == null || endDate == null || !endDate.isAfter(startDate)) {
        continue;
      }

      if ((mode == 'both' || mode == 'start') &&
          startDate.isAfter(now) &&
          !isQuiet(startDate)) {
        await notifications.zonedSchedule(
          baseId,
          'شروع مطالعه ✦',
          '$title${topic.isNotEmpty ? ' · $topic' : ''}',
          tz.TZDateTime.from(startDate, tz.local),
          const NotificationDetails(
            android: AndroidNotificationDetails(
              'study_reminders_start',
              'شروع فعالیت‌های مطالعاتی',
              channelDescription: 'یادآوری زمان شروع هر فعالیت',
              importance: Importance.high,
              priority: Priority.high,
            ),
          ),
          androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
          uiLocalNotificationDateInterpretation:
              UILocalNotificationDateInterpretation.absoluteTime,
          payload: '${task['id']}:start',
        );
      }

      if ((mode == 'both' || mode == 'end') &&
          endDate.isAfter(now) &&
          !isQuiet(endDate)) {
        await notifications.zonedSchedule(
          (baseId ^ 0x40000000) & 0x7fffffff,
          'پایان فعالیت ✦',
          'زمان ${title} به پایان رسید. برای استراحت کوتاه یا فعالیت بعدی آماده شو.',
          tz.TZDateTime.from(endDate, tz.local),
          const NotificationDetails(
            android: AndroidNotificationDetails(
              'study_reminders_end',
              'پایان فعالیت‌های مطالعاتی',
              channelDescription: 'یادآوری زمان پایان هر فعالیت',
              importance: Importance.defaultImportance,
              priority: Priority.defaultPriority,
            ),
          ),
          androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
          uiLocalNotificationDateInterpretation:
              UILocalNotificationDateInterpretation.absoluteTime,
          payload: '${task['id']}:end',
        );
      }
    }
  }

  int _stableId(String value) {
    var hash = 0x811c9dc5;
    for (final unit in value.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0x7fffffff;
    }
    return hash & 0x3fffffff;
  }

  int _minutes(String value) {
    final p = value.split(':');
    if (p.length != 2) return 0;
    return (int.tryParse(p[0]) ?? 0) * 60 +
        (int.tryParse(p[1]) ?? 0);
  }

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, result) async {
          if (!didPop && await controller.canGoBack()) {
            await controller.goBack();
          } else if (!didPop && mounted) {
            SystemNavigator.pop();
          }
        },
        child: Scaffold(
          body: SafeArea(
            child: Stack(
              children: [
                WebViewWidget(controller: controller),
                if (loading)
                  const Center(child: CircularProgressIndicator()),
              ],
            ),
          ),
        ),
      );
}

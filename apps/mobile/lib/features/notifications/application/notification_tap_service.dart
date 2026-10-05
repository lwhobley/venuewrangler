import 'dart:io';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/services.dart';

/// Delivers a tapped push notification's payload to [start]'s `onTap` callback, per platform:
///   - iOS: from `PushNotificationsPlugin.swift` over the method channel — both a tap while
///     the app is running (live call) and one that arrived before Dart was listening, most
///     notably the tap that cold-launched the app ("consumePendingNotificationTap").
///   - Android: from `firebase_messaging` — `onMessageOpenedApp` for a running/backgrounded
///     app and `getInitialMessage()` for a cold launch. The `data` map is the same payload
///     `notifications-send` attaches on iOS (`kind` plus any custom fields).
class NotificationTapService {
  NotificationTapService({
    MethodChannel? iosChannel,
    bool Function()? isIOS,
    bool Function()? isAndroid,
    FirebaseMessaging? firebaseMessaging,
  })  : _channel = iosChannel ??
            const MethodChannel('com.venuewrangler.app/push_notifications'),
        _isIOS = isIOS ?? (() => Platform.isIOS),
        _isAndroid = isAndroid ?? (() => Platform.isAndroid),
        _firebaseMessagingOverride = firebaseMessaging;

  final MethodChannel _channel;
  final bool Function() _isIOS;
  final bool Function() _isAndroid;
  final FirebaseMessaging? _firebaseMessagingOverride;

  Future<void> start(void Function(Map<String, dynamic> data) onTap) async {
    if (_isIOS()) {
      await _startIOS(onTap);
    } else if (_isAndroid()) {
      await _startAndroid(onTap);
    }
  }

  Future<void> _startIOS(void Function(Map<String, dynamic> data) onTap) async {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onNotificationTapped') {
        onTap(_asStringKeyedMap(call.arguments));
      }
      return null;
    });

    try {
      final pending = await _channel
          .invokeMethod<Map<dynamic, dynamic>>('consumePendingNotificationTap');
      if (pending != null) onTap(_asStringKeyedMap(pending));
    } on PlatformException {
      // Native side rejected the call — nothing to route to.
    } on MissingPluginException {
      // Plugin not registered (e.g. a test host) — nothing to route to.
    }
  }

  Future<void> _startAndroid(
    void Function(Map<String, dynamic> data) onTap,
  ) async {
    try {
      final messaging =
          _firebaseMessagingOverride ?? FirebaseMessaging.instance;
      FirebaseMessaging.onMessageOpenedApp
          .listen((message) => onTap(_asStringKeyedMap(message.data)));
      final initial = await messaging.getInitialMessage();
      if (initial != null) onTap(_asStringKeyedMap(initial.data));
    } catch (_) {
      // Firebase isn't initialized (google-services.json missing/placeholder — see
      // app/bootstrap.dart); push taps simply won't route, which must never break startup.
    }
  }

  Map<String, dynamic> _asStringKeyedMap(Object? raw) {
    if (raw is Map) {
      return raw.map((key, value) => MapEntry(key.toString(), value));
    }
    return const {};
  }
}

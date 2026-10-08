import 'dart:async';
import 'dart:io';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
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
        _isIOS = isIOS ?? (() => !kIsWeb && Platform.isIOS),
        _isAndroid = isAndroid ?? (() => !kIsWeb && Platform.isAndroid),
        _firebaseMessagingOverride = firebaseMessaging;

  final MethodChannel _channel;
  final bool Function() _isIOS;
  final bool Function() _isAndroid;
  final FirebaseMessaging? _firebaseMessagingOverride;
  void Function(Map<String, dynamic> data)? _onTap;
  bool _started = false;
  StreamSubscription<RemoteMessage>? _androidOpenedSubscription;

  Future<void> start(void Function(Map<String, dynamic> data) onTap) async {
    _onTap = onTap;
    if (_started) return;
    _started = true;
    if (_isIOS()) {
      await _startIOS();
    } else if (_isAndroid()) {
      await _startAndroid();
    }
  }

  Future<void> _startIOS() async {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onNotificationTapped') {
        _onTap?.call(_asStringKeyedMap(call.arguments));
      }
      return null;
    });

    try {
      final pending = await _channel
          .invokeMethod<Map<dynamic, dynamic>>('consumePendingNotificationTap');
      if (pending != null) _onTap?.call(_asStringKeyedMap(pending));
    } on PlatformException {
      // Native side rejected the call — nothing to route to.
    } on MissingPluginException {
      // Plugin not registered (e.g. a test host) — nothing to route to.
    }
  }

  Future<void> _startAndroid() async {
    try {
      final messaging =
          _firebaseMessagingOverride ?? FirebaseMessaging.instance;
      _androidOpenedSubscription = FirebaseMessaging.onMessageOpenedApp
          .listen((message) => _onTap?.call(_asStringKeyedMap(message.data)));
      final initial = await messaging.getInitialMessage();
      if (initial != null) _onTap?.call(_asStringKeyedMap(initial.data));
    } catch (_) {
      // Firebase isn't initialized (google-services.json missing/placeholder — see
      // app/bootstrap.dart); push taps simply won't route, which must never break startup.
    }
  }

  Future<void> dispose() async {
    await _androidOpenedSubscription?.cancel();
    _channel.setMethodCallHandler(null);
    _onTap = null;
    _started = false;
  }

  Map<String, dynamic> _asStringKeyedMap(Object? raw) {
    if (raw is Map) {
      return raw.map((key, value) => MapEntry(key.toString(), value));
    }
    return const {};
  }
}

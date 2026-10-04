import 'dart:io';

import 'package:flutter/services.dart';

/// Bridges a tapped push notification's payload from `PushNotificationsPlugin.swift` to
/// [onTap] — covering a tap that arrives while the app is already running (via the method
/// channel's live call) and one that arrived before this was listening, most notably the tap
/// that cold-launched the app (via "consumePendingNotificationTap").
///
/// Android has no equivalent native-side wiring yet (see `features/pos/README.md`-style
/// documented-gap convention) — [start] is a no-op there rather than silently failing.
class NotificationTapService {
  NotificationTapService({
    MethodChannel? iosChannel,
    bool Function()? isIOS,
  })  : _channel = iosChannel ?? const MethodChannel('com.venuewrangler.app/push_notifications'),
        _isIOS = isIOS ?? (() => Platform.isIOS);

  final MethodChannel _channel;
  final bool Function() _isIOS;

  Future<void> start(void Function(Map<String, dynamic> data) onTap) async {
    if (!_isIOS()) return;

    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onNotificationTapped') {
        onTap(_asStringKeyedMap(call.arguments));
      }
      return null;
    });

    try {
      final pending = await _channel.invokeMethod<Map<dynamic, dynamic>>('consumePendingNotificationTap');
      if (pending != null) onTap(_asStringKeyedMap(pending));
    } on PlatformException {
      // Native side rejected the call — nothing to route to.
    } on MissingPluginException {
      // Plugin not registered (e.g. a test host) — nothing to route to.
    }
  }

  Map<String, dynamic> _asStringKeyedMap(Object? raw) {
    if (raw is Map) {
      return raw.map((key, value) => MapEntry(key.toString(), value));
    }
    return const {};
  }
}

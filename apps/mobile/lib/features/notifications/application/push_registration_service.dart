import 'dart:io';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/services.dart';

import '../data/notifications_repository.dart';

/// Acquires a push token and registers it with [NotificationsRepository.registerPushToken],
/// per-platform:
///   - iOS: native APNs via `PushNotificationsPlugin.swift` (a raw device token), matching the
///     native APNs dispatch branch in `supabase/functions/notifications-send/index.ts`. iOS is
///     deliberately not routed through Firebase — see that Swift file's header comment.
///   - Android: Firebase Cloud Messaging, the only push transport Android has here. Requires
///     `android/app/google-services.json` to exist and match the same Firebase project as the
///     server's `FIREBASE_SERVICE_ACCOUNT` secret — see
///     `android/app/google-services.json.MISSING.md` if that file hasn't been supplied yet.
///
/// Never throws: every failure path (permission denied, no token, missing platform config)
/// returns `false` so a caller can fire-and-forget this after sign-in/venue-switch without its
/// own try/catch, same posture as `AppAttestService.attestDevice()`.
class PushRegistrationService {
  PushRegistrationService({
    required NotificationsRepository repository,
    MethodChannel? iosChannel,
    bool Function()? isIOS,
    bool Function()? isAndroid,
    FirebaseMessaging? firebaseMessaging,
  })  : _repository = repository,
        _iosChannel = iosChannel ??
            const MethodChannel('com.venuewrangler.app/push_notifications'),
        _isIOS = isIOS ?? (() => Platform.isIOS),
        _isAndroid = isAndroid ?? (() => Platform.isAndroid),
        _firebaseMessagingOverride = firebaseMessaging;

  final NotificationsRepository _repository;
  final MethodChannel _iosChannel;
  final bool Function() _isIOS;
  final bool Function() _isAndroid;
  final FirebaseMessaging? _firebaseMessagingOverride;

  FirebaseMessaging get _firebaseMessaging =>
      _firebaseMessagingOverride ?? FirebaseMessaging.instance;

  /// Requests permission, obtains a token, and registers it for [venueId]. Returns `true` only
  /// if a token was actually sent to the server.
  Future<bool> registerForVenue(String venueId) async {
    try {
      if (_isIOS()) {
        return await _registerIOS(venueId);
      }
      if (_isAndroid()) {
        return await _registerAndroid(venueId);
      }
      // Web/desktop: no push transport wired up here.
      return false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _registerIOS(String venueId) async {
    try {
      final token = await _iosChannel
          .invokeMethod<String>('requestPermissionAndRegister');
      if (token == null || token.isEmpty) return false;
      await _repository.registerPushToken(
        venueId: venueId,
        token: token,
        platform: 'ios',
      );
      return true;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<bool> _registerAndroid(String venueId) async {
    final settings = await _firebaseMessaging.requestPermission();
    final authorized =
        settings.authorizationStatus == AuthorizationStatus.authorized ||
            settings.authorizationStatus == AuthorizationStatus.provisional;
    if (!authorized) return false;

    final token = await _firebaseMessaging.getToken();
    if (token == null || token.isEmpty) return false;

    await _repository.registerPushToken(
      venueId: venueId,
      token: token,
      platform: 'android',
    );
    return true;
  }
}

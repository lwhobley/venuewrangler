import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:flutter/services.dart';

import '../../../core/storage/secure_session_storage.dart';

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
        _isIOS = isIOS ?? (() => !kIsWeb && Platform.isIOS),
        _isAndroid = isAndroid ?? (() => !kIsWeb && Platform.isAndroid),
        _firebaseMessagingOverride = firebaseMessaging;

  final NotificationsRepository _repository;
  final MethodChannel _iosChannel;
  final bool Function() _isIOS;
  final bool Function() _isAndroid;
  final FirebaseMessaging? _firebaseMessagingOverride;
  final SecureSessionStorage _sessionStorage = const SecureSessionStorage();

  /// Venue the Android token was last registered for; a rotated FCM token is re-registered
  /// against it. Null until the first successful Android registration.
  String? _androidVenueId;
  StreamSubscription<String>? _tokenRefreshSubscription;
  Future<String>? _installationSecret;
  bool _disposed = false;

  Future<String> _getInstallationSecret() => _installationSecret ??= () async {
        final existing =
            await _sessionStorage.read(pushInstallationSecretStorageKey);
        if (existing != null) return existing;
        final random = Random.secure();
        final secret = List.generate(
          32,
          (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
        ).join();
        await _sessionStorage.write(pushInstallationSecretStorageKey, secret);
        return secret;
      }();

  FirebaseMessaging get _firebaseMessaging =>
      _firebaseMessagingOverride ?? FirebaseMessaging.instance;

  /// Cancels the FCM token-refresh listener. Called when the provider is disposed.
  Future<void> dispose() async {
    _disposed = true;
    await _tokenRefreshSubscription?.cancel();
    _tokenRefreshSubscription = null;
  }

  void _listenForTokenRefresh() {
    _tokenRefreshSubscription ??= _firebaseMessaging.onTokenRefresh.listen(
      (token) => unawaited(_onAndroidTokenRefreshed(token)),
      onError: (Object _) {},
    );
  }

  /// FCM rotates tokens (app restore, reinstall, periodic refresh). Without this the server
  /// keeps only the old token and Android pushes silently stop until the next app launch.
  Future<void> _onAndroidTokenRefreshed(String token) async {
    final venueId = _androidVenueId;
    if (venueId == null || token.isEmpty) return;
    try {
      await _registerAndRemember(venueId, token, 'android');
    } catch (_) {
      // Same fire-and-forget posture as registerForVenue: the next launch retries.
    }
  }

  Future<void> _registerAndRemember(
    String venueId,
    String token,
    String platform,
  ) async {
    final secret = await _getInstallationSecret();
    if (_disposed) return;
    // Revoking a previous account's token is best effort. If it fails (offline, or secure storage
    // unavailable) the pending marker stays and is retried on a later registration, but it must
    // not stop this device from registering for the current venue.
    try {
      final pendingRevocation =
          await _sessionStorage.read(pendingPushTokenRevocationStorageKey);
      if (pendingRevocation != null) {
        await _repository.unregisterPushToken(
          pendingRevocation,
          revocationSecret: secret,
        );
        await _sessionStorage.delete(pendingPushTokenRevocationStorageKey);
      }
    } catch (error) {
      debugPrint('Push: pending token revocation failed, continuing: $error');
    }
    await _repository.registerPushToken(
      venueId: venueId,
      token: token,
      platform: platform,
      revocationSecret: secret,
    );
    if (_disposed) {
      await _repository.unregisterPushToken(token, revocationSecret: secret);
      return;
    }
    try {
      await _sessionStorage.write(registeredPushTokenStorageKey, token);
    } catch (_) {
      await _repository.unregisterPushToken(token, revocationSecret: secret);
      rethrow;
    }
  }

  /// Requests permission, obtains a token, and registers it for [venueId]. Returns `true` only
  /// if a token was actually sent to the server.
  Future<bool> registerForVenue(String venueId) async {
    if (_disposed) return false;
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
      await _registerAndRemember(venueId, token, 'ios');
      return !_disposed;
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

    await _registerAndRemember(venueId, token, 'android');
    if (_disposed) return false;
    _androidVenueId = venueId;
    _listenForTokenRefresh();
    return true;
  }
}

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../storage/secure_session_storage.dart';

/// Client side of iOS App Attest — talks to `supabase/functions/device-attestation` and its
/// real cryptographic verification in `supabase/functions/_shared/app-attest.ts`. Android has a
/// separate, net-new Play Integrity client path not covered here (no prior implementation to
/// port — see `core/security/README.md`); `isSupported()`/`attestDevice()` are both always
/// `false`/no-ops on non-iOS platforms by design, not a gap in this file.
///
/// Two-step flow, matching the server's device-attestation/index.ts exactly:
///   1. Ask the server for a signed, single-use challenge bound to this user + device_id
///      (`action: "challenge"`). The server now also tracks it server-side for single-use
///      enforcement (see the `attestation_challenges` table) — this client doesn't need to know
///      that, it just has to send the same challenge token back unmodified.
///   2. Generate (or reuse) a DeviceCheck key, attest it against that challenge's nonce, and
///      send the attestation object back for verification.
///
/// This feature runs in `observe` mode only on the server (see device-attestation/index.ts's
/// header comment) — it never blocks or gates anything here either. [attestDevice] never
/// throws; every failure path returns `false` so a caller can fire-and-forget this on a timer
/// or after sign-in without needing its own try/catch.
class AppAttestService {
  AppAttestService({
    required SupabaseClient client,
    SecureSessionStorage storage = const SecureSessionStorage(),
    MethodChannel? channel,
    bool Function()? isIOS,
  })  : _client = client,
        _storage = storage,
        _channel =
            channel ?? const MethodChannel('com.venuewrangler.app/app_attest'),
        _isIOS = isIOS ?? (() => !kIsWeb && Platform.isIOS);

  final SupabaseClient _client;
  final SecureSessionStorage _storage;
  final MethodChannel _channel;
  // Injectable so widget/unit tests can exercise the iOS code path on a non-iOS test host,
  // rather than every non-iOS CI run silently short-circuiting this file's actual logic.
  final bool Function() _isIOS;

  static const _deviceIdStorageKey = 'app_attest.device_id';
  static const _keyIdStorageKey = 'app_attest.key_id';

  /// True only on iOS where the current OS/device actually supports App Attest (iOS 14+, and
  /// not every simulator configuration does — the simulator generally does not). This is not a
  /// generic "is some device attestation available" check.
  Future<bool> isSupported() async {
    if (!_isIOS()) return false;
    try {
      return await _channel.invokeMethod<bool>('isSupported') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Runs the full attest-and-verify round trip. Returns `true` only if the server recorded a
  /// `valid` verdict for this attestation; `false` for every other outcome (unsupported
  /// device, network failure, expired/reused challenge, server rejection) — see class doc for
  /// why this never throws instead.
  Future<bool> attestDevice() async {
    if (!await isSupported()) return false;

    try {
      final deviceId = await _getOrCreateDeviceId();

      final challengeResponse = await _client.functions.invoke(
        'device-attestation',
        body: {'action': 'challenge', 'platform': 'ios', 'device_id': deviceId},
      );
      final challengeToken =
          (challengeResponse.data as Map?)?['challenge'] as String?;
      if (challengeToken == null) return false;

      final nonceBytes = _extractNonceBytes(challengeToken);
      if (nonceBytes == null) return false;

      final keyId = await _getOrGenerateKeyId();
      if (keyId == null) return false;

      final Uint8List? attestationObject;
      try {
        attestationObject =
            await _channel.invokeMethod<Uint8List>('attestKey', {
          'keyId': keyId,
          'nonceBytes': nonceBytes,
        });
      } on PlatformException {
        // Apple's guidance when a key stops working (DCError.invalidKey — e.g. after a device
        // restore) is to generate a new one. Dropping the cached id makes the next attempt do
        // that instead of retrying a dead key forever.
        await _storage.delete(_keyIdStorageKey);
        return false;
      }
      if (attestationObject == null) return false;

      final verifyResponse = await _client.functions.invoke(
        'device-attestation',
        body: {
          'platform': 'ios',
          'device_id': deviceId,
          'key_id': keyId,
          'attestation_object': base64Encode(attestationObject),
          'challenge': challengeToken,
        },
      );
      final status = (verifyResponse.data as Map?)?['status'] as String?;
      return status == 'valid';
    } catch (_) {
      // Fail silently — see class doc. The `device_attestations` row the server inserts (if it
      // got that far) is the durable record of what actually happened; this boolean only tells
      // the immediate caller whether it's worth retrying later.
      return false;
    }
  }

  /// A stable, random per-install identifier — not a real hardware identifier (Apple and
  /// Google both restrict access to those); just a UUID persisted in secure storage so the
  /// same value is reused across launches. Binds a challenge/key to "this install" server-side.
  Future<String> _getOrCreateDeviceId() async {
    final existing = await _storage.read(_deviceIdStorageKey);
    if (existing != null && existing.isNotEmpty) return existing;

    final generated = const Uuid().v4();
    await _storage.write(_deviceIdStorageKey, generated);
    return generated;
  }

  /// Apple's guidance is to generate an attestation key once per app install and reuse it —
  /// repeated `generateKey()` calls mint unrelated keys for no benefit and cost an extra
  /// `attestKey()` round trip each time. Cached in secure storage, not just memory, so a
  /// restarted app doesn't silently keep minting new keys.
  Future<String?> _getOrGenerateKeyId() async {
    final existing = await _storage.read(_keyIdStorageKey);
    if (existing != null && existing.isNotEmpty) return existing;

    try {
      final generated = await _channel.invokeMethod<String>('generateKey');
      if (generated == null) return null;
      await _storage.write(_keyIdStorageKey, generated);
      return generated;
    } on PlatformException {
      return null;
    }
  }

  /// Parses the signed challenge token's unsigned payload segment to pull out the raw nonce
  /// bytes the server generated (see `signAttestationChallenge` in `_shared/crypto.ts`). The
  /// client never verifies the signature itself — it has no way to, the signing key is
  /// server-only — it only needs the nonce to compute `clientDataHash` correctly (done natively
  /// in AppAttestPlugin.swift, not here, so this file needs no SHA-256 dependency of its own).
  /// The server re-verifies the signature when this challenge comes back in step 2, so a
  /// tampered or forged token here just fails there instead of being trusted blindly.
  Uint8List? _extractNonceBytes(String challengeToken) {
    final parts = challengeToken.split('.');
    if (parts.length != 2) return null;
    try {
      final payloadJson = utf8.decode(base64.decode(_padBase64(parts[0])));
      final payload = jsonDecode(payloadJson) as Map<String, dynamic>;
      final nonceB64 = payload['nonce_b64'] as String?;
      if (nonceB64 == null) return null;
      return base64.decode(_padBase64(nonceB64));
    } catch (_) {
      return null;
    }
  }

  String _padBase64(String input) {
    final remainder = input.length % 4;
    if (remainder == 0) return input;
    return input + ('=' * (4 - remainder));
  }
}

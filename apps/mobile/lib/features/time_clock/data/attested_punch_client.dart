import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/errors/app_error.dart';
import '../domain/time_entry.dart';

/// Device proof for one punch request.
class PunchProof {
  const PunchProof({required this.platform, required this.evidence});

  /// `ios` or `android`.
  final String platform;

  /// iOS: `{key_id, assertion}` (base64). Android: `{integrity_token}`.
  final Map<String, Object?> evidence;
}

/// Produces [PunchProof] for a payload; null when this device cannot (web, unsupported OS,
/// App Attest key not yet attested, Play Integrity not configured).
abstract interface class PunchProofProvider {
  Future<PunchProof?> prove(String payloadJson);
}

/// The server could not be used for an attested punch and the caller may fall back to the
/// direct database path (older backend without the function, or it is temporarily down). Never
/// thrown for a policy refusal: those are real answers and must reach the user.
class AttestedPunchUnavailable implements Exception {
  const AttestedPunchUnavailable();
}

/// Records punches through `supabase/functions/time-clock-punch`, which verifies the device proof
/// and then records the punch with every database check (membership, geofence, accuracy, replay).
///
///   1. `challenge` -> single-use server nonce.
///   2. Build the payload (kind, venue, fix, nonce, timestamp) as one JSON string. The device
///      proof covers SHA-256 of exactly these bytes, and the server hashes the same string.
///   3. `punch` with the payload and proof.
/// Calls the `time-clock-punch` function with [body] and returns the response data. Throws
/// [FunctionException] for a non-2xx answer.
typedef PunchFunctionInvoker = Future<Object?> Function(
  Map<String, Object?> body,
);

class AttestedPunchClient {
  AttestedPunchClient({
    required PunchFunctionInvoker invoke,
    required PunchProofProvider proof,
    DateTime Function()? now,
  })  : _invoke = invoke,
        _proof = proof,
        _now = now ?? DateTime.now;

  /// Production wiring: the signed-in user's Supabase client.
  factory AttestedPunchClient.forClient(
    SupabaseClient client, {
    required PunchProofProvider proof,
  }) =>
      AttestedPunchClient(
        invoke: (body) async =>
            (await client.functions.invoke('time-clock-punch', body: body))
                .data,
        proof: proof,
      );

  final PunchFunctionInvoker _invoke;
  final PunchProofProvider _proof;
  final DateTime Function() _now;

  /// Hex SHA-256 of [payloadJson], used by the Android requestHash.
  static String payloadHashHex(String payloadJson) =>
      sha256.convert(utf8.encode(payloadJson)).toString();

  /// The exact payload string the proof and the server both hash. Key order is fixed.
  static String buildPayload({
    required String kind,
    required String venueId,
    required double lat,
    required double lng,
    required double accuracyM,
    required bool mocked,
    required String nonce,
    required int timestampMs,
  }) =>
      jsonEncode({
        'v': 1,
        'kind': kind,
        'venue_id': venueId,
        'lat': lat,
        'lng': lng,
        'accuracy_m': accuracyM,
        'mocked': mocked,
        'nonce': nonce,
        'ts': timestampMs,
      });

  Future<TimeEntry> punch({
    required String kind,
    required String venueId,
    required double lat,
    required double lng,
    required double accuracyM,
    required bool mocked,
  }) async {
    try {
      final challenge = await _invoke({'action': 'challenge'});
      final nonce = (challenge as Map?)?['nonce'] as String?;
      if (nonce == null) throw const AttestedPunchUnavailable();

      final payloadJson = buildPayload(
        kind: kind,
        venueId: venueId,
        lat: lat,
        lng: lng,
        accuracyM: accuracyM,
        mocked: mocked,
        nonce: nonce,
        timestampMs: _now().millisecondsSinceEpoch,
      );
      final proof = await _proof.prove(payloadJson);

      final response = await _invoke({
        'action': 'punch',
        'payload_json': payloadJson,
        if (proof != null) 'platform': proof.platform,
        if (proof != null) 'evidence': proof.evidence,
      });
      final entry = (response as Map?)?['entry'];
      if (entry is! Map) throw const AttestedPunchUnavailable();
      return TimeEntry.fromJson(Map<String, dynamic>.from(entry));
    } on FunctionException catch (error) {
      throw _map(error);
    }
  }

  Object _map(FunctionException error) {
    final details = error.details;
    final code = details is Map ? details['error'] as String? : null;
    switch (code) {
      case 'outside_geofence':
        return const PermissionDeniedError(
          'You are outside the venue geofence. Move closer to the venue to clock in/out.',
        );
      case 'location_replayed':
        return const PermissionDeniedError(
          'This location reading was flagged as an identical replay of an earlier fix. Please re-acquire GPS and try again.',
        );
      case 'location_accuracy_too_low':
        return const PermissionDeniedError(
          'Location accuracy must be 50m or better. Wait for a stronger GPS fix and try again.',
        );
      case 'mocked_location':
        return const PermissionDeniedError(
          'Mocked locations are not allowed.',
        );
      case 'attestation_failed':
      case 'attested_punch_required':
        return const PermissionDeniedError(
          'This device could not be verified. Update the app and try again, or ask a manager to record your punch.',
        );
      case 'already_clocked_in':
        return const UnknownError('You are already clocked in.');
      case 'no_open_punch':
        return const UnknownError('You are not clocked in.');
      case 'nonce_invalid_or_expired':
        return const UnknownError('The request expired. Please try again.');
      case 'forbidden':
        return const PermissionDeniedError(
          'You do not have access to do this.',
        );
      case 'rate_limited':
        return const UnknownError('Too many attempts. Please wait a moment.');
    }
    // 404 = function not deployed yet; 5xx = temporarily unavailable. The direct path remains
    // valid until the backend requires attested punches.
    if (error.status == 404 || error.status >= 500) {
      return const AttestedPunchUnavailable();
    }
    return UnknownError(
      'Could not record the punch (${error.status}). Please try again.',
    );
  }
}

/// Default [PunchProofProvider]: App Attest on iOS, Play Integrity on Android.
class PlatformPunchProofProvider implements PunchProofProvider {
  PlatformPunchProofProvider({
    required Future<({String keyId, Uint8List assertion})?> Function(
      Uint8List payloadBytes,
    ) iosAssertion,
    required Future<String?> Function(String requestHashHex) androidToken,
    required String Function() platform,
  })  : _iosAssertion = iosAssertion,
        _androidToken = androidToken,
        _platform = platform;

  final Future<({String keyId, Uint8List assertion})?> Function(
    Uint8List payloadBytes,
  ) _iosAssertion;
  final Future<String?> Function(String requestHashHex) _androidToken;
  final String Function() _platform;

  @override
  Future<PunchProof?> prove(String payloadJson) async {
    switch (_platform()) {
      case 'ios':
        final assertion =
            await _iosAssertion(Uint8List.fromList(utf8.encode(payloadJson)));
        if (assertion == null) return null;
        return PunchProof(
          platform: 'ios',
          evidence: {
            'key_id': assertion.keyId,
            'assertion': base64Encode(assertion.assertion),
          },
        );
      case 'android':
        final token = await _androidToken(
          AttestedPunchClient.payloadHashHex(payloadJson),
        );
        if (token == null) return null;
        return PunchProof(
          platform: 'android',
          evidence: {'integrity_token': token},
        );
    }
    return null;
  }
}

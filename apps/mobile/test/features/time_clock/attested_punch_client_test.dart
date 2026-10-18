import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:venuewrangler_mobile/core/errors/app_error.dart';
import 'package:venuewrangler_mobile/features/time_clock/data/attested_punch_client.dart';

const _venueId = 'd3000000-0000-0000-0000-0000000000a1';

Map<String, Object?> _entryJson({bool attested = true}) => {
      'id': 'e0000000-0000-0000-0000-000000000001',
      'organization_id': 'd2000000-0000-0000-0000-00000000000a',
      'venue_id': _venueId,
      'user_id': 'd1000000-0000-0000-0000-000000000002',
      'clock_in_at': '2026-10-17T12:00:00Z',
      'clock_in_lat': 29.7604,
      'clock_in_lng': -95.3698,
      'clock_in_accuracy_m': 12.0,
      'clock_in_mocked': false,
      'is_open': true,
      'breaks': <Object?>[],
      'clock_in_attested': attested,
      'clock_out_attested': false,
      'punch_source': attested ? 'attested' : 'direct',
      'created_at': '2026-10-17T12:00:00Z',
      'updated_at': '2026-10-17T12:00:00Z',
    };

class _Proofs implements PunchProofProvider {
  _Proofs(this.proof);

  final PunchProof? proof;
  final payloads = <String>[];

  @override
  Future<PunchProof?> prove(String payloadJson) async {
    payloads.add(payloadJson);
    return proof;
  }
}

AttestedPunchClient _client(
  Future<Object?> Function(Map<String, Object?> body) invoke,
  PunchProofProvider proofs,
) =>
    AttestedPunchClient(
      invoke: invoke,
      proof: proofs,
      now: () => DateTime.utc(2026, 10, 17, 12),
    );

Future<TimeEntryResult> _punch(AttestedPunchClient client) async {
  final entry = await client.punch(
    kind: 'in',
    venueId: _venueId,
    lat: 29.7604,
    lng: -95.3698,
    accuracyM: 12,
    mocked: false,
  );
  return TimeEntryResult(entry.id, entry.clockInAttested, entry.punchSource);
}

class TimeEntryResult {
  const TimeEntryResult(this.id, this.attested, this.source);

  final String id;
  final bool attested;
  final String source;
}

void main() {
  test('payload is stable JSON carrying the nonce, and its hash is SHA-256 hex',
      () {
    final payload = AttestedPunchClient.buildPayload(
      kind: 'in',
      venueId: _venueId,
      lat: 29.7604,
      lng: -95.3698,
      accuracyM: 12,
      mocked: false,
      nonce: 'N' * 43,
      timestampMs: 1790000000000,
    );
    final decoded = jsonDecode(payload) as Map<String, dynamic>;
    expect(decoded['v'], 1);
    expect(decoded['kind'], 'in');
    expect(decoded['nonce'], 'N' * 43);
    expect(decoded['ts'], 1790000000000);
    expect(
      AttestedPunchClient.payloadHashHex('abc'),
      'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
    );
  });

  test('requests a nonce, proves the exact payload, and returns the entry',
      () async {
    final bodies = <Map<String, Object?>>[];
    final proofs = _Proofs(
      const PunchProof(
        platform: 'ios',
        evidence: {'key_id': 'k1', 'assertion': 'QQ=='},
      ),
    );
    final client = _client(
      (body) async {
        bodies.add(body);
        if (body['action'] == 'challenge') return {'nonce': 'N' * 43};
        return {'status': 'verified', 'entry': _entryJson()};
      },
      proofs,
    );

    final result = await _punch(client);

    expect(result.attested, isTrue);
    expect(result.source, 'attested');
    expect(bodies.map((b) => b['action']), ['challenge', 'punch']);
    // The proof was computed over exactly the payload string that was sent.
    expect(bodies[1]['payload_json'], proofs.payloads.single);
    expect(bodies[1]['platform'], 'ios');
    expect(bodies[1]['evidence'], {'key_id': 'k1', 'assertion': 'QQ=='});
    expect(
      (jsonDecode(proofs.payloads.single) as Map)['nonce'],
      'N' * 43,
    );
  });

  test('sends the punch without evidence when the device cannot prove it',
      () async {
    Map<String, Object?>? punchBody;
    final client = _client(
      (body) async {
        if (body['action'] == 'challenge') return {'nonce': 'N' * 43};
        punchBody = body;
        return {
          'status': 'unverified',
          'entry': _entryJson(attested: false),
        };
      },
      _Proofs(null),
    );

    final result = await _punch(client);

    expect(result.attested, isFalse);
    expect(punchBody!.containsKey('evidence'), isFalse);
    expect(punchBody!.containsKey('platform'), isFalse);
  });

  test('maps server refusals to user-facing errors', () async {
    final cases = <String, String>{
      'outside_geofence': 'outside the venue geofence',
      'attestation_failed': 'could not be verified',
      'attested_punch_required': 'could not be verified',
      'location_replayed': 'identical replay',
      'mocked_location': 'Mocked locations',
      'already_clocked_in': 'already clocked in',
    };
    for (final entry in cases.entries) {
      final client = _client(
        (body) async {
          if (body['action'] == 'challenge') return {'nonce': 'N' * 43};
          throw FunctionException(status: 403, details: {'error': entry.key});
        },
        _Proofs(null),
      );
      await expectLater(
        _punch(client),
        throwsA(
          isA<AppError>()
              .having((e) => e.message, 'message', contains(entry.value)),
        ),
        reason: entry.key,
      );
    }
  });

  test('an unavailable function is reported so the caller can fall back',
      () async {
    for (final status in [404, 500, 503]) {
      final client = _client(
        (body) async => throw FunctionException(status: status),
        _Proofs(null),
      );
      await expectLater(
        _punch(client),
        throwsA(isA<AttestedPunchUnavailable>()),
        reason: '$status',
      );
    }
  });

  test('a policy refusal is never treated as unavailable', () async {
    final client = _client(
      (body) async {
        if (body['action'] == 'challenge') return {'nonce': 'N' * 43};
        throw FunctionException(status: 403, details: {'error': 'forbidden'});
      },
      _Proofs(null),
    );
    await expectLater(_punch(client), throwsA(isA<PermissionDeniedError>()));
  });

  test('PlatformPunchProofProvider builds iOS and Android evidence', () async {
    final ios = PlatformPunchProofProvider(
      iosAssertion: (bytes) async =>
          (keyId: 'key-1', assertion: Uint8List.fromList([1, 2, 3])),
      androidToken: (_) async => null,
      platform: () => 'ios',
    );
    final iosProof = await ios.prove('{"x":1}');
    expect(iosProof!.platform, 'ios');
    expect(iosProof.evidence['key_id'], 'key-1');
    expect(iosProof.evidence['assertion'], base64Encode([1, 2, 3]));

    String? hashSeen;
    final android = PlatformPunchProofProvider(
      iosAssertion: (_) async => null,
      androidToken: (hash) async {
        hashSeen = hash;
        return 'token-abc';
      },
      platform: () => 'android',
    );
    final androidProof = await android.prove('abc');
    expect(androidProof!.evidence, {'integrity_token': 'token-abc'});
    expect(
      hashSeen,
      'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
    );

    final none = PlatformPunchProofProvider(
      iosAssertion: (_) async => null,
      androidToken: (_) async => null,
      platform: () => 'web',
    );
    expect(await none.prove('x'), isNull);
  });
}

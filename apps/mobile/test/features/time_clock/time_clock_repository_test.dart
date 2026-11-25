import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:venuewrangler_mobile/core/errors/app_error.dart';
import 'package:venuewrangler_mobile/features/time_clock/data/attested_punch_client.dart';
import 'package:venuewrangler_mobile/features/time_clock/data/time_clock_repository.dart';

const _venueId = 'd3000000-0000-0000-0000-0000000000a1';
const _entryId = 'e0000000-0000-0000-0000-000000000001';

Map<String, Object?> _entryJson({bool open = false}) => {
      'id': _entryId,
      'organization_id': 'd2000000-0000-0000-0000-00000000000a',
      'venue_id': _venueId,
      'user_id': 'd1000000-0000-0000-0000-000000000002',
      'clock_in_at': '2026-10-17T12:00:00Z',
      'clock_in_lat': 29.7604,
      'clock_in_lng': -95.3698,
      'clock_in_accuracy_m': 12.0,
      'clock_in_mocked': false,
      'is_open': open,
      'breaks': <Object?>[],
      'clock_in_attested': false,
      'clock_out_attested': false,
      'punch_source': 'direct',
      'created_at': '2026-10-17T12:00:00Z',
      'updated_at': '2026-10-17T12:00:00Z',
    };

class _NoProof implements PunchProofProvider {
  @override
  Future<PunchProof?> prove(String payloadJson) async => null;
}

/// A Supabase client whose REST calls are answered by [respond] and recorded in [requests].
SupabaseClient _supabase(
  List<http.Request> requests,
  http.Response Function(http.Request r) respond,
) {
  final client = SupabaseClient(
    'https://timeclock.test',
    'public-test-key',
    httpClient: MockClient((r) async {
      requests.add(r);
      return respond(r);
    }),
  );
  addTearDown(client.dispose);
  return client;
}

http.Response _json(http.Request r, Object? body, [int status = 200]) =>
    http.Response(
      jsonEncode(body),
      status,
      request: r,
      headers: {'content-type': 'application/json'},
    );

void main() {
  test(
      'clockIn: a server error from the attested punch fails the punch with no direct write',
      () async {
    final requests = <http.Request>[];
    final supabase = _supabase(requests, (r) => _json(r, _entryJson()));
    final repo = SupabaseTimeClockRepository(
      supabase,
      attestedPunches: AttestedPunchClient(
        invoke: (body) async {
          if (body['action'] == 'challenge') {
            return {'nonce': 'N' * 43, 'mode': 'observe'};
          }
          throw FunctionException(
            status: 500,
            details: {'error': 'internal_error', 'code': '23503'},
          );
        },
        proof: _NoProof(),
      ),
    );

    await expectLater(
      repo.clockIn(venueId: _venueId, lat: 29.76, lng: -95.37, accuracyM: 12),
      throwsA(
        isA<AppError>().having(
          (e) => e.message,
          'message',
          contains('Could not record the punch'),
        ),
      ),
    );
    expect(requests, isEmpty, reason: 'no unattested time_entries write');
  });

  test(
      'clockIn: an undeployed function in observe mode still uses the documented fallback',
      () async {
    final requests = <http.Request>[];
    final supabase =
        _supabase(requests, (r) => _json(r, _entryJson(open: true), 201));
    final repo = SupabaseTimeClockRepository(
      supabase,
      attestedPunches: AttestedPunchClient(
        invoke: (body) async => throw FunctionException(status: 404),
        proof: _NoProof(),
      ),
    );

    await repo.clockIn(
      venueId: _venueId,
      lat: 29.76,
      lng: -95.37,
      accuracyM: 12,
    );
    expect(requests.single.method, 'POST');
    expect(requests.single.url.path, '/rest/v1/time_entries');
  });

  test('clockOut: a failed venue lookup fails closed and skips the write',
      () async {
    final requests = <http.Request>[];
    var punches = 0;
    final supabase = _supabase(
      requests,
      (r) => _json(r, {'message': 'boom', 'code': 'XX000'}, 500),
    );
    final repo = SupabaseTimeClockRepository(
      supabase,
      attestedPunches: AttestedPunchClient(
        invoke: (body) async {
          punches++;
          return {'nonce': 'N' * 43};
        },
        proof: _NoProof(),
      ),
    );

    await expectLater(
      repo.clockOut(entryId: _entryId, lat: 29.76, lng: -95.37, accuracyM: 12),
      throwsA(isA<AppError>()),
    );
    expect(punches, 0);
    expect(requests.map((r) => r.method), ['GET']);
  });

  test('clockOut: a missing entry fails closed and skips the write', () async {
    final requests = <http.Request>[];
    final supabase = _supabase(requests, (r) => _json(r, <Object?>[]));
    final repo = SupabaseTimeClockRepository(
      supabase,
      attestedPunches: AttestedPunchClient(
        invoke: (body) async => fail('no punch without a venue'),
        proof: _NoProof(),
      ),
    );

    await expectLater(
      repo.clockOut(entryId: _entryId, lat: 29.76, lng: -95.37, accuracyM: 12),
      throwsA(
        isA<UnknownError>().having(
          (e) => e.message,
          'message',
          contains('not clocked in'),
        ),
      ),
    );
    expect(requests.map((r) => r.method), ['GET']);
  });

  test('clockOut: looks up the venue, then punches through the attested path',
      () async {
    final requests = <http.Request>[];
    final bodies = <Map<String, Object?>>[];
    final supabase =
        _supabase(requests, (r) => _json(r, {'venue_id': _venueId}));
    final repo = SupabaseTimeClockRepository(
      supabase,
      attestedPunches: AttestedPunchClient(
        invoke: (body) async {
          bodies.add(body);
          if (body['action'] == 'challenge') return {'nonce': 'N' * 43};
          return {'status': 'unverified', 'entry': _entryJson()};
        },
        proof: _NoProof(),
      ),
    );

    final entry = await repo.clockOut(
      entryId: _entryId,
      lat: 29.76,
      lng: -95.37,
      accuracyM: 12,
    );
    expect(entry.id, _entryId);
    expect(bodies.map((b) => b['action']), ['challenge', 'punch']);
    final payload = jsonDecode(bodies[1]['payload_json']! as String) as Map;
    expect(payload['kind'], 'out');
    expect(payload['venue_id'], _venueId);
    expect(requests.map((r) => r.method), ['GET']);
  });
}

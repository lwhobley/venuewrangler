import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:venuewrangler_mobile/core/security/app_attest_service.dart';

/// In-memory fake for flutter_secure_storage's platform channel — the real plugin has no
/// backing implementation in a widget-test host, so without this every read/write throws
/// MissingPluginException, which AppAttestService's outer try/catch would silently swallow as
/// "attestation failed," masking whatever the test is actually trying to verify.
class _FakeSecureStoragePlatform extends FlutterSecureStoragePlatform {
  final Map<String, String> _values = {};

  @override
  Future<void> write({required String key, required String value, required Map<String, String> options}) async {
    _values[key] = value;
  }

  @override
  Future<String?> read({required String key, required Map<String, String> options}) async => _values[key];

  @override
  Future<bool> containsKey({required String key, required Map<String, String> options}) async =>
      _values.containsKey(key);

  @override
  Future<void> delete({required String key, required Map<String, String> options}) async {
    _values.remove(key);
  }

  @override
  Future<Map<String, String>> readAll({required Map<String, String> options}) async => Map.of(_values);

  @override
  Future<void> deleteAll({required Map<String, String> options}) async => _values.clear();
}

/// A signed-challenge-token builder matching the server's own encoding in
/// `supabase/functions/_shared/crypto.ts`'s `signAttestationChallenge` — unsigned here (the
/// signature isn't checked client-side; the client just needs to round-trip it and extract the
/// nonce), but shaped identically so [AppAttestService] parses it the same way.
http.Response _jsonResponse(Map<String, dynamic> body, [int status = 200]) {
  return http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});
}

String _buildChallengeToken(Uint8List nonceBytes) {
  final payload = {
    'user_id': 'user-1',
    'device_id': 'device-1',
    'nonce_b64': base64Encode(nonceBytes),
    'issued_at': DateTime.now().millisecondsSinceEpoch,
  };
  final payloadB64 = base64Encode(utf8.encode(jsonEncode(payload)));
  return '$payloadB64.fake-signature';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.venuewrangler.app/app_attest');
  final methodCalls = <MethodCall>[];
  String methodResponse = 'generated-key-1';
  Uint8List attestationObjectResponse = Uint8List.fromList([1, 2, 3, 4]);
  bool isSupportedResponse = true;
  bool attestKeyShouldFail = false;

  setUp(() {
    methodCalls.clear();
    isSupportedResponse = true;
    methodResponse = 'generated-key-1';
    attestationObjectResponse = Uint8List.fromList([1, 2, 3, 4]);
    attestKeyShouldFail = false;
    FlutterSecureStoragePlatform.instance = _FakeSecureStoragePlatform();

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (call) async {
        methodCalls.add(call);
        switch (call.method) {
          case 'isSupported':
            return isSupportedResponse;
          case 'generateKey':
            return methodResponse;
          case 'attestKey':
            if (attestKeyShouldFail) {
              throw PlatformException(code: 'attest_key_failed', message: 'invalid key');
            }
            return attestationObjectResponse;
        }
        return null;
      },
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  SupabaseClient buildClient(Future<http.Response> Function(http.Request) handler) {
    return SupabaseClient(
      'https://example.supabase.co',
      'test-anon-key',
      httpClient: MockClient.streaming((request, bodyStream) async {
        final bodyBytes = await bodyStream.toBytes();
        final req = http.Request(request.method, request.url)..bodyBytes = bodyBytes;
        final response = await handler(req);
        return http.StreamedResponse(
          Stream.value(response.bodyBytes),
          response.statusCode,
          headers: response.headers,
        );
      }),
    );
  }

  test('isSupported is false on a non-iOS host even if the channel would say yes', () async {
    final client = buildClient((req) async => http.Response('{}', 200));
    final service = AppAttestService(client: client, isIOS: () => false);

    expect(await service.isSupported(), isFalse);
    expect(methodCalls, isEmpty);
  });

  test('attestDevice runs the full challenge -> attestKey -> verify round trip and returns true on a valid verdict', () async {
    late Uint8List nonceSentToAttestKey;
    final nonceBytes = Uint8List.fromList(List.generate(32, (i) => i));
    final challengeToken = _buildChallengeToken(nonceBytes);

    attestationObjectResponse = Uint8List.fromList([9, 9, 9]);

    final client = buildClient((req) async {
      if (req.url.path.endsWith('/functions/v1/device-attestation')) {
        final body = jsonDecode(utf8.decode(req.bodyBytes)) as Map<String, dynamic>;
        if (body['action'] == 'challenge') {
          return _jsonResponse({'challenge': challengeToken});
        }
        // Verification call: confirm the client sent back the exact same challenge token and
        // the base64 of whatever attestKey returned.
        expect(body['challenge'], challengeToken);
        expect(body['key_id'], 'generated-key-1');
        expect(body['attestation_object'], base64Encode(attestationObjectResponse));
        return _jsonResponse({'recorded': true, 'mode': 'observe', 'status': 'valid'});
      }
      return http.Response('not found', 404);
    });

    final service = AppAttestService(client: client, isIOS: () => true);

    final result = await service.attestDevice();

    expect(result, isTrue);

    final attestKeyCall = methodCalls.firstWhere((c) => c.method == 'attestKey');
    nonceSentToAttestKey = (attestKeyCall.arguments as Map)['nonceBytes'] as Uint8List;
    expect(nonceSentToAttestKey, nonceBytes);
    expect((attestKeyCall.arguments as Map)['keyId'], 'generated-key-1');
  });

  test('attestDevice returns false when the server records an invalid verdict', () async {
    final nonceBytes = Uint8List.fromList(List.generate(32, (i) => i));
    final challengeToken = _buildChallengeToken(nonceBytes);

    final client = buildClient((req) async {
      final body = jsonDecode(utf8.decode(req.bodyBytes)) as Map<String, dynamic>;
      if (body['action'] == 'challenge') {
        return _jsonResponse({'challenge': challengeToken});
      }
      return _jsonResponse({'recorded': true, 'mode': 'observe', 'status': 'invalid'});
    });

    final service = AppAttestService(client: client, isIOS: () => true);

    expect(await service.attestDevice(), isFalse);
  });

  test('attestDevice returns false (never throws) when the challenge call fails outright', () async {
    final client = buildClient((req) async => http.Response('internal error', 500));
    final service = AppAttestService(client: client, isIOS: () => true);

    expect(await service.attestDevice(), isFalse);
  });

  test('a second attestDevice call reuses the cached key id instead of calling generateKey again', () async {
    final nonceBytes1 = Uint8List.fromList(List.generate(32, (i) => i));
    final nonceBytes2 = Uint8List.fromList(List.generate(32, (i) => 31 - i));

    var challengeCount = 0;
    final client = buildClient((req) async {
      final body = jsonDecode(utf8.decode(req.bodyBytes)) as Map<String, dynamic>;
      if (body['action'] == 'challenge') {
        challengeCount++;
        final nonce = challengeCount == 1 ? nonceBytes1 : nonceBytes2;
        return _jsonResponse({'challenge': _buildChallengeToken(nonce)});
      }
      return _jsonResponse({'status': 'valid'});
    });

    final service = AppAttestService(client: client, isIOS: () => true);

    await service.attestDevice();
    await service.attestDevice();

    final generateKeyCalls = methodCalls.where((c) => c.method == 'generateKey');
    expect(generateKeyCalls.length, 1, reason: 'generateKey should only be called once per install');

    final attestKeyCalls = methodCalls.where((c) => c.method == 'attestKey');
    expect(attestKeyCalls.length, 2);
  });

  test('a failed attestKey drops the cached key so the next attempt generates a fresh one', () async {
    final nonceBytes = Uint8List.fromList(List.generate(32, (i) => i));
    final client = buildClient((req) async {
      final body = jsonDecode(utf8.decode(req.bodyBytes)) as Map<String, dynamic>;
      if (body['action'] == 'challenge') {
        return _jsonResponse({'challenge': _buildChallengeToken(nonceBytes)});
      }
      return _jsonResponse({'status': 'valid'});
    });
    final service = AppAttestService(client: client, isIOS: () => true);

    attestKeyShouldFail = true;
    expect(await service.attestDevice(), isFalse);

    attestKeyShouldFail = false;
    methodResponse = 'generated-key-2';
    expect(await service.attestDevice(), isTrue);

    expect(methodCalls.where((c) => c.method == 'generateKey').length, 2);
    final lastAttest = methodCalls.lastWhere((c) => c.method == 'attestKey');
    expect((lastAttest.arguments as Map)['keyId'], 'generated-key-2');
  });
}

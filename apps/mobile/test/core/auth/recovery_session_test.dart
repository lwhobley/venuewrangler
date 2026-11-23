import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:venuewrangler_mobile/core/auth/auth_providers.dart';
import 'package:venuewrangler_mobile/core/auth/recovery_session.dart';
import 'package:venuewrangler_mobile/core/storage/secure_session_storage.dart';

String _jwt(Map<String, Object?> claims) {
  String part(Object value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  return '${part({'alg': 'HS256', 'typ': 'JWT'})}.${part(claims)}.sig';
}

Session _sessionWithAmr(List<Object> amr) {
  final expiresAt = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600;
  return Session(
    accessToken: _jwt({
      'aal': 'aal1',
      'sub': 'u1',
      'exp': expiresAt,
      'amr': amr,
    }),
    tokenType: 'bearer',
    user: User(
      id: 'u1',
      appMetadata: const {},
      userMetadata: const {},
      aud: 'authenticated',
      createdAt: '2026-01-01T00:00:00Z',
      email: 'owner@example.com',
    ),
  );
}

class _MemoryStorage extends SecureSessionStorage {
  final map = <String, String>{};

  @override
  Future<String?> read(String key) async => map[key];

  @override
  Future<void> write(String key, String value) async => map[key] = value;

  @override
  Future<void> delete(String key) async => map.remove(key);
}

void main() {
  group('sessionLooksLikePasswordRecovery', () {
    test('is true when AMR includes recovery (object or string form)', () {
      expect(
        sessionLooksLikePasswordRecovery(
          _sessionWithAmr([
            {'method': 'recovery', 'timestamp': 1},
          ]),
        ),
        isTrue,
      );
      expect(
        sessionLooksLikePasswordRecovery(_sessionWithAmr(['recovery'])),
        isTrue,
      );
    });

    test('is false for normal password sessions and null', () {
      expect(
        sessionLooksLikePasswordRecovery(
          _sessionWithAmr([
            {'method': 'password', 'timestamp': 1},
          ]),
        ),
        isFalse,
      );
      expect(sessionLooksLikePasswordRecovery(null), isFalse);
    });
  });

  group('resolvePasswordRecoveryPending', () {
    test('uses the durable latch when present', () async {
      final storage = _MemoryStorage()
        ..map[passwordRecoveryStorageKey] = 'true';
      final pending = await resolvePasswordRecoveryPending(
        session: _sessionWithAmr([
          {'method': 'password', 'timestamp': 1},
        ]),
        storage: storage,
      );
      expect(pending, isTrue);
    });

    test('fail-closes on recovery AMR when the latch key is missing', () async {
      final storage = _MemoryStorage();
      final pending = await resolvePasswordRecoveryPending(
        session: _sessionWithAmr([
          {'method': 'recovery', 'timestamp': 1},
        ]),
        storage: storage,
      );
      expect(pending, isTrue);
      expect(storage.map[passwordRecoveryStorageKey], 'true');
    });

    test('is false with no session', () async {
      final pending = await resolvePasswordRecoveryPending(
        session: null,
        storage: _MemoryStorage(),
      );
      expect(pending, isFalse);
    });
  });
}

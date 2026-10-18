import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:venuewrangler_mobile/core/auth/auth_providers.dart';
import 'package:venuewrangler_mobile/core/auth/auth_repository.dart';
import 'package:venuewrangler_mobile/features/mfa/application/mfa_providers.dart';
import 'package:venuewrangler_mobile/features/mfa/domain/mfa_error.dart';
import 'package:venuewrangler_mobile/features/mfa/presentation/mfa_challenge_screen.dart';
import 'package:venuewrangler_mobile/features/mfa/presentation/mfa_enroll_screen.dart';
import 'package:venuewrangler_mobile/features/mfa/presentation/mfa_enrollment_banner.dart';
import 'package:venuewrangler_mobile/features/mfa/presentation/mfa_settings_screen.dart';
import 'package:venuewrangler_mobile/features/venues/application/venues_providers.dart';

import 'fake_mfa_repository.dart';

String _jwt(Map<String, Object?> claims) {
  String part(Object value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  return '${part({'alg': 'HS256', 'typ': 'JWT'})}.${part(claims)}.sig';
}

/// A client whose current session has the given AAL and factors, with no network involved
/// (the token is unexpired, so recovering it never refreshes).
Future<SupabaseClient> _clientWithSession({
  required String aal,
  required bool verifiedFactor,
}) async {
  final client = SupabaseClient('https://mfa.test', 'public-test-key');
  final expiresAt = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600;
  final nowIso = DateTime.now().toUtc().toIso8601String();
  await client.auth.recoverSession(
    jsonEncode({
      'access_token': _jwt({'aal': aal, 'sub': 'u1', 'exp': expiresAt}),
      'refresh_token': 'refresh',
      'token_type': 'bearer',
      'expires_in': 3600,
      'expires_at': expiresAt,
      'user': {
        'id': 'u1',
        'aud': 'authenticated',
        'app_metadata': <String, Object?>{},
        'user_metadata': <String, Object?>{},
        'created_at': nowIso,
        'factors': [
          if (verifiedFactor)
            {
              'id': 'f1',
              'friendly_name': 'Authenticator',
              'factor_type': 'totp',
              'status': 'verified',
              'created_at': nowIso,
              'updated_at': nowIso,
            },
        ],
      },
    }),
  );
  addTearDown(client.dispose);
  return client;
}

void main() {
  group('SupabaseMfaRepository.challengeRequired', () {
    test('is true only for an AAL1 session whose account has a verified factor',
        () async {
      final needsChallenge = SupabaseMfaRepository(
        await _clientWithSession(aal: 'aal1', verifiedFactor: true),
      );
      final alreadyVerified = SupabaseMfaRepository(
        await _clientWithSession(aal: 'aal2', verifiedFactor: true),
      );
      final noFactor = SupabaseMfaRepository(
        await _clientWithSession(aal: 'aal1', verifiedFactor: false),
      );

      expect(needsChallenge.challengeRequired, isTrue);
      expect(alreadyVerified.challengeRequired, isFalse);
      expect(noFactor.challengeRequired, isFalse);
    });

    test('is false when signed out', () {
      final client = SupabaseClient('https://mfa.test', 'public-test-key');
      addTearDown(client.dispose);

      expect(SupabaseMfaRepository(client).challengeRequired, isFalse);
    });
  });

  test('mfaErrorMessage explains a wrong code and a lost connection', () {
    expect(
      mfaErrorMessage(const AuthException('Invalid TOTP code entered')),
      contains("isn't correct"),
    );
    expect(
      mfaErrorMessage(AuthRetryableFetchException(message: 'offline')),
      contains('Could not reach the server'),
    );
    expect(mfaErrorMessage(StateError('x')), contains('Something went wrong'));
  });

  group('MfaChallengeScreen', () {
    Future<FakeMfaRepository> pump(WidgetTester tester) async {
      final repository = FakeMfaRepository(
        factors: [const MfaFactor(id: 'f1', verified: true)],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [mfaRepositoryProvider.overrideWithValue(repository)],
          child: const MaterialApp(home: MfaChallengeScreen()),
        ),
      );
      await tester.pumpAndSettle();
      return repository;
    }

    testWidgets('a valid code answers the challenge for the verified factor',
        (tester) async {
      final repository = await pump(tester);

      await tester.enterText(find.byType(TextField), '123456');
      await tester.tap(find.text('Verify'));
      await tester.pumpAndSettle();

      expect(repository.challenges, [('f1', '123456')]);
    });

    testWidgets('a short code is rejected without calling the server',
        (tester) async {
      final repository = await pump(tester);

      await tester.enterText(find.byType(TextField), '123');
      await tester.tap(find.text('Verify'));
      await tester.pumpAndSettle();

      expect(
        find.text('Enter the 6-digit code from your app.'),
        findsOneWidget,
      );
      expect(repository.challenges, isEmpty);
    });

    testWidgets('a wrong code shows a friendly error', (tester) async {
      final repository = await pump(tester);
      repository.challengeError = const AuthException('Invalid TOTP code');

      await tester.enterText(find.byType(TextField), '000000');
      await tester.tap(find.text('Verify'));
      await tester.pumpAndSettle();

      expect(find.textContaining("isn't correct"), findsOneWidget);
    });
  });

  group('enrollment', () {
    testWidgets('shows the setup key and activates with the first code',
        (tester) async {
      final repository = FakeMfaRepository();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [mfaRepositoryProvider.overrideWithValue(repository)],
          child: MaterialApp(
            home: Builder(
              builder: (context) => TextButton(
                onPressed: () => Navigator.of(context).push<bool>(
                  MaterialPageRoute(builder: (_) => const MfaEnrollScreen()),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('JBSWY3DPEHPK3PXP'), findsOneWidget);
      expect(find.text('Copy key'), findsOneWidget);

      await tester.enterText(find.byType(TextField), '654321');
      await tester.tap(find.text('Turn on two-factor authentication'));
      await tester.pumpAndSettle();

      expect(repository.verifications, [('new-factor', '654321')]);
      // The screen closed itself after activation.
      expect(find.text('JBSWY3DPEHPK3PXP'), findsNothing);
    });

    testWidgets('a wrong first code keeps the screen open with an error',
        (tester) async {
      final repository = FakeMfaRepository()
        ..verifyError = const AuthException('Invalid TOTP code');
      await tester.pumpWidget(
        ProviderScope(
          overrides: [mfaRepositoryProvider.overrideWithValue(repository)],
          child: const MaterialApp(home: MfaEnrollScreen()),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), '111111');
      await tester.tap(find.text('Turn on two-factor authentication'));
      await tester.pumpAndSettle();

      expect(find.textContaining("isn't correct"), findsOneWidget);
      expect(find.text('JBSWY3DPEHPK3PXP'), findsOneWidget);
    });
  });

  group('MfaSettingsScreen', () {
    testWidgets('lists verified authenticators and removes one after confirm',
        (tester) async {
      final repository = FakeMfaRepository(
        factors: [
          MfaFactor(id: 'f1', verified: true, createdAt: DateTime(2026, 9, 1)),
          const MfaFactor(id: 'pending', verified: false),
        ],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            mfaRepositoryProvider.overrideWithValue(repository),
            currentUserIdProvider.overrideWithValue('u1'),
          ],
          child: const MaterialApp(home: MfaSettingsScreen()),
        ),
      );
      await tester.pumpAndSettle();

      // Only the verified one is listed (the unverified leftover is hidden).
      expect(find.text('Authenticator app'), findsOneWidget);
      expect(find.text('Added 2026-09-01'), findsOneWidget);

      await tester.tap(find.byTooltip('Remove authenticator'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
      await tester.pumpAndSettle();

      expect(repository.unenrolled, ['f1']);
      expect(find.text('Set up authenticator app'), findsOneWidget);
    });
  });

  group('MfaEnrollmentBanner', () {
    Future<void> pump(
      WidgetTester tester, {
      required String role,
      required List<MfaFactor> factors,
    }) async {
      // A fresh scope each time: provider state must not carry over between calls.
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            mfaRepositoryProvider
                .overrideWithValue(FakeMfaRepository(factors: factors)),
            currentUserIdProvider.overrideWithValue('u1'),
            myVenueRoleProvider.overrideWith((ref) async => role),
          ],
          child: const MaterialApp(home: Scaffold(body: MfaEnrollmentBanner())),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('nudges an owner without a factor, and can be dismissed',
        (tester) async {
      await pump(tester, role: 'organization_owner', factors: const []);
      expect(find.text('Protect your account'), findsOneWidget);

      await tester.tap(find.byTooltip('Dismiss'));
      await tester.pumpAndSettle();

      expect(find.text('Protect your account'), findsNothing);
    });

    testWidgets('stays hidden for staff and for owners who enrolled',
        (tester) async {
      await pump(tester, role: 'staff', factors: const []);
      expect(find.text('Protect your account'), findsNothing);

      await pump(
        tester,
        role: 'organization_admin',
        factors: const [MfaFactor(id: 'f1', verified: true)],
      );
      expect(find.text('Protect your account'), findsNothing);
    });
  });

  test('shouldNudgeMfaEnrollmentProvider waits for the factors to load', () {
    final container = ProviderContainer(
      overrides: [
        mfaRepositoryProvider.overrideWithValue(FakeMfaRepository()),
        currentUserIdProvider.overrideWithValue('u1'),
        myVenueRoleProvider.overrideWith((ref) async => 'organization_owner'),
      ],
    );
    addTearDown(container.dispose);

    expect(container.read(shouldNudgeMfaEnrollmentProvider), isFalse);
  });
}

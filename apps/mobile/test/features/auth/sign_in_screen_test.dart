import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:venuewrangler_mobile/core/auth/auth_providers.dart';
import 'package:venuewrangler_mobile/core/auth/auth_repository.dart';
import 'package:venuewrangler_mobile/features/auth/sign_in_screen.dart';

class _FakeAuthRepository implements AuthRepository {
  bool signInCalled = false;

  @override
  Session? get currentSession => null;

  @override
  Future<void> signInWithPassword({
    required String email,
    required String password,
  }) async {
    signInCalled = true;
  }

  @override
  Future<bool> signUpWithPassword({
    required String email,
    required String password,
    Map<String, dynamic>? data,
  }) async =>
      false;

  String? resetEmail;

  @override
  Future<void> sendPasswordResetEmail(String email) async {
    resetEmail = email;
  }

  @override
  Future<void> updatePassword(String newPassword) async {}

  @override
  Future<void> signOut() async {}
}

void main() {
  testWidgets(
      'shows a validation error and does not sign in with an empty form', (
    tester,
  ) async {
    final fakeAuth = _FakeAuthRepository();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [authRepositoryProvider.overrideWithValue(fakeAuth)],
        child: const MaterialApp(home: SignInScreen()),
      ),
    );

    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pump();

    expect(find.text('Enter a valid email'), findsOneWidget);
    expect(fakeAuth.signInCalled, isFalse);
  });

  testWidgets('calls the auth repository with a valid email and password',
      (tester) async {
    final fakeAuth = _FakeAuthRepository();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [authRepositoryProvider.overrideWithValue(fakeAuth)],
        child: const MaterialApp(home: SignInScreen()),
      ),
    );

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Email'),
      'owner@example.com',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Password'),
      'correct horse',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pumpAndSettle();

    expect(fakeAuth.signInCalled, isTrue);
  });

  group('rejected email links (launch review A2)', () {
    testWidgets('explain the link expired and offer a new one', (tester) async {
      final fakeAuth = _FakeAuthRepository();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authRepositoryProvider.overrideWithValue(fakeAuth),
            authLinkErrorProvider.overrideWith((ref) => true),
          ],
          child: const MaterialApp(home: SignInScreen()),
        ),
      );

      expect(
        find.textContaining('expired or was already used'),
        findsOneWidget,
      );

      await tester.tap(find.text('Send a new reset link'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextField),
        ),
        'host@example.com',
      );
      await tester.tap(find.text('Send link'));
      await tester.pumpAndSettle();

      expect(fakeAuth.resetEmail, 'host@example.com');
      expect(find.textContaining('expired or was already used'), findsNothing);
    });

    testWidgets('no notice on a plain sign-in', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authRepositoryProvider.overrideWithValue(_FakeAuthRepository()),
          ],
          child: const MaterialApp(home: SignInScreen()),
        ),
      );

      expect(find.textContaining('expired or was already used'), findsNothing);
    });

    test('only link failures count, not refresh or network errors', () {
      expect(
        isRejectedAuthLink(
          const AuthException(
            'Email link is invalid or has expired',
            statusCode: 'otp_expired',
            code: 'access_denied',
          ),
        ),
        isTrue,
      );
      expect(
        isRejectedAuthLink(
          const AuthException(
            'Code verifier could not be found in local storage.',
          ),
        ),
        isTrue,
      );
      expect(
        isRejectedAuthLink(AuthRetryableFetchException(message: 'offline')),
        isFalse,
      );
      expect(
        isRejectedAuthLink(const AuthException('Invalid Refresh Token')),
        isFalse,
      );
      expect(isRejectedAuthLink(Exception('boom')), isFalse);
    });
  });
}

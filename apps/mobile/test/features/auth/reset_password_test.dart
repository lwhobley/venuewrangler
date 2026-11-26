import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:venuewrangler_mobile/core/auth/auth_providers.dart';
import 'package:venuewrangler_mobile/core/auth/auth_repository.dart';
import 'package:venuewrangler_mobile/core/storage/secure_session_storage.dart';
import 'package:venuewrangler_mobile/features/auth/reset_password_screen.dart';
import 'package:venuewrangler_mobile/features/auth/sign_in_screen.dart';

class _Auth implements AuthRepository {
  String? resetEmail;
  String? newPassword;

  @override
  Session? get currentSession => null;

  @override
  Future<void> sendPasswordResetEmail(String email) async => resetEmail = email;

  @override
  Future<void> updatePassword(String password) async => newPassword = password;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _RecoveryStorage extends SecureSessionStorage {
  bool cleared = false;

  @override
  Future<void> delete(String key) async {
    if (key == passwordRecoveryStorageKey) cleared = true;
  }
}

void main() {
  test('password policy mirrors the project rules', () {
    expect(passwordPolicyProblem('Abcdefg1!'), 'Use at least 12 characters');
    expect(passwordPolicyProblem('abcdefghij1!'), 'Add an uppercase letter');
    expect(passwordPolicyProblem('ABCDEFGHIJ1!'), 'Add a lowercase letter');
    expect(passwordPolicyProblem('Abcdefghijk!'), 'Add a number');
    expect(passwordPolicyProblem('Abcdefghij12'), 'Add a symbol');
    expect(passwordPolicyProblem('Abcdefghij1!'), isNull);
  });

  group('reset link redirect per platform (F06)', () {
    String forPlatform(TargetPlatform platform, {bool isWeb = false}) =>
        passwordResetRedirectFor(
          isWeb: isWeb,
          platform: platform,
          webOrigin: 'https://venuewrangler.com',
        );

    test('iOS uses the verified Universal Link', () {
      expect(
        forPlatform(TargetPlatform.iOS),
        'https://venuewrangler.com/reset-password',
      );
      expect(kPasswordResetUniversalLink, forPlatform(TargetPlatform.iOS));
    });

    test('Android keeps the custom scheme until App Links verify', () {
      expect(
        forPlatform(TargetPlatform.android),
        'venuewrangler://reset-password',
      );
    });

    test('web returns to the Flutter web app on the requesting origin', () {
      expect(
        forPlatform(TargetPlatform.iOS, isWeb: true),
        'https://venuewrangler.com/app/',
      );
      expect(
        forPlatform(TargetPlatform.android, isWeb: true),
        'https://venuewrangler.com/app/',
      );
    });

    test('the running build uses the rule for its own platform', () {
      // flutter_test reports Android as the default target platform.
      expect(passwordResetRedirect(), kPasswordResetRedirect);
    });
  });

  testWidgets('forgot password sends a reset email for the typed address',
      (tester) async {
    final auth = _Auth();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [authRepositoryProvider.overrideWithValue(auth)],
        child: const MaterialApp(home: SignInScreen()),
      ),
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Email'),
      'someone@example.com',
    );
    await tester.tap(find.text('Forgot password?'));
    await tester.pumpAndSettle();
    expect(find.text('Reset password'), findsOneWidget);

    await tester.tap(find.text('Send link'));
    await tester.pumpAndSettle();

    expect(auth.resetEmail, 'someone@example.com');
    expect(find.textContaining('reset link is on its way'), findsOneWidget);
  });

  testWidgets('reset screen enforces the policy, then saves and releases hold',
      (tester) async {
    final auth = _Auth();
    final storage = _RecoveryStorage();
    final container = ProviderContainer(
      overrides: [
        authRepositoryProvider.overrideWithValue(auth),
        passwordRecoveryStorageProvider.overrideWithValue(storage),
      ],
    );
    addTearDown(container.dispose);
    container.read(passwordRecoveryPendingProvider.notifier).state = true;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: ResetPasswordScreen()),
      ),
    );

    await tester.enterText(
      find.widgetWithText(TextFormField, 'New password'),
      'weakpassword',
    );
    await tester.tap(find.text('Save password'));
    await tester.pump();
    expect(find.text('Add an uppercase letter'), findsOneWidget);
    expect(auth.newPassword, isNull);

    await tester.enterText(
      find.widgetWithText(TextFormField, 'New password'),
      'Stronger123!',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Confirm new password'),
      'Different12!',
    );
    await tester.tap(find.text('Save password'));
    await tester.pump();
    expect(find.text("Passwords don't match"), findsOneWidget);

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Confirm new password'),
      'Stronger123!',
    );
    await tester.tap(find.text('Save password'));
    await tester.pumpAndSettle();

    expect(auth.newPassword, 'Stronger123!');
    expect(storage.cleared, isTrue);
    expect(container.read(passwordRecoveryPendingProvider), isFalse);
  });
}

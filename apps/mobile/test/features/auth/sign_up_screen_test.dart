import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:venuewrangler_mobile/core/auth/auth_providers.dart';
import 'package:venuewrangler_mobile/core/auth/auth_repository.dart';
import 'package:venuewrangler_mobile/features/auth/sign_up_screen.dart';

class _FakeAuthRepository implements AuthRepository {
  bool signUpCalled = false;
  String? capturedEmail;
  String? capturedWorkspaceName;
  bool sessionOnSignUp = true;

  @override
  Session? get currentSession => null;

  @override
  Future<void> signInWithPassword({
    required String email,
    required String password,
  }) async {}

  @override
  Future<bool> signUpWithPassword({
    required String email,
    required String password,
    Map<String, dynamic>? data,
  }) async {
    signUpCalled = true;
    capturedEmail = email;
    capturedWorkspaceName = data?['pending_workspace_name'] as String?;
    return sessionOnSignUp;
  }

  @override
  Future<void> sendPasswordResetEmail(String email) async {}

  @override
  Future<void> updatePassword(String newPassword) async {}

  @override
  Future<void> signOut() async {}
}

void main() {
  testWidgets('shows validation errors and does not sign up with an empty form',
      (tester) async {
    final fakeAuth = _FakeAuthRepository();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [authRepositoryProvider.overrideWithValue(fakeAuth)],
        child: const MaterialApp(home: SignUpScreen()),
      ),
    );

    final submitButton =
        find.widgetWithText(FilledButton, "Let's get you in command");
    await tester.ensureVisible(submitButton);
    await tester.tap(submitButton);
    await tester.pump();

    expect(find.text('Enter your venue name'), findsOneWidget);
    expect(find.text('Enter a valid email'), findsOneWidget);
    expect(fakeAuth.signUpCalled, isFalse);
  });

  testWidgets(
      'signs up with the venue name stashed as pending workspace metadata',
      (tester) async {
    final fakeAuth = _FakeAuthRepository();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [authRepositoryProvider.overrideWithValue(fakeAuth)],
        child: const MaterialApp(home: SignUpScreen()),
      ),
    );

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Venue name'),
      'The Riverside Taphouse',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Work email'),
      'owner@example.com',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Password'),
      'Correct-Horse-1',
    );
    final submitButton =
        find.widgetWithText(FilledButton, "Let's get you in command");
    await tester.ensureVisible(submitButton);
    await tester.tap(submitButton);
    await tester.pumpAndSettle();

    expect(fakeAuth.signUpCalled, isTrue);
    expect(fakeAuth.capturedEmail, 'owner@example.com');
    expect(fakeAuth.capturedWorkspaceName, 'The Riverside Taphouse');
    // A session came back immediately, so the router (not this screen) takes over —
    // no "check your email" panel.
    expect(find.text('Check your email'), findsNothing);
  });

  testWidgets('shows a check-your-email panel when no session is returned',
      (tester) async {
    final fakeAuth = _FakeAuthRepository()..sessionOnSignUp = false;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [authRepositoryProvider.overrideWithValue(fakeAuth)],
        child: const MaterialApp(home: SignUpScreen()),
      ),
    );

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Venue name'),
      'The Riverside Taphouse',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Work email'),
      'owner@example.com',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Password'),
      'Correct-Horse-1',
    );
    final submitButton =
        find.widgetWithText(FilledButton, "Let's get you in command");
    await tester.ensureVisible(submitButton);
    await tester.tap(submitButton);
    await tester.pumpAndSettle();

    expect(find.text('Check your email'), findsOneWidget);
    expect(find.textContaining('owner@example.com'), findsOneWidget);
  });
}

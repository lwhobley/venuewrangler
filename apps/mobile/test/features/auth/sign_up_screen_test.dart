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
  String? capturedTimezone;
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
    capturedTimezone = data?['pending_timezone'] as String?;
    return sessionOnSignUp;
  }

  @override
  Future<void> sendPasswordResetEmail(String email) async {}

  @override
  Future<void> updatePassword(String newPassword) async {}

  @override
  Future<void> signOut() async {}
}

/// Picks a time zone explicitly: the picker pre-selects the device's zone only when it can
/// tell it apart, which depends on the machine running the test (CI is UTC: no guess).
Future<void> _selectTimezone(WidgetTester tester, String label) async {
  final dropdown = find.byType(DropdownButtonFormField<String>);
  await tester.ensureVisible(dropdown);
  await tester.tap(dropdown);
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

Future<void> _fillAndSubmit(
  WidgetTester tester, {
  required String venueName,
  required String timezoneLabel,
}) async {
  await tester.enterText(
    find.widgetWithText(TextFormField, 'Venue name'),
    venueName,
  );
  await tester.enterText(
    find.widgetWithText(TextFormField, 'Work email'),
    'owner@example.com',
  );
  await tester.enterText(
    find.widgetWithText(TextFormField, 'Password'),
    'Correct-Horse-1',
  );
  await _selectTimezone(tester, timezoneLabel);
  final submitButton =
      find.widgetWithText(FilledButton, "Let's get you in command");
  await tester.ensureVisible(submitButton);
  await tester.tap(submitButton);
  await tester.pumpAndSettle();
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

  Future<_FakeAuthRepository> pumpSignUp(
    WidgetTester tester, {
    bool sessionOnSignUp = true,
  }) async {
    final fakeAuth = _FakeAuthRepository()..sessionOnSignUp = sessionOnSignUp;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [authRepositoryProvider.overrideWithValue(fakeAuth)],
        child: const MaterialApp(home: SignUpScreen()),
      ),
    );
    return fakeAuth;
  }

  testWidgets(
      'signs up with the venue name and time zone stashed as pending workspace metadata',
      (tester) async {
    final fakeAuth = await pumpSignUp(tester);

    await _fillAndSubmit(
      tester,
      venueName: 'The Riverside Taphouse',
      timezoneLabel: 'Central (Chicago)',
    );

    expect(fakeAuth.signUpCalled, isTrue);
    expect(fakeAuth.capturedEmail, 'owner@example.com');
    expect(fakeAuth.capturedWorkspaceName, 'The Riverside Taphouse');
    expect(fakeAuth.capturedTimezone, 'America/Chicago');
    // A session came back immediately, so the router (not this screen) takes over —
    // no "check your email" panel.
    expect(find.text('Check your email'), findsNothing);
  });

  testWidgets('stores whichever time zone was chosen, not a fixed default',
      (tester) async {
    final fakeAuth = await pumpSignUp(tester);

    await _fillAndSubmit(
      tester,
      venueName: 'Harbor Room',
      timezoneLabel: 'Pacific (Los Angeles)',
    );

    expect(fakeAuth.capturedTimezone, 'America/Los_Angeles');
  });

  testWidgets('shows a check-your-email panel when no session is returned',
      (tester) async {
    await pumpSignUp(tester, sessionOnSignUp: false);

    await _fillAndSubmit(
      tester,
      venueName: 'The Riverside Taphouse',
      timezoneLabel: 'Central (Chicago)',
    );

    expect(find.text('Check your email'), findsOneWidget);
    expect(find.textContaining('owner@example.com'), findsOneWidget);
  });

  testWidgets('rejects a venue name longer than the database allows',
      (tester) async {
    final fakeAuth = await pumpSignUp(tester);

    await _fillAndSubmit(
      tester,
      venueName: 'x' * 121,
      timezoneLabel: 'Central (Chicago)',
    );

    expect(find.text('Use 120 characters or fewer'), findsOneWidget);
    expect(fakeAuth.signUpCalled, isFalse);
  });

  testWidgets('accepts a venue name of exactly the maximum length',
      (tester) async {
    final fakeAuth = await pumpSignUp(tester);

    await _fillAndSubmit(
      tester,
      venueName: 'x' * 120,
      timezoneLabel: 'Central (Chicago)',
    );

    expect(fakeAuth.signUpCalled, isTrue);
    expect(fakeAuth.capturedWorkspaceName, hasLength(120));
  });
}

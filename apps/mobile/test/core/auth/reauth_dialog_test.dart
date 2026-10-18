import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:venuewrangler_mobile/core/auth/auth_providers.dart';
import 'package:venuewrangler_mobile/core/auth/auth_repository.dart';
import 'package:venuewrangler_mobile/core/auth/reauth_dialog.dart';

import '../../features/mfa/fake_mfa_repository.dart';

class _FakeAuthRepository implements AuthRepository {
  _FakeAuthRepository(this.session);

  final Session? session;
  final signIns = <(String, String)>[];

  @override
  Session? get currentSession => session;

  @override
  Future<void> signInWithPassword({
    required String email,
    required String password,
  }) async {
    if (password == 'wrong') {
      throw const AuthException('Invalid login credentials');
    }
    signIns.add((email, password));
  }

  @override
  Future<bool> signUpWithPassword({
    required String email,
    required String password,
    Map<String, dynamic>? data,
  }) async =>
      false;

  @override
  Future<void> sendPasswordResetEmail(String email) async {}

  @override
  Future<void> updatePassword(String newPassword) async {}

  @override
  Future<void> signOut() async {}
}

Session _session({
  Map<String, dynamic> appMetadata = const {
    'provider': 'email',
    'providers': ['email'],
  },
  List<Factor>? factors,
}) =>
    Session(
      accessToken: 'token',
      tokenType: 'bearer',
      user: User(
        id: 'u1',
        appMetadata: appMetadata,
        userMetadata: const {},
        aud: 'authenticated',
        createdAt: '2026-01-01T00:00:00Z',
        email: 'owner@example.com',
        factors: factors,
      ),
    );

void main() {
  bool? result;

  Future<void> pumpTrigger(
    WidgetTester tester, {
    required _FakeAuthRepository auth,
    FakeMfaRepository? mfa,
  }) async {
    result = null;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authRepositoryProvider.overrideWithValue(auth),
          mfaRepositoryProvider.overrideWithValue(mfa ?? FakeMfaRepository()),
        ],
        child: MaterialApp(
          home: Consumer(
            builder: (context, ref, _) => TextButton(
              onPressed: () async =>
                  result = await confirmPasswordReauth(context, ref),
              child: const Text('go'),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('skips the prompt for accounts without a password',
      (tester) async {
    await pumpTrigger(
      tester,
      auth: _FakeAuthRepository(
        _session(
          appMetadata: {
            'provider': 'google',
            'providers': ['google'],
          },
        ),
      ),
    );

    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();

    expect(result, isTrue);
    expect(find.text('Confirm your password'), findsNothing);
  });

  testWidgets('skips the prompt when there is no session', (tester) async {
    await pumpTrigger(tester, auth: _FakeAuthRepository(null));

    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();

    expect(result, isTrue);
  });

  testWidgets('the right password lets the action continue', (tester) async {
    final auth = _FakeAuthRepository(_session());
    await pumpTrigger(tester, auth: auth);

    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(find.text('Confirm your password'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'Correct-Horse-1');
    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();

    expect(result, isTrue);
    expect(auth.signIns, [('owner@example.com', 'Correct-Horse-1')]);
  });

  testWidgets('a wrong password keeps the dialog open and blocks the action',
      (tester) async {
    final auth = _FakeAuthRepository(_session());
    await pumpTrigger(tester, auth: auth);

    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'wrong');
    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();

    expect(find.text("That password isn't correct."), findsOneWidget);
    expect(result, isNull);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(result, isFalse);
  });

  testWidgets('an account with an authenticator also needs a valid code',
      (tester) async {
    final auth = _FakeAuthRepository(
      _session(
        factors: [
          Factor(
            id: 'f1',
            friendlyName: 'Authenticator',
            factorType: FactorType.totp,
            status: FactorStatus.verified,
            createdAt: DateTime(2026),
            updatedAt: DateTime(2026),
          ),
        ],
      ),
    );
    final mfa = FakeMfaRepository();
    await pumpTrigger(tester, auth: auth, mfa: mfa);

    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(find.text('Authenticator code'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, 'Correct-Horse-1');
    await tester.enterText(find.byType(TextField).last, '123456');
    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();

    expect(result, isTrue);
    expect(mfa.challenges, [('f1', '123456')]);
  });
}

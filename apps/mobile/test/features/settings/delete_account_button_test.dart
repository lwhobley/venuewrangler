import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:venuewrangler_mobile/core/auth/auth_providers.dart';
import 'package:venuewrangler_mobile/core/auth/auth_repository.dart';
import 'package:venuewrangler_mobile/features/settings/application/settings_providers.dart';
import 'package:venuewrangler_mobile/features/settings/data/settings_repository.dart';
import 'package:venuewrangler_mobile/features/settings/domain/profile.dart';
import 'package:venuewrangler_mobile/features/settings/presentation/delete_account_button.dart';

import '../mfa/fake_mfa_repository.dart';

class _FakeAuthRepository implements AuthRepository {
  /// A signed-in email/password user when set; null means no password to re-enter.
  Session? session;
  bool signOutCalled = false;
  final signIns = <String>[];

  @override
  Session? get currentSession => session;

  @override
  Future<void> signInWithPassword({
    required String email,
    required String password,
  }) async {
    if (password == 'wrong') throw const AuthException('Invalid credentials');
    signIns.add(password);
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
  Future<void> signOut() async {
    signOutCalled = true;
  }
}

class _FakeSettingsRepository implements SettingsRepository {
  _FakeSettingsRepository({this.deletionError, this.deleteGate});

  /// Thrown by [deleteAccount] if set — e.g. the sole-owner guard's 42501.
  final PostgrestException? deletionError;

  /// When set, [deleteAccount] holds until this completes (simulates an in-flight request).
  final Completer<void>? deleteGate;
  bool deleteAccountCalled = false;

  @override
  Future<Profile> fetchMyProfile(String userId) async =>
      const Profile(id: 'u1');

  @override
  Future<void> updateDisplayName(String userId, String displayName) async {}

  @override
  Future<void> deleteAccount({String? reason}) async {
    deleteAccountCalled = true;
    if (deleteGate != null) await deleteGate!.future;
    if (deletionError != null) throw deletionError!;
  }
}

void main() {
  Future<void> pumpButton(
    WidgetTester tester, {
    required SettingsRepository settingsRepository,
    required AuthRepository authRepository,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsRepositoryProvider.overrideWithValue(settingsRepository),
          authRepositoryProvider.overrideWithValue(authRepository),
          mfaRepositoryProvider.overrideWithValue(FakeMfaRepository()),
        ],
        child: const MaterialApp(
          home: Scaffold(body: DeleteAccountButton()),
        ),
      ),
    );
  }

  Session passwordSession() => Session(
        accessToken: 'token',
        tokenType: 'bearer',
        user: User(
          id: 'u1',
          appMetadata: const {
            'provider': 'email',
            'providers': ['email'],
          },
          userMetadata: const {},
          aud: 'authenticated',
          createdAt: '2026-01-01T00:00:00Z',
          email: 'owner@example.com',
        ),
      );

  testWidgets('cancelling the confirmation dialog does not delete anything',
      (tester) async {
    final settingsRepo = _FakeSettingsRepository();
    final authRepo = _FakeAuthRepository();
    await pumpButton(
      tester,
      settingsRepository: settingsRepo,
      authRepository: authRepo,
    );

    await tester.tap(find.text('Delete account'));
    await tester.pumpAndSettle();
    expect(find.text('Delete your account?'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(settingsRepo.deleteAccountCalled, isFalse);
    expect(authRepo.signOutCalled, isFalse);
  });

  testWidgets('confirming deletes the account and signs out', (tester) async {
    final settingsRepo = _FakeSettingsRepository();
    final authRepo = _FakeAuthRepository();
    await pumpButton(
      tester,
      settingsRepository: settingsRepo,
      authRepository: authRepo,
    );

    // Confirming leads into the real signOutAndClearScopedData, which calls
    // flutter_secure_storage/the offline queue - real platform-channel Futures that
    // FakeAsync (plain pump/pumpAndSettle) never resolves, so this whole interaction needs
    // runAsync's real event loop.
    await tester.runAsync(() async {
      await tester.tap(find.text('Delete account'));
      await tester.pumpAndSettle();
      // Two "Delete account" texts now: the TextButton underneath the dialog and the
      // dialog's own destructive action button.
      await tester.tap(find.text('Delete account').last);
      await tester.pumpAndSettle();
      // pumpAndSettle only waits for pending *frames*, not for real (non-fake-clock)
      // Futures still in flight - signOutAndClearScopedData's platform-channel calls
      // resolve in real wall-clock time under runAsync, so give them a beat to finish.
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });

    expect(settingsRepo.deleteAccountCalled, isTrue);
    expect(authRepo.signOutCalled, isTrue);
  });

  testWidgets('signs out even if the widget is unmounted while deleting',
      (tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    final gate = Completer<void>();
    final settingsRepo = _FakeSettingsRepository(deleteGate: gate);
    final authRepo = _FakeAuthRepository();
    // A long-lived root container (as the app's ProviderScope is), so unmounting only the
    // button does not dispose the container sign-out needs.
    final container = ProviderContainer(
      overrides: [
        settingsRepositoryProvider.overrideWithValue(settingsRepo),
        authRepositoryProvider.overrideWithValue(authRepo),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(body: DeleteAccountButton()),
        ),
      ),
    );

    await tester.runAsync(() async {
      await tester.tap(find.text('Delete account'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete account').last);
      await tester.pumpAndSettle();
      // Unmount the button while the deletion request is still in flight.
      await tester.pumpWidget(const SizedBox());
      gate.complete();
      for (var i = 0; i < 10 && !authRepo.signOutCalled; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });

    expect(settingsRepo.deleteAccountCalled, isTrue);
    expect(tester.takeException(), isNull);
    expect(authRepo.signOutCalled, isTrue);
  });

  testWidgets(
      'a sole-owner rejection surfaces the server message and does not sign out',
      (tester) async {
    final settingsRepo = _FakeSettingsRepository(
      deletionError: const PostgrestException(
        message:
            'You are the only owner of 1 organization(s). Add another organization owner '
            'before deleting your account.',
        code: '42501',
      ),
    );
    final authRepo = _FakeAuthRepository();
    await pumpButton(
      tester,
      settingsRepository: settingsRepo,
      authRepository: authRepo,
    );

    await tester.tap(find.text('Delete account'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete account').last);
    await tester.pumpAndSettle();

    expect(settingsRepo.deleteAccountCalled, isTrue);
    expect(authRepo.signOutCalled, isFalse);
    expect(
      find.textContaining('the only owner of 1 organization'),
      findsOneWidget,
    );
  });

  testWidgets('a password account must re-enter its password before deletion',
      (tester) async {
    final settingsRepo = _FakeSettingsRepository();
    final authRepo = _FakeAuthRepository()..session = passwordSession();
    await pumpButton(
      tester,
      settingsRepository: settingsRepo,
      authRepository: authRepo,
    );

    await tester.tap(find.text('Delete account'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete account').last);
    await tester.pumpAndSettle();

    // The destructive confirmation is followed by the password step-up.
    expect(find.text('Confirm to delete your account'), findsOneWidget);
    expect(settingsRepo.deleteAccountCalled, isFalse);

    // A wrong password does not delete anything.
    await tester.enterText(find.byType(TextField), 'wrong');
    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();
    expect(find.text("That password isn't correct."), findsOneWidget);
    expect(settingsRepo.deleteAccountCalled, isFalse);

    // Cancelling abandons the deletion.
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(settingsRepo.deleteAccountCalled, isFalse);
    expect(authRepo.signOutCalled, isFalse);
  });

  testWidgets('the right password lets the deletion proceed', (tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    final settingsRepo = _FakeSettingsRepository();
    final authRepo = _FakeAuthRepository()..session = passwordSession();
    await pumpButton(
      tester,
      settingsRepository: settingsRepo,
      authRepository: authRepo,
    );

    await tester.runAsync(() async {
      await tester.tap(find.text('Delete account'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete account').last);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Correct-Horse-1');
      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });

    expect(authRepo.signIns, ['Correct-Horse-1']);
    expect(settingsRepo.deleteAccountCalled, isTrue);
    expect(authRepo.signOutCalled, isTrue);
  });
}

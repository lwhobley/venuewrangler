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

class _FakeAuthRepository implements AuthRepository {
  bool signOutCalled = false;

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
  _FakeSettingsRepository({this.deletionError});

  /// Thrown by [deleteAccount] if set — e.g. the sole-owner guard's 42501.
  final PostgrestException? deletionError;
  bool deleteAccountCalled = false;

  @override
  Future<Profile> fetchMyProfile(String userId) async =>
      const Profile(id: 'u1');

  @override
  Future<void> updateDisplayName(String userId, String displayName) async {}

  @override
  Future<void> deleteAccount({String? reason}) async {
    deleteAccountCalled = true;
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
        ],
        child: const MaterialApp(
          home: Scaffold(body: DeleteAccountButton()),
        ),
      ),
    );
  }

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
}

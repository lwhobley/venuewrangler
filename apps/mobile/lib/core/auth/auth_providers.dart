import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../network/supabase_providers.dart';
import 'auth_repository.dart';

final authRepositoryProvider = Provider<AuthRepository>((ref) {
  final client = ref.watch(supabaseClientProvider);
  return SupabaseAuthRepository(client);
});

/// `true` once `authStateChangesProvider` has confirmed there is a signed-in session.
/// `go_router`'s redirect logic (app/router.dart) watches this to decide between the auth
/// flow and the authenticated app shell.
final isSignedInProvider = Provider<bool>((ref) {
  final authState = ref.watch(authStateChangesProvider);
  return authState.maybeWhen(
    data: (state) => state.session != null,
    orElse: () => ref.read(authRepositoryProvider).currentSession != null,
  );
});

final currentUserIdProvider = Provider<String?>((ref) {
  final authState = ref.watch(authStateChangesProvider);
  return authState.maybeWhen(
    data: (state) => state.session?.user.id,
    orElse: () => ref.read(authRepositoryProvider).currentSession?.user.id,
  );
});

/// True from the moment a password-reset link signs the user in until they set a new
/// password (or sign out). While true the router keeps them on /reset-password, so a recovery
/// session can't be used to wander into the app without choosing a password.
final passwordRecoveryPendingProvider = StateProvider<bool>((ref) => false);

/// Side-effect only, watched once at the app root: flips [passwordRecoveryPendingProvider]
/// when Supabase reports a password-recovery sign-in, and clears it on sign-out.
final passwordRecoveryTriggerProvider = Provider<void>((ref) {
  ref.listen<AsyncValue<AuthState>>(
    authStateChangesProvider,
    (_, next) {
      final event = next.valueOrNull?.event;
      final pending = ref.read(passwordRecoveryPendingProvider.notifier);
      if (event == AuthChangeEvent.passwordRecovery) pending.state = true;
      if (event == AuthChangeEvent.signedOut) pending.state = false;
    },
    fireImmediately: true,
  );
});

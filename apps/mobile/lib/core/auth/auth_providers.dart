import 'dart:async';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../network/supabase_providers.dart';
import '../storage/secure_session_storage.dart';
import 'auth_repository.dart';

const passwordRecoveryStorageKey = 'password_recovery_pending';
final passwordRecoveryStorageProvider = Provider<SecureSessionStorage>(
  (ref) => const SecureSessionStorage(),
);

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

/// Set when the app was opened from an emailed auth link (password reset, email
/// confirmation) that Supabase rejected: expired (15 minutes, `otp_expiry`), already used, or
/// opened in a different browser/device from the one that asked for it (PKCE). The sign-in
/// screen explains it and offers a new link (launch review A2: it used to show plain sign-in).
final authLinkErrorProvider = StateProvider<bool>((ref) => false);

/// Whether [error], reported on the auth state stream, is a rejected email link rather than,
/// say, a failed token refresh.
@visibleForTesting
bool isRejectedAuthLink(Object error) {
  if (error is! AuthException || error is AuthRetryableFetchException) {
    return false;
  }
  const codes = {
    'otp_expired',
    'access_denied',
    'flow_state_not_found',
    'flow_state_expired',
    'bad_code_verifier',
  };
  final message = error.message.toLowerCase();
  return codes.contains(error.code) ||
      codes.contains(error.statusCode) ||
      error is AuthPKCEGrantCodeExchangeError ||
      message.contains('code verifier') ||
      message.contains('invalid or has expired');
}

/// Side-effect only, watched once at the app root: flips [passwordRecoveryPendingProvider]
/// when Supabase reports a password-recovery sign-in, and clears it on sign-out. Also records
/// a rejected email link for [authLinkErrorProvider].
final passwordRecoveryTriggerProvider = Provider<void>((ref) {
  ref.listen<AsyncValue<AuthState>>(
    authStateChangesProvider,
    (_, next) {
      final error = next.error;
      if (next.hasError && error != null && isRejectedAuthLink(error)) {
        // Outside this callback: it can run while providers are still initialising.
        scheduleMicrotask(
          () => ref.read(authLinkErrorProvider.notifier).state = true,
        );
        return;
      }
      final event = next.valueOrNull?.event;
      final pending = ref.read(passwordRecoveryPendingProvider.notifier);
      if (event == AuthChangeEvent.passwordRecovery) {
        pending.state = true;
        unawaited(
          ref
              .read(passwordRecoveryStorageProvider)
              .write(passwordRecoveryStorageKey, 'true'),
        );
      }
      if (event == AuthChangeEvent.signedOut) {
        pending.state = false;
        unawaited(
          ref
              .read(passwordRecoveryStorageProvider)
              .delete(passwordRecoveryStorageKey),
        );
      }
    },
    fireImmediately: true,
  );
});

final mfaRepositoryProvider = Provider<MfaRepository>((ref) {
  return SupabaseMfaRepository(ref.watch(supabaseClientProvider));
});

/// True while the session is AAL1 but the account has a verified authenticator, so the router
/// holds the user on /mfa-challenge. Re-evaluated on every auth event (sign-in, token refresh,
/// `mfaChallengeVerified`, sign-out) because the answer lives in the session's JWT.
final mfaChallengeRequiredProvider = Provider<bool>((ref) {
  ref.watch(authStateChangesProvider);
  return ref.watch(mfaRepositoryProvider).challengeRequired;
});

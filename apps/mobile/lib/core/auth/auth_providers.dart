import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../network/supabase_providers.dart';
import '../storage/secure_session_storage.dart';
import 'auth_repository.dart';
import 'recovery_session.dart';

const expiredAuthLinkMessage =
    'This link has expired or was already used. Tap Forgot password? to request a new reset link.';
final authCallbackErrorProvider = StateProvider<String?>((ref) => null);
String? authCallbackProblem(Uri uri) {
  final fragment =
      Uri.tryParse('https://callback/?${uri.fragment}')?.queryParameters ??
          const <String, String>{};
  return uri.queryParameters.containsKey('error') ||
          fragment.containsKey('error')
      ? expiredAuthLinkMessage
      : null;
}

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

/// True while the signed-in account was created by an admin with a starting password
/// (scripts/import-staff.py sets `user_metadata.must_change_password`). The router holds the
/// person on /reset-password until they choose their own; [AuthRepository.updatePassword]
/// clears the flag. Re-evaluated on every auth event, including `userUpdated`.
final mustChangePasswordProvider = Provider<bool>((ref) {
  final authState = ref.watch(authStateChangesProvider);
  Session? session;
  try {
    session = authState.maybeWhen(
      data: (state) => state.session,
      orElse: () => ref.read(authRepositoryProvider).currentSession,
    );
  } catch (_) {
    // No auth client (some tests): nothing to enforce.
    return false;
  }
  return session?.user.userMetadata?['must_change_password'] == true;
});

/// True from the moment a password-reset link signs the user in until they set a new
/// password (or sign out). While true the router keeps them on /reset-password, so a recovery
/// session can't be used to wander into the app without choosing a password.
final passwordRecoveryPendingProvider = StateProvider<bool>((ref) => false);

/// True while [confirmPasswordReauth] is open. The router suspends `/mfa-challenge`
/// redirects so a mid-dialog AAL1 session from `signInWithPassword` cannot tear away
/// the step-up UI before TOTP restores AAL2.
final reauthInProgressProvider = StateProvider<bool>((ref) => false);

/// Extra MFA hold for password-recovery sessions whose JWT omitted `nextLevel=aal2`
/// and whose session `user.factors` is empty, but [MfaRepository.listFactors] still
/// reports a verified authenticator (M11). Cleared when recovery ends or AAL2 is restored.
final recoveryMfaHoldProvider = StateProvider<bool>((ref) => false);

/// Side-effect only, watched once at the app root: flips [passwordRecoveryPendingProvider]
/// when Supabase reports a password-recovery sign-in, and clears it on sign-out.
final passwordRecoveryTriggerProvider = Provider<void>((ref) {
  ref.listen<AsyncValue<AuthState>>(
    authStateChangesProvider,
    (_, next) {
      unawaited(applyPasswordRecoveryAuthChange(ref.read, next));
    },
    fireImmediately: true,
  );
});

/// Side-effect only: during password recovery, probe [listFactors] so TOTP is forced even
/// when JWT AAL claims omit `nextLevel=aal2` (M11). Watched once at the app root.
final recoveryMfaProbeProvider = Provider<void>((ref) {
  ref.listen<bool>(
    passwordRecoveryPendingProvider,
    (_, pending) {
      if (!pending) {
        ref.read(recoveryMfaHoldProvider.notifier).state = false;
        return;
      }
      unawaited(probeRecoveryMfaHold(ref.read));
    },
    fireImmediately: true,
  );
  ref.listen<AsyncValue<AuthState>>(
    authStateChangesProvider,
    (_, __) {
      final mfa = ref.read(mfaRepositoryProvider);
      if (!mfa.isAal1 || !ref.read(passwordRecoveryPendingProvider)) {
        ref.read(recoveryMfaHoldProvider.notifier).state = false;
      }
    },
  );
});

/// Applies a password-recovery / sign-out latch update, awaiting the durable storage write
/// so a crash after this future completes still restores the hold on next launch.
Future<void> applyPasswordRecoveryAuthChange(
  T Function<T>(ProviderListenable<T> provider) read,
  AsyncValue<AuthState> next,
) async {
  if (next.error is AuthException) {
    read(authCallbackErrorProvider.notifier).state = expiredAuthLinkMessage;
  }
  final event = next.valueOrNull?.event;
  final pending = read(passwordRecoveryPendingProvider.notifier);
  final storage = read(passwordRecoveryStorageProvider);
  if (event == AuthChangeEvent.passwordRecovery) {
    pending.state = true;
    await storage.write(passwordRecoveryStorageKey, 'true');
  }
  if (event == AuthChangeEvent.signedOut) {
    pending.state = false;
    read(recoveryMfaHoldProvider.notifier).state = false;
    await storage.delete(passwordRecoveryStorageKey);
  }
}

/// Lists factors during recovery and sets [recoveryMfaHoldProvider] when a verified
/// authenticator exists while the session is still AAL1.
Future<void> probeRecoveryMfaHold(
  T Function<T>(ProviderListenable<T> provider) read,
) async {
  final mfa = read(mfaRepositoryProvider);
  if (!read(passwordRecoveryPendingProvider)) return;
  if (mfa.challengeRequired || !mfa.isAal1) {
    read(recoveryMfaHoldProvider.notifier).state = false;
    return;
  }
  try {
    final factors = await mfa.listFactors();
    if (!read(passwordRecoveryPendingProvider)) return;
    final hasVerified = factors.any((f) => f.verified);
    read(recoveryMfaHoldProvider.notifier).state = hasVerified && mfa.isAal1;
  } catch (_) {
    // Leave hold unchanged on network failure; JWT / user.factors path may still apply.
  }
}

/// Resolves whether bootstrap should force `/reset-password`: durable latch, or a
/// recovery-looking session (AMR) even when the latch key is missing.
Future<bool> resolvePasswordRecoveryPending({
  required Session? session,
  required SecureSessionStorage storage,
}) async {
  if (session == null) return false;
  final latched = await storage.read(passwordRecoveryStorageKey) == 'true';
  if (latched) return true;
  if (!sessionLooksLikePasswordRecovery(session)) return false;
  // Fail closed: persist so subsequent launches keep the hold without re-parsing AMR.
  await storage.write(passwordRecoveryStorageKey, 'true');
  return true;
}

final mfaRepositoryProvider = Provider<MfaRepository>((ref) {
  return SupabaseMfaRepository(ref.watch(supabaseClientProvider));
});

/// True while the session is AAL1 but the account has a verified authenticator, so the router
/// holds the user on /mfa-challenge. Re-evaluated on every auth event (sign-in, token refresh,
/// `mfaChallengeVerified`, sign-out) because the answer lives in the session's JWT.
///
/// Also true during password recovery when [recoveryMfaHoldProvider] was set after
/// [listFactors] found a verified authenticator despite JWT AAL claims (M11).
final mfaChallengeRequiredProvider = Provider<bool>((ref) {
  ref.watch(authStateChangesProvider);
  final mfa = ref.watch(mfaRepositoryProvider);
  if (mfa.challengeRequired) return true;
  return ref.watch(recoveryMfaHoldProvider) && mfa.isAal1;
});

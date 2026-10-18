import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../network/supabase_providers.dart';
import '../offline/offline_queue_providers.dart';
import '../storage/secure_session_storage.dart';
import '../../features/notifications/application/notifications_providers.dart';
import 'auth_providers.dart';

/// Deletes the temporary copies `file_picker` made of documents/imports the person chose
/// (they are otherwise left in the app cache until the OS reclaims it). Unsupported on web and
/// desktop; callers must treat a failure as non-fatal.
Future<void> clearPickerTemporaryFiles() async {
  if (kIsWeb) return;
  await FilePicker.platform.clearTemporaryFiles();
}

/// Overridable in tests; the real implementation touches a platform channel.
final pickerTemporaryFilesCleanerProvider =
    Provider<Future<void> Function()>((ref) => clearPickerTemporaryFiles);

/// Remembers who was last signed in and whether the sign-out cleanup has already run for that
/// session, so the UI sign-out path and the global `signedOut` listener (below) never both run
/// it. Lives for the app's lifetime in the root container.
class SignOutCleanupGate {
  String? lastUserId;
  bool _done = false;
  Future<void>? _running;

  /// A session exists: remember its owner and re-arm the cleanup for its eventual sign-out.
  void sessionStarted(String userId) {
    lastUserId = userId;
    _done = false;
  }

  /// Runs [body] unless the cleanup for this session already ran (or is running, in which case
  /// this waits for that run to finish).
  Future<void> runOnce(Future<void> Function() body) {
    if (_done) return Future<void>.value();
    return _running ??= body().whenComplete(() {
      _done = true;
      _running = null;
    });
  }

  /// A sign-out attempt failed after the cleanup ran and the session is still alive.
  void reset() => _done = false;
}

final signOutCleanupGateProvider =
    Provider<SignOutCleanupGate>((ref) => SignOutCleanupGate());

/// Everything that must happen when a session ends, whoever ended it: push-token revocation
/// (queued for the next sign-in when offline or unauthenticated), the signed-out user's offline
/// queue entries, picker temp files, and the secure-storage wipe (which also removes the
/// user-keyed floor-plan drafts).
///
/// Each step is isolated: a failure in one never prevents the others. Idempotent per session via
/// [SignOutCleanupGate]. [userId] is the account that is signing out; when the session is
/// already gone (server-initiated sign-out) the caller must supply it from the gate.
Future<void> runSignOutCleanup(
  ProviderContainer container, {
  String? userId,
}) {
  final gate = container.read(signOutCleanupGateProvider);
  final owner = userId ?? gate.lastUserId;
  return gate.runOnce(() => _cleanup(container, owner));
}

Future<void> _cleanup(ProviderContainer container, String? userId) async {
  const storage = SecureSessionStorage();
  try {
    await container.read(pushRegistrationServiceProvider).dispose();
    final token = await storage.read(registeredPushTokenStorageKey);
    if (token != null) {
      try {
        await container
            .read(notificationsRepositoryProvider)
            .unregisterPushToken(
              token,
              revocationSecret:
                  await storage.read(pushInstallationSecretStorageKey),
            );
        await storage.delete(pendingPushTokenRevocationStorageKey);
      } catch (_) {
        // Preserve the device token across secure-session cleanup so the next signed-in
        // session can revoke it before registering this device for another account.
        await storage.write(pendingPushTokenRevocationStorageKey, token);
      }
    }
  } catch (error) {
    // Network failure must not trap a person in the previous account.
    debugPrint('Sign-out: push token revocation skipped: $error');
  }
  try {
    // Without a known owner nothing is pruned: pruning "the null user" would delete unowned
    // legacy entries that belong to nobody in particular.
    if (userId != null) {
      await container
          .read(offlineQueueControllerProvider.notifier)
          .clearAll(forUserId: userId);
    }
  } catch (error) {
    // Queue clear must never block sign-out.
    debugPrint('Sign-out: offline queue clear failed: $error');
  }
  try {
    await container.read(pickerTemporaryFilesCleanerProvider)();
  } catch (error) {
    debugPrint('Sign-out: picker temp files not cleared: $error');
  }
  try {
    await storage.clearAll();
  } catch (error) {
    // Secure-storage clear must never block sign-out.
    debugPrint('Sign-out: secure storage clear failed: $error');
  }
}

/// Single sign-out path every screen must use: clears the per-user offline queue
/// and secure session values *before* signing out, so a shared tablet can never
/// replay user A's queued writes as user B.
///
/// Takes a [ProviderContainer] rather than a widget ref, so a caller that awaits something
/// first (and may be unmounted when it resumes) can capture the container before the await.
/// Each cleanup step is isolated: a failure in one never prevents the others, and the final
/// `signOut()` always runs.
Future<void> signOutAndClearScopedData(ProviderContainer container) async {
  String? userId;
  try {
    userId = container.read(currentUserIdProvider);
  } catch (_) {
    // No auth wiring (some tests): the cleanup then has no owner to prune.
  }
  await runSignOutCleanup(container, userId: userId);
  try {
    await container.read(authRepositoryProvider).signOut();
  } catch (_) {
    // The session survived, so its eventual sign-out still needs its own cleanup.
    container.read(signOutCleanupGateProvider).reset();
    rethrow;
  }
}

/// Side-effect only, watched once at the app root (app/app.dart): runs [runSignOutCleanup] when
/// Supabase ends the session on its own (refresh token revoked or reused, account removed,
/// session timebox or inactivity timeout), which never passes through a sign-out button.
/// A UI sign-out has already run the cleanup by then, so it is skipped.
final serverSignOutCleanupProvider = Provider<void>((ref) {
  final gate = ref.read(signOutCleanupGateProvider);
  try {
    final existing = ref.read(authRepositoryProvider).currentSession;
    if (existing != null) gate.sessionStarted(existing.user.id);
  } catch (_) {
    // Auth not available (tests): the first auth event seeds the gate instead.
  }
  ref.listen<AsyncValue<AuthState>>(authStateChangesProvider, (_, next) {
    final state = next.valueOrNull;
    if (state == null) return;
    switch (state.event) {
      case AuthChangeEvent.signedOut:
        unawaited(runSignOutCleanup(ref.container));
      case AuthChangeEvent.signedIn || AuthChangeEvent.initialSession:
        final user = state.session?.user;
        if (user != null) gate.sessionStarted(user.id);
      default:
        // Token refreshes etc. carry the same session; keep the owner current.
        final user = state.session?.user;
        if (user != null) gate.lastUserId = user.id;
    }
  });
});

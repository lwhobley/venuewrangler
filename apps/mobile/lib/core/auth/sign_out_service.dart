import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../offline/offline_queue_providers.dart';
import '../storage/secure_session_storage.dart';
import '../../features/notifications/application/notifications_providers.dart';
import 'auth_providers.dart';

/// Single sign-out path every screen must use: clears the per-user offline queue
/// and secure session values *before* signing out, so a shared tablet can never
/// replay user A's queued writes as user B.
///
/// Takes a [ProviderContainer] rather than a widget ref, so a caller that awaits something
/// first (and may be unmounted when it resumes) can capture the container before the await.
/// Each cleanup step is isolated: a failure in one never prevents the others, and the final
/// `signOut()` always runs.
Future<void> signOutAndClearScopedData(ProviderContainer container) async {
  try {
    await container.read(pushRegistrationServiceProvider).dispose();
    final token =
        await const SecureSessionStorage().read(registeredPushTokenStorageKey);
    if (token != null) {
      try {
        await container
            .read(notificationsRepositoryProvider)
            .unregisterPushToken(
              token,
              revocationSecret: await const SecureSessionStorage()
                  .read(pushInstallationSecretStorageKey),
            );
        await const SecureSessionStorage()
            .delete(pendingPushTokenRevocationStorageKey);
      } catch (_) {
        // Preserve the device token across secure-session cleanup so the next signed-in
        // session can revoke it before registering this device for another account.
        await const SecureSessionStorage().write(
          pendingPushTokenRevocationStorageKey,
          token,
        );
      }
    }
  } catch (error) {
    // Network failure must not trap a person in the previous account.
    debugPrint('Sign-out: push token revocation skipped: $error');
  }
  try {
    await container.read(offlineQueueControllerProvider.notifier).clearAll();
  } catch (error) {
    // Queue clear must never block sign-out.
    debugPrint('Sign-out: offline queue clear failed: $error');
  }
  try {
    await const SecureSessionStorage().clearAll();
  } catch (error) {
    // Secure-storage clear must never block sign-out.
    debugPrint('Sign-out: secure storage clear failed: $error');
  }
  await container.read(authRepositoryProvider).signOut();
}

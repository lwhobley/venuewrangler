import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../offline/offline_queue_providers.dart';
import '../storage/secure_session_storage.dart';
import 'auth_providers.dart';

/// Single sign-out path every screen must use: clears the per-user offline queue
/// and secure session values *before* signing out, so a shared tablet can never
/// replay user A's queued writes as user B.
Future<void> signOutAndClearScopedData(WidgetRef ref) async {
  try {
    await ref.read(offlineQueueControllerProvider.notifier).clearAll();
  } catch (_) {
    // Queue clear must never block sign-out.
  }
  try {
    await const SecureSessionStorage().clearAll();
  } catch (_) {
    // Secure-storage clear must never block sign-out.
  }
  await ref.read(authRepositoryProvider).signOut();
}

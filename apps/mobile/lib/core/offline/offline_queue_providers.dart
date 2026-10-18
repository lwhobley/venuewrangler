import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_providers.dart';
import '../storage/secure_session_storage.dart';
import 'offline_queue_controller.dart';
import 'offline_queue_store.dart';
import 'pending_mutation.dart';

final offlineQueueStoreProvider = Provider<OfflineQueueStore>((ref) {
  // Native stores the queue encrypted with flutter_secure_storage. Existing plaintext queue
  // files are imported once and removed only after secure storage confirms the encrypted copy.
  return SecureStorageOfflineQueueStore(migrateLegacyFile: !kIsWeb);
});

/// Empty by default. The app composition root (app/bootstrap.dart) overrides this with the
/// merged handler map from every feature that queues mutations, so core/offline never needs
/// to import a feature package directly.
final offlineQueueHandlersProvider =
    Provider<Map<String, MutationHandler>>((ref) {
  return const {};
});

final offlineQueueControllerProvider =
    StateNotifierProvider<OfflineQueueController, OfflineQueueState>((ref) {
  final store = ref.watch(offlineQueueStoreProvider);
  final handlers = ref.watch(offlineQueueHandlersProvider);
  return OfflineQueueController(
    store,
    handlers,
    // Tests often override the store without a Supabase client — auth state is
    // then unavailable. Never let user-stamping break enqueue in that case.
    currentUserId: () {
      try {
        return ref.read(currentUserIdProvider);
      } catch (_) {
        return null;
      }
    },
  );
});

/// The queue as the signed-in user may see it: their own pending writes and conflicts only. The
/// underlying queue also holds other accounts' unsynced work on a shared device.
final userOfflineQueueProvider = Provider<OfflineQueueState>((ref) {
  final queue = ref.watch(offlineQueueControllerProvider);
  String? userId;
  try {
    userId = ref.watch(currentUserIdProvider);
  } catch (_) {
    // Tests often override the controller without a Supabase client; entries are then
    // unowned (null) and match a null user, same as the controller's own stamping.
  }
  return queue.forUser(userId);
});

final secureSessionStorageProvider = Provider<SecureSessionStorage>((ref) {
  return const SecureSessionStorage();
});

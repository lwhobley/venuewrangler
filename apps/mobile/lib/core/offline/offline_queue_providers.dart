import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_providers.dart';
import '../storage/secure_session_storage.dart';
import 'offline_queue_controller.dart';
import 'offline_queue_store.dart';
import 'pending_mutation.dart';

final offlineQueueStoreProvider = Provider<OfflineQueueStore>((ref) {
  // No filesystem on web (path_provider has no web implementation).
  if (kIsWeb) return const SecureStorageOfflineQueueStore();
  return FileOfflineQueueStore();
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

final secureSessionStorageProvider = Provider<SecureSessionStorage>((ref) {
  return const SecureSessionStorage();
});

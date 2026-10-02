import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'offline_queue_controller.dart';
import 'offline_queue_store.dart';
import 'pending_mutation.dart';

final offlineQueueStoreProvider = Provider<OfflineQueueStore>((ref) {
  return FileOfflineQueueStore();
});

/// Empty by default. The app composition root (app/bootstrap.dart) overrides this with the
/// merged handler map from every feature that queues mutations, so core/offline never needs
/// to import a feature package directly.
final offlineQueueHandlersProvider = Provider<Map<String, MutationHandler>>((ref) {
  return const {};
});

final offlineQueueControllerProvider =
    StateNotifierProvider<OfflineQueueController, OfflineQueueState>((ref) {
  final store = ref.watch(offlineQueueStoreProvider);
  final handlers = ref.watch(offlineQueueHandlersProvider);
  return OfflineQueueController(store, handlers);
});

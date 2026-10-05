import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_providers.dart';
import 'offline_queue_providers.dart';

/// Watching this provider anywhere (app/app.dart does, once, app-wide) activates a listener
/// that flushes the offline queue whenever connectivity is regained. It has no state of its
/// own — it exists purely for its side effect — so nothing else should depend on its value.
final offlineQueueConnectivityProvider = Provider<void>((ref) {
  final controller = ref.read(offlineQueueControllerProvider.notifier);

  // Also attempt a flush on startup, in case mutations were queued during a previous session
  // that ended while still offline.
  controller.flush(onlyUserId: ref.read(currentUserIdProvider));

  final subscription = Connectivity().onConnectivityChanged.listen((results) {
    final hasConnection =
        results.any((result) => result != ConnectivityResult.none);
    if (hasConnection) {
      controller.flush(onlyUserId: ref.read(currentUserIdProvider));
    }
  });

  ref.onDispose(subscription.cancel);
});

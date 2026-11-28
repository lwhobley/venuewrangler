import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_providers.dart';
import 'offline_queue_providers.dart';

/// Connectivity changes; overridable in tests (the real stream needs a platform channel).
final connectivityChangesProvider = Provider<Stream<List<ConnectivityResult>>>(
  (ref) => Connectivity().onConnectivityChanged,
);

/// Watching this provider anywhere (app/app.dart does, once, app-wide) activates listeners
/// that flush the offline queue on startup, whenever connectivity is regained, and whenever a
/// user signs in. It has no state of its own — it exists purely for its side effect — so
/// nothing else should depend on its value.
final offlineQueueConnectivityProvider = Provider<void>((ref) {
  final controller = ref.read(offlineQueueControllerProvider.notifier);

  // Also attempt a flush on startup, in case mutations were queued during a previous session
  // that ended while still offline.
  controller.flush(onlyUserId: ref.read(currentUserIdProvider));

  // A cold start while signed out flushes nothing (no owner). Signing in while already online
  // never fires a connectivity change either, so flush that user's queued writes now rather
  // than waiting for the next network flip (review E11).
  ref.listen<String?>(currentUserIdProvider, (previous, next) {
    if (next != null && next != previous) controller.flush(onlyUserId: next);
  });

  final subscription = ref.watch(connectivityChangesProvider).listen((results) {
    final hasConnection =
        results.any((result) => result != ConnectivityResult.none);
    if (hasConnection) {
      controller.flush(onlyUserId: ref.read(currentUserIdProvider));
    }
  });

  ref.onDispose(subscription.cancel);
});

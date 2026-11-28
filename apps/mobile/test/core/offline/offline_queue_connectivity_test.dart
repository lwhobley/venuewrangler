import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venuewrangler_mobile/core/auth/auth_providers.dart';
import 'package:venuewrangler_mobile/core/offline/offline_queue_connectivity.dart';
import 'package:venuewrangler_mobile/core/offline/offline_queue_controller.dart';
import 'package:venuewrangler_mobile/core/offline/offline_queue_providers.dart';
import 'package:venuewrangler_mobile/core/offline/offline_queue_store.dart';
import 'package:venuewrangler_mobile/core/offline/pending_mutation.dart';

class _Store implements OfflineQueueStore {
  @override
  Future<List<PendingMutation>> loadAll() async => const [];

  @override
  Future<void> saveAll(List<PendingMutation> mutations) async {}
}

class _RecordingController extends OfflineQueueController {
  _RecordingController() : super(_Store(), const {});

  final flushes = <String?>[];

  @override
  Future<void> flush({String? onlyUserId}) async => flushes.add(onlyUserId);
}

void main() {
  test('flushes on startup, on sign-in and when connectivity returns (E11)',
      () async {
    final controller = _RecordingController();
    final connectivity = StreamController<List<ConnectivityResult>>();
    final userId = StateProvider<String?>((ref) => null);
    final container = ProviderContainer(
      overrides: [
        offlineQueueControllerProvider.overrideWith((ref) => controller),
        currentUserIdProvider.overrideWith((ref) => ref.watch(userId)),
        connectivityChangesProvider.overrideWithValue(connectivity.stream),
      ],
    );
    addTearDown(() {
      container.dispose();
      connectivity.close();
    });

    container.read(offlineQueueConnectivityProvider);
    expect(controller.flushes, [null], reason: 'startup, signed out');

    // Signing in while already online: no connectivity event, still flushes.
    container.read(userId.notifier).state = 'user-1';
    await Future<void>.delayed(Duration.zero);
    expect(controller.flushes, [null, 'user-1']);

    connectivity.add([ConnectivityResult.none]);
    await Future<void>.delayed(Duration.zero);
    expect(controller.flushes, [null, 'user-1'], reason: 'still offline');

    connectivity.add([ConnectivityResult.wifi]);
    await Future<void>.delayed(Duration.zero);
    expect(controller.flushes, [null, 'user-1', 'user-1']);

    // Signing out does not flush (nothing to flush for nobody).
    container.read(userId.notifier).state = null;
    await Future<void>.delayed(Duration.zero);
    expect(controller.flushes, [null, 'user-1', 'user-1']);
  });
}

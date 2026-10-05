import 'package:flutter_test/flutter_test.dart';
import 'package:venuewrangler_mobile/core/offline/offline_queue_controller.dart';
import 'package:venuewrangler_mobile/core/offline/offline_queue_store.dart';
import 'package:venuewrangler_mobile/core/offline/pending_mutation.dart';

class _InMemoryOfflineQueueStore implements OfflineQueueStore {
  List<PendingMutation> saved = const [];

  @override
  Future<List<PendingMutation>> loadAll() async => saved;

  @override
  Future<void> saveAll(List<PendingMutation> mutations) async {
    saved = mutations;
  }
}

PendingMutation _mutation({
  String id = 'm1',
  String kind = 'test_kind',
  int attempts = 0,
}) {
  return PendingMutation(
    id: id,
    kind: kind,
    payload: const {'value': 1},
    createdAt: DateTime(2026),
    attemptCount: attempts,
  );
}

void main() {
  group('OfflineQueueController', () {
    test('enqueue adds to pending and persists to the store', () async {
      final store = _InMemoryOfflineQueueStore();
      final controller = OfflineQueueController(store, const {});
      await controller.ready;

      await controller.enqueue(_mutation());

      expect(controller.state.pending, hasLength(1));
      expect(store.saved, hasLength(1));
    });

    test('flush removes a mutation whose handler reports applied', () async {
      final store = _InMemoryOfflineQueueStore();
      final controller = OfflineQueueController(store, {
        'test_kind': (payload) async =>
            const MutationResult(MutationOutcome.applied),
      });
      await controller.ready;
      await controller.enqueue(_mutation());

      await controller.flush();

      expect(controller.state.pending, isEmpty);
      expect(controller.state.conflicts, isEmpty);
    });

    test(
        'flush moves a mutation whose handler reports a conflict out of pending, and never '
        'retries it again', () async {
      var callCount = 0;
      final store = _InMemoryOfflineQueueStore();
      final controller = OfflineQueueController(store, {
        'test_kind': (payload) async {
          callCount++;
          return const MutationResult(
            MutationOutcome.conflict,
            message: 'changed elsewhere',
          );
        },
      });
      await controller.ready;
      await controller.enqueue(_mutation());

      await controller.flush();
      await controller.flush();

      expect(controller.state.pending, isEmpty);
      expect(controller.state.conflicts, hasLength(1));
      expect(
        callCount,
        1,
        reason: 'a conflicted mutation must not be retried on a later flush',
      );
    });

    test(
        'flush keeps a retryable failure pending and increments its attempt count',
        () async {
      final store = _InMemoryOfflineQueueStore();
      final controller = OfflineQueueController(store, {
        'test_kind': (payload) async =>
            const MutationResult(MutationOutcome.retryableFailure),
      });
      await controller.ready;
      await controller.enqueue(_mutation());

      await controller.flush();

      expect(controller.state.pending, hasLength(1));
      expect(controller.state.pending.single.attemptCount, 1);
      expect(controller.state.conflicts, isEmpty);
    });

    test(
        'a retryable failure becomes a conflict once it reaches kMaxMutationAttempts',
        () async {
      final store = _InMemoryOfflineQueueStore();
      final controller = OfflineQueueController(store, {
        'test_kind': (payload) async =>
            const MutationResult(MutationOutcome.retryableFailure),
      });
      await controller.ready;
      await controller.enqueue(_mutation(attempts: kMaxMutationAttempts - 1));

      await controller.flush();

      expect(controller.state.pending, isEmpty);
      expect(controller.state.conflicts, hasLength(1));
    });

    test('a handler that throws is treated as a retryable failure, not a crash',
        () async {
      final store = _InMemoryOfflineQueueStore();
      final controller = OfflineQueueController(store, {
        'test_kind': (payload) async => throw Exception('network down'),
      });
      await controller.ready;
      await controller.enqueue(_mutation());

      await controller.flush();

      expect(controller.state.pending, hasLength(1));
      expect(controller.state.pending.single.attemptCount, 1);
    });

    test('dismissConflict removes it from the conflicts list', () async {
      final store = _InMemoryOfflineQueueStore();
      final controller = OfflineQueueController(store, {
        'test_kind': (payload) async =>
            const MutationResult(MutationOutcome.conflict),
      });
      await controller.ready;
      await controller.enqueue(_mutation(id: 'conflicted'));
      await controller.flush();
      expect(controller.state.conflicts, hasLength(1));

      controller.dismissConflict('conflicted');

      expect(controller.state.conflicts, isEmpty);
    });

    test(
        'a mutation with no registered handler stays pending rather than being dropped',
        () async {
      final store = _InMemoryOfflineQueueStore();
      final controller = OfflineQueueController(store, const {});
      await controller.ready;
      await controller.enqueue(_mutation(kind: 'unknown_kind'));

      await controller.flush();

      expect(controller.state.pending, hasLength(1));
    });
  });
}

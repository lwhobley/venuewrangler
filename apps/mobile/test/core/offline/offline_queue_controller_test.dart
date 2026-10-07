import 'dart:async';

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

/// The first save takes noticeably longer than later ones, so two un-serialized overlapping
/// writes would complete out of order.
class _SlowFirstWriteStore implements OfflineQueueStore {
  List<PendingMutation> saved = const [];
  int _calls = 0;

  @override
  Future<List<PendingMutation>> loadAll() async => saved;

  @override
  Future<void> saveAll(List<PendingMutation> mutations) async {
    final call = ++_calls;
    if (call == 1) await Future<void>.delayed(const Duration(milliseconds: 40));
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

    test(
        'a mutation enqueued while flush is awaiting a handler survives the flush',
        () async {
      final store = _InMemoryOfflineQueueStore();
      final handlerGate = Completer<void>();
      late OfflineQueueController controller;
      controller = OfflineQueueController(store, {
        'test_kind': (payload) async {
          await handlerGate.future;
          return const MutationResult(MutationOutcome.applied);
        },
      });
      await controller.ready;
      await controller.enqueue(_mutation(id: 'first'));

      final flushing = controller.flush();
      // flush() is now suspended inside the handler; this arrives mid-sync.
      await controller.enqueue(_mutation(id: 'arrived-during-sync'));
      handlerGate.complete();
      await flushing;

      expect(
        controller.state.pending.map((m) => m.id),
        ['arrived-during-sync'],
      );
      expect(store.saved.map((m) => m.id), ['arrived-during-sync']);
    });

    test('clearAll during a flush is not undone when the flush finishes',
        () async {
      final store = _InMemoryOfflineQueueStore();
      final handlerGate = Completer<void>();
      final controller = OfflineQueueController(store, {
        'test_kind': (payload) async {
          await handlerGate.future;
          return const MutationResult(MutationOutcome.conflict);
        },
      });
      await controller.ready;
      await controller.enqueue(_mutation(id: 'old-user'));
      await controller.enqueue(_mutation(id: 'old-user-2'));

      final flushing = controller.flush();
      await controller.clearAll(); // sign-out while the flush is mid-handler
      handlerGate.complete();
      await flushing;

      expect(controller.state.pending, isEmpty);
      expect(controller.state.conflicts, isEmpty);
      expect(store.saved, isEmpty);
    });

    test('overlapping writes persist in order, ending on the latest queue',
        () async {
      final store = _SlowFirstWriteStore();
      final controller = OfflineQueueController(store, const {});
      await controller.ready;

      final first = controller.enqueue(_mutation(id: 'a'));
      final second = controller.enqueue(_mutation(id: 'b'));
      await Future.wait([first, second]);

      // The first write is deliberately slow; without serialization it would finish last and
      // leave only [a] on disk.
      expect(store.saved.map((m) => m.id), ['a', 'b']);
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

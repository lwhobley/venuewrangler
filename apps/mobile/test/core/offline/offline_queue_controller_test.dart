import 'dart:async';
import 'dart:io';

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

      // Moved out of pending, not duplicated into both lists.
      expect(controller.state.pending, isEmpty);
      expect(controller.state.conflicts, hasLength(1));
      expect(store.saved, hasLength(1));
    });

    test('conflicts are persisted and restored after a restart', () async {
      final store = _InMemoryOfflineQueueStore();
      final first = OfflineQueueController(store, {
        'test_kind': (payload) async =>
            const MutationResult(MutationOutcome.conflict),
      });
      await first.ready;
      await first.enqueue(_mutation(id: 'conflicted'));
      await first.flush();
      expect(first.state.conflicts, hasLength(1));

      final restarted = OfflineQueueController(store, const {});
      await restarted.ready;

      expect(restarted.state.conflicts.map((m) => m.id), ['conflicted']);
      expect(restarted.state.pending, isEmpty);
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

    test('sign-out stops handlers for later entries in an active flush',
        () async {
      final store = _InMemoryOfflineQueueStore();
      final gate = Completer<void>();
      final started = Completer<void>();
      var calls = 0;
      String? userId = 'user-a';
      final controller = OfflineQueueController(
        store,
        {
          'test_kind': (payload) async {
            calls++;
            if (!started.isCompleted) started.complete();
            await gate.future;
            return const MutationResult(MutationOutcome.applied);
          },
        },
        currentUserId: () => userId,
      );
      await controller.ready;
      await controller.enqueue(_mutation(id: 'first'));
      await controller.enqueue(_mutation(id: 'second'));

      final flushing = controller.flush();
      await started.future;
      await controller.clearAll();
      userId = null;
      gate.complete();
      await flushing;

      expect(calls, 1);
      expect(store.saved, isEmpty);
    });

    test('signed-out sessions never replay another user queue', () async {
      final store = _InMemoryOfflineQueueStore();
      var calls = 0;
      String? userId = 'user-a';
      final controller = OfflineQueueController(
        store,
        {
          'test_kind': (payload) async {
            calls++;
            return const MutationResult(MutationOutcome.applied);
          },
        },
        currentUserId: () => userId,
      );
      await controller.ready;
      await controller.enqueue(_mutation());
      userId = null;

      await controller.flush();

      expect(calls, 0);
      expect(store.saved, hasLength(1));
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

      await controller.dismissConflict('conflicted');

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

    test('an unreadable store starts empty and enqueue still works', () async {
      final controller =
          OfflineQueueController(_UnreadableOfflineQueueStore(), const {});

      await controller.ready;
      await controller.enqueue(_mutation(id: 'after-corruption'));

      expect(controller.state.pending.map((m) => m.id), ['after-corruption']);
    });

    test(
        'transport failures do not count toward the retry limit: the mutation '
        'stays pending and is never moved to conflicts', () async {
      final store = _InMemoryOfflineQueueStore();
      final controller = OfflineQueueController(store, {
        'test_kind': (payload) async => throw const SocketException('offline'),
      });
      await controller.ready;
      await controller.enqueue(_mutation(id: 'offline-write'));

      for (var i = 0; i < kMaxMutationAttempts + 3; i++) {
        await controller.flush();
      }

      expect(controller.state.conflicts, isEmpty);
      expect(controller.state.pending, hasLength(1));
      expect(controller.state.pending.single.attemptCount, 0);
    });

    test('a thrown non-transport error counts as a server-answered attempt',
        () async {
      final store = _InMemoryOfflineQueueStore();
      final controller = OfflineQueueController(store, {
        'test_kind': (payload) async => throw StateError('server said no'),
      });
      await controller.ready;
      await controller.enqueue(_mutation(id: 'rejected'));

      for (var i = 0; i < kMaxMutationAttempts; i++) {
        await controller.flush();
      }

      expect(controller.state.pending, isEmpty);
      expect(controller.state.conflicts.single.id, 'rejected');
    });

    test(
        'sign-out removes only the signed-out user and keeps other users\' '
        'conflicts and pending writes', () async {
      final store = _InMemoryOfflineQueueStore();
      String? userId = 'user-a';
      final controller = OfflineQueueController(
        store,
        {
          'test_kind': (payload) async =>
              const MutationResult(MutationOutcome.conflict),
        },
        currentUserId: () => userId,
      );
      await controller.ready;
      await controller.enqueue(_mutation(id: 'a-conflict'));
      await controller.flush();
      userId = 'user-b';
      await controller.enqueue(_mutation(id: 'b-pending'));

      await controller.clearAll();

      expect(controller.state.conflicts.map((m) => m.id), ['a-conflict']);
      expect(controller.state.pending, isEmpty);
      expect(store.saved.map((m) => m.id), ['a-conflict']);
    });

    test('clearAll(forUserId) prunes the named user after the session is gone',
        () async {
      final store = _InMemoryOfflineQueueStore();
      String? userId = 'user-a';
      final controller = OfflineQueueController(
        store,
        const {},
        currentUserId: () => userId,
      );
      await controller.ready;
      await controller.enqueue(_mutation(id: 'a-pending'));
      userId = 'user-b';
      await controller.enqueue(_mutation(id: 'b-pending'));
      userId = null; // server-initiated sign-out: no current user any more

      await controller.clearAll(forUserId: 'user-a');

      expect(controller.state.pending.map((m) => m.id), ['b-pending']);
      expect(store.saved.map((m) => m.id), ['b-pending']);
    });

    test('forUser exposes only the named users pending writes and conflicts',
        () async {
      final store = _InMemoryOfflineQueueStore();
      String? userId = 'user-a';
      final controller = OfflineQueueController(
        store,
        {
          'test_kind': (payload) async =>
              const MutationResult(MutationOutcome.conflict),
        },
        currentUserId: () => userId,
      );
      await controller.ready;
      await controller.enqueue(_mutation(id: 'a-conflict'));
      await controller.flush();
      await controller.enqueue(_mutation(id: 'a-pending'));
      userId = 'user-b';
      await controller.enqueue(_mutation(id: 'b-pending'));

      final forB = controller.state.forUser('user-b');
      expect(forB.pending.map((m) => m.id), ['b-pending']);
      expect(forB.conflicts, isEmpty);

      final forA = controller.state.forUser('user-a');
      expect(forA.pending.map((m) => m.id), ['a-pending']);
      expect(forA.conflicts.map((m) => m.id), ['a-conflict']);
    });

    test('dismissConflict ignores entries owned by another user', () async {
      final store = _InMemoryOfflineQueueStore();
      String? userId = 'user-a';
      final controller = OfflineQueueController(
        store,
        {
          'test_kind': (payload) async =>
              const MutationResult(MutationOutcome.conflict),
        },
        currentUserId: () => userId,
      );
      await controller.ready;
      await controller.enqueue(_mutation(id: 'a-conflict'));
      await controller.flush();

      userId = 'user-b';
      await controller.dismissConflict('a-conflict');
      expect(controller.state.conflicts.map((m) => m.id), ['a-conflict']);
      expect(store.saved.map((m) => m.id), ['a-conflict']);

      userId = 'user-a';
      await controller.dismissConflict('a-conflict');
      expect(controller.state.conflicts, isEmpty);
      expect(store.saved, isEmpty);
    });

    test(
        'when the user changes mid-flush, mutations already applied are removed '
        'before returning so they are not replayed', () async {
      final store = _InMemoryOfflineQueueStore();
      final gate = Completer<void>();
      final started = Completer<void>();
      String? userId = 'user-a';
      var calls = 0;
      final controller = OfflineQueueController(
        store,
        {
          'test_kind': (payload) async {
            calls++;
            if (payload['value'] == 2) {
              if (!started.isCompleted) started.complete();
              await gate.future;
            }
            return const MutationResult(MutationOutcome.applied);
          },
        },
        currentUserId: () => userId,
      );
      await controller.ready;
      await controller.enqueue(_mutation(id: 'first'));
      await controller.enqueue(
        PendingMutation(
          id: 'second',
          kind: 'test_kind',
          payload: const {'value': 2},
          createdAt: DateTime(2026),
        ),
      );
      await controller.enqueue(_mutation(id: 'third'));

      final flushing = controller.flush();
      await started.future;
      userId = 'user-b';
      gate.complete();
      await flushing;

      expect(calls, 2);
      expect(controller.state.pending.map((m) => m.id), ['third']);
      expect(store.saved.map((m) => m.id), ['third']);
    });
  });
}

class _UnreadableOfflineQueueStore implements OfflineQueueStore {
  @override
  Future<List<PendingMutation>> loadAll() async =>
      throw const FormatException('corrupt blob');

  @override
  Future<void> saveAll(List<PendingMutation> mutations) async {}
}

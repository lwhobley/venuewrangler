import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'offline_queue_store.dart';
import 'pending_mutation.dart';

/// A mutation stays queued for retry at most this many times before it is treated the same
/// as a conflict (surfaced to the user rather than retried forever in the background).
const int kMaxMutationAttempts = 5;

class OfflineQueueState {
  const OfflineQueueState({this.pending = const [], this.conflicts = const []});

  final List<PendingMutation> pending;

  /// Mutations that failed because someone else changed the record first, or that exceeded
  /// [kMaxMutationAttempts]. Never auto-resolved — a feature screen should show these and let
  /// the person decide (discard the local change, or re-view the current record and redo it),
  /// per the migration plan's "never silently overwrite a manager's changes" requirement.
  final List<PendingMutation> conflicts;

  OfflineQueueState copyWith({
    List<PendingMutation>? pending,
    List<PendingMutation>? conflicts,
  }) =>
      OfflineQueueState(
        pending: pending ?? this.pending,
        conflicts: conflicts ?? this.conflicts,
      );
}

/// Feature-agnostic: each feature registers a [MutationHandler] for the mutation `kind`(s) it
/// queues (see TasksRepository/TaskListScreen for the first consumer) rather than this class
/// knowing about tasks, checklists, or incidents itself.
class OfflineQueueController extends StateNotifier<OfflineQueueState> {
  OfflineQueueController(this._store, this._handlers) : super(const OfflineQueueState()) {
    _loaded = _load();
  }

  final OfflineQueueStore _store;
  final Map<String, MutationHandler> _handlers;
  late final Future<void> _loaded;
  bool _flushing = false;

  Future<void> get ready => _loaded;

  Future<void> _load() async {
    final pending = await _store.loadAll();
    state = state.copyWith(pending: pending);
  }

  Future<void> enqueue(PendingMutation mutation) async {
    await _loaded;
    state = state.copyWith(pending: [...state.pending, mutation]);
    await _store.saveAll(state.pending);
  }

  void dismissConflict(String mutationId) {
    state = state.copyWith(
      conflicts: state.conflicts.where((m) => m.id != mutationId).toList(growable: false),
    );
  }

  /// Attempts every pending mutation once, in queue order (oldest first), so an earlier
  /// change to the same record is applied — and can be conflict-detected against — before a
  /// later one. Safe to call repeatedly (e.g. on every connectivity-restored event); a second
  /// call while one is already running is a no-op.
  Future<void> flush() async {
    if (_flushing) return;
    _flushing = true;
    try {
      await _loaded;
      final stillPending = <PendingMutation>[];
      final newConflicts = <PendingMutation>[];

      for (final mutation in state.pending) {
        final handler = _handlers[mutation.kind];
        if (handler == null) {
          // No feature has registered a handler for this kind (e.g. an older app version
          // queued it). Keep it rather than silently dropping someone's unsynced change.
          stillPending.add(mutation);
          continue;
        }

        final result = await _tryApply(handler, mutation);
        switch (result.outcome) {
          case MutationOutcome.applied:
            break;
          case MutationOutcome.conflict:
            newConflicts.add(mutation);
          case MutationOutcome.retryableFailure:
            final attempted = mutation.withIncrementedAttempt();
            if (attempted.attemptCount >= kMaxMutationAttempts) {
              newConflicts.add(attempted);
            } else {
              stillPending.add(attempted);
            }
        }
      }

      state = state.copyWith(
        pending: stillPending,
        conflicts: [...state.conflicts, ...newConflicts],
      );
      await _store.saveAll(stillPending);
    } finally {
      _flushing = false;
    }
  }

  Future<MutationResult> _tryApply(MutationHandler handler, PendingMutation mutation) async {
    try {
      return await handler(mutation.payload);
    } catch (_) {
      return const MutationResult(MutationOutcome.retryableFailure);
    }
  }
}

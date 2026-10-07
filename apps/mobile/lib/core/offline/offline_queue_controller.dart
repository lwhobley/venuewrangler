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
  OfflineQueueController(
    this._store,
    this._handlers, {
    String? Function()? currentUserId,
  })  : _currentUserId = currentUserId,
        super(const OfflineQueueState()) {
    _loaded = _load();
  }

  final OfflineQueueStore _store;
  final Map<String, MutationHandler> _handlers;
  final String? Function()? _currentUserId;
  late final Future<void> _loaded;
  bool _flushing = false;

  // Every write to the store goes through this chain so two overlapping writes (an enqueue
  // landing while flush() is saving) can never finish out of order and persist a stale list.
  // Each link saves whatever state.pending is *when it runs*, not a snapshot taken earlier.
  Future<void> _writeChain = Future<void>.value();

  Future<void> get ready => _loaded;

  Future<void> _load() async {
    final pending = await _store.loadAll();
    state = state.copyWith(pending: pending);
  }

  Future<void> enqueue(PendingMutation mutation) async {
    await _loaded;
    final stamped = mutation.userId != null
        ? mutation
        : PendingMutation(
            id: mutation.id,
            kind: mutation.kind,
            payload: mutation.payload,
            createdAt: mutation.createdAt,
            attemptCount: mutation.attemptCount,
            userId: _currentUserId?.call(),
          );
    state = state.copyWith(pending: [...state.pending, stamped]);
    await _persist();
  }

  Future<void> _persist() {
    final write = _writeChain.then((_) => _store.saveAll(state.pending));
    // A failed write must not wedge every later one; the caller still sees its own error.
    _writeChain = write.then((_) {}, onError: (_) {});
    return write;
  }

  Future<void> clearAll() async {
    await _loaded;
    state = const OfflineQueueState();
    await _persist();
  }

  void dismissConflict(String mutationId) {
    state = state.copyWith(
      conflicts: state.conflicts
          .where((m) => m.id != mutationId)
          .toList(growable: false),
    );
  }

  /// Attempts every pending mutation once, in queue order (oldest first), so an earlier
  /// change to the same record is applied — and can be conflict-detected against — before a
  /// later one. Safe to call repeatedly (e.g. on every connectivity-restored event); a second
  /// call while one is already running is a no-op.
  ///
  /// When [onlyUserId] is set, entries owned by a different user are left untouched
  /// (kept pending, never applied). Pass the current user id; a null here with
  /// pending entries present still flushes legacy entries with no owner, but never
  /// another user's entries.
  Future<void> flush({String? onlyUserId}) async {
    final effectiveUserId = onlyUserId ?? _currentUserId?.call();
    if (_flushing) return;
    _flushing = true;
    try {
      await _loaded;
      // Outcomes are recorded by id and applied to the queue as it is *after* the loop, not
      // to the list this loop started from: handlers are awaited, and anything enqueued (or
      // cleared by a sign-out) in the meantime must survive the flush.
      final settled = <String>{};
      final retried = <String, PendingMutation>{};
      final newConflicts = <PendingMutation>[];

      for (final mutation in List<PendingMutation>.of(state.pending)) {
        if (mutation.userId != null &&
            effectiveUserId != null &&
            mutation.userId != effectiveUserId) {
          continue;
        }
        final handler = _handlers[mutation.kind];
        if (handler == null) {
          // No feature has registered a handler for this kind (e.g. an older app version
          // queued it). Keep it rather than silently dropping someone's unsynced change.
          continue;
        }

        final result = await _tryApply(handler, mutation);
        switch (result.outcome) {
          case MutationOutcome.applied:
            settled.add(mutation.id);
          case MutationOutcome.conflict:
            settled.add(mutation.id);
            newConflicts.add(mutation);
          case MutationOutcome.retryableFailure:
            final attempted = mutation.withIncrementedAttempt();
            if (attempted.attemptCount >= kMaxMutationAttempts) {
              settled.add(mutation.id);
              newConflicts.add(attempted);
            } else {
              retried[mutation.id] = attempted;
            }
        }
      }

      // A conflict is only recorded if its mutation is still queued: a sign-out's clearAll()
      // during the flush discards the previous user's queue *and* anything it would conflict.
      final queuedIds = {for (final m in state.pending) m.id};
      state = state.copyWith(
        pending: [
          for (final m in state.pending)
            if (!settled.contains(m.id)) retried[m.id] ?? m,
        ],
        conflicts: [
          ...state.conflicts,
          for (final c in newConflicts)
            if (queuedIds.contains(c.id)) c,
        ],
      );
      await _persist();
    } finally {
      _flushing = false;
    }
  }

  Future<MutationResult> _tryApply(
    MutationHandler handler,
    PendingMutation mutation,
  ) async {
    try {
      return await handler(mutation.payload);
    } catch (_) {
      return const MutationResult(MutationOutcome.retryableFailure);
    }
  }
}

# core/offline

Implemented: a feature-agnostic offline mutation queue.

- `pending_mutation.dart` — the queued-write data shape and `MutationOutcome`
  (applied/conflict/retryableFailure).
- `offline_queue_store.dart` — queue persistence across app restarts. Production uses
  `flutter_secure_storage`; native installs migrate any existing plaintext JSON queue and its
  backup into secure storage before removing those files. The file store remains available for
  isolated tests and migration compatibility.
- `offline_queue_controller.dart` — the retry/conflict-surfacing state machine. A mutation is
  retried up to `kMaxMutationAttempts` times; past that, or on an explicit conflict from its
  handler, it moves to `OfflineQueueState.conflicts` and is **never retried automatically
  again** — per the migration plan's "never silently overwrite a manager's changes"
  requirement, a conflict is something a person resolves, not something the queue guesses at.
- `offline_queue_connectivity.dart` — flushes the queue on reconnect and once at app startup.
- `offline_queue_providers.dart` — the Riverpod wiring. `offlineQueueHandlersProvider` starts
  empty and is overridden in `app/bootstrap.dart` with the merged handler map from every
  feature that queues mutations, so this folder never imports a feature package directly.

First (and so far only) consumer: `features/tasks` (see its README) — its status-toggle path
tries an immediate online update first and falls back to the queue on failure, using the
task's `updated_at` as an optimistic-concurrency token to detect a conflicting change made in
the meantime.

Still to wire up, per the migration plan's offline-writable scope: checklist responses,
incident drafts, and media-upload retry metadata. Each should register its own
`MutationHandler`(s) the same way `features/tasks/application/tasks_providers.dart`'s
`taskMutationHandlersProvider` does, rather than this folder growing feature-specific
branches.

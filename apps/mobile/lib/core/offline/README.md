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

Ownership: the queue is shared by everyone who signs in on a device, so every entry is stamped
with its owner (`PendingMutation.userId`). `flush` only runs the current user's entries;
`OfflineQueueState.forUser` / `userOfflineQueueProvider` are the only way a screen should read
the queue; `dismissConflict` ignores entries owned by someone else; and sign-out
(`core/auth/sign_out_service.dart`, run for UI and server-initiated sign-outs alike) prunes only
the signed-out user's entries via `clearAll(forUserId:)`. Legacy entries with no owner are kept
but never shown or replayed.

Consumers, each registering its own `MutationHandler`(s) into `offlineQueueHandlersProvider`
(merged in `app/bootstrap.dart`) rather than this folder growing feature-specific branches:

- `features/tasks` — status toggles (immediate online try, queue on a transport failure, the
  task's `updated_at` as the optimistic-concurrency token).
- `features/checklists` — checklist completions.
- `features/incidents` — incident reports (client-generated id, so retries are idempotent).
- `features/media` — incident-evidence photo uploads (metadata is stripped before upload and
  the cached local copy is deleted once stored).

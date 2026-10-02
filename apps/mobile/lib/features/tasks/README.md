# features/tasks

Phase 2: implemented, including offline-writable status changes.

`domain/operational_task.dart` — model, including `updatedAt` used as an
optimistic-concurrency token. `data/tasks_repository.dart` — Supabase-backed repository,
with `updateStatusIfUnchanged` for the offline-queue path. `application/tasks_providers.dart`
— Riverpod providers scoped to `activeVenueProvider`, plus `taskMutationHandlersProvider`
(registered into `core/offline`'s handler registry by `app/bootstrap.dart`).
`presentation/task_list_screen.dart` — list with checkbox-toggle complete/open and a
create-task dialog.

Status changes try an immediate online update first; on any failure other than an explicit
permission denial, the change is queued (`core/offline`) and shown with a "Syncing…" badge
until it's applied on reconnect. If the same task was changed by someone else in the
meantime, the queued change is **not** applied — it surfaces as a dismissible banner instead
of silently overwriting their change, per the migration plan's hard requirement.

Denied writes (e.g. a staff member trying to create a task, which only venue_manager+ may do)
surface as a snackbar rather than a client-side role check, since
`supabase/migrations/20261002010000_tasks_schema.sql`'s RLS policies and
`enforce_task_update_scope` trigger are the actual authority — this feature does not
duplicate that logic.

Not yet implemented: offline support for task *creation* (only the status-toggle path is
wired to the queue so far) and reassigning/editing a task's other fields from the UI (the RLS
policies already allow it for managers; there's just no screen for it yet).

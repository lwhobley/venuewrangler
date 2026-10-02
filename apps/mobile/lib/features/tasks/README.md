# features/tasks

Phase 2, first slice: implemented (online-only CRUD).

`domain/operational_task.dart` — model. `data/tasks_repository.dart` — Supabase-backed
repository. `application/tasks_providers.dart` — Riverpod providers scoped to
`activeVenueProvider`. `presentation/task_list_screen.dart` — list with checkbox-toggle
complete/open and a create-task dialog; denied writes (e.g. a staff member trying to create a
task) surface as a snackbar rather than a client-side role check, since
`supabase/migrations/20261002010000_tasks_schema.sql`'s RLS policies and
`enforce_task_update_scope` trigger are the actual authority.

**Not yet implemented: the offline-writable behavior this feature is supposed to have.**
Per the migration plan, tasks is one of the four workflows that must work offline with an
outbox and explicit conflict surfacing on reconnect ("never silently overwrite a manager's
changes"). This slice is online-only — `core/offline/` is still an empty scaffold. Build the
outbox there next, modeled on the conflict-aware pattern already proven in the legacy Expo
app's `lib/offline-inventory-queue.ts` (see Phase 0 discovery in
`docs/migration/flutter-supabase-rebuild-plan.md`), then wire this feature's status-toggle
path through it.

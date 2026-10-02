# features/checklists

Phase 2: implemented, including offline-writable completion submission.

`domain/` — `ChecklistTemplate`/`ChecklistTemplateItem` models and `ItemResult` (one item's
checked state, serialized into `checklist_completions.item_results` as a jsonb array rather
than a normalized child table — revisit this if per-item evidence photos are added later,
since a photo needs its own row to carry a Storage object reference). `data/` — Supabase
repository; `submitCompletion` is a plain insert, not an upsert (see its doc comment for why
an upsert would be wrong here: `checklist_completions` only allows a manager to UPDATE an
existing row, so an upsert's conflict path would be denied for a staff member's own retry — a
duplicate-key insert on retry is instead treated as "already submitted, done").
`application/checklists_providers.dart` — providers plus `checklistMutationHandlersProvider`
(registered into `core/offline`'s handler registry by `app/bootstrap.dart`, same pattern as
`features/tasks`).

`presentation/checklist_list_screen.dart` lists a venue's templates; tapping one opens
`checklist_completion_screen.dart`, which renders the template's items as checkboxes and
submits a completion. A failed online submission is queued and retried on reconnect, using a
client-generated completion id so the retry is idempotent — unlike `features/tasks`' status
update, there is no conflict-detection concern here, since completing a checklist creates a
new row rather than modifying an existing one.

Not yet implemented: checklist template management UI (creating/editing templates and items —
the RLS policies already support it for managers), and per-item evidence photos.

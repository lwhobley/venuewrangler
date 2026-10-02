# core/offline

Scaffolded in Phase 1; not implemented yet.

Per the migration plan, offline-first support is scoped to four high-value field workflows
only: assigned tasks, checklist responses, incident drafts, and media-upload retry metadata
(see `features/tasks`, `features/checklists`, `features/incidents`, `features/media`). This
folder will hold the shared outbox/sync-queue infrastructure those features build on —
modeled after the conflict-aware pattern already proven in the reference implementation's
`lib/offline-inventory-queue.ts` (Phase 0 discovery) — once Phase 2 reaches those modules.

Do not add app-wide offline support beyond that list; it is an explicit non-goal.

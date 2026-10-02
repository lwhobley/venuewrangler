# features/incidents

Phase 2: implemented, including offline-writable draft reporting.

`domain/incident.dart` — model, `IncidentSeverity`/`IncidentStatus` enums.
`data/incidents_repository.dart` — Supabase repository; `reportIncident` is a plain insert
with duplicate-key-is-success handling, same idempotent-retry reasoning as
`features/checklists`' `submitCompletion`. `application/incidents_providers.dart` — providers
plus `incidentMutationHandlersProvider` (registered into `core/offline`'s handler registry by
`app/bootstrap.dart`).

`presentation/incident_list_screen.dart` lists a venue's incidents (with any still-queued
offline drafts shown first, with a "Syncing…" indicator) and a dialog to report a new one
(title, optional description, severity). A failed online report is queued and retried on
reconnect, using a client-generated incident id for idempotency — this is the "incident
drafts" item in the migration plan's offline-writable scope. Open incidents show a "Resolve"
action for managers (online-only; resolving is not itself offline-writable in this slice,
since it's a less time-critical action than filing the report in the first place).

Resolving an incident is recorded in `public.audit_log` automatically by a database trigger
(`log_incident_status_change`), which is the "audit history" part of the original
requirement — there's no separate incident-specific audit table or UI for it yet, since the
existing audit_log schema already covers it.

Not yet implemented: evidence photo attachments (depends on Supabase Storage, which is Phase
3 scope), and a dedicated incident detail screen (the list screen shows everything there is
to show today).

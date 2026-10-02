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

The report dialog also offers an optional evidence photo, handled by `features/media` (see
its README) — uploaded immediately if online, or queued alongside the incident report if not.
Attachments are not yet shown anywhere in the UI after upload (there's no incident detail
screen to show them on — the list screen is everything there is today), so this is currently
write-only from the user's perspective, which is worth fixing before this ships for real.

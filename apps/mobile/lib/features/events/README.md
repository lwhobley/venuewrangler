# features/events

A venue's calendar of planned events, backed by
`supabase/migrations/20261002180000_events_schema.sql`. This is a simple event list — not the
reference app's full CRM/BEO/contract "event command center" (leads, BEOs, contracts,
forecasting), which is a separate, larger feature not covered by this rebuild pass.

- `domain/event.dart` — `VenueEvent`, `EventStatus`.
- `data/events_repository.dart` — `EventsRepository` interface + Supabase implementation:
  `fetchEventsForVenue`, `createEvent`, `updateStatus`, `deleteEvent`.
- `application/events_providers.dart` — repository + events-for-venue provider.
- `presentation/event_list_screen.dart` — routed at `/events`: lists events for the active
  venue (every venue member can view; only a manager tier can create/update/delete, per RLS),
  with a manual "Add event" dialog.

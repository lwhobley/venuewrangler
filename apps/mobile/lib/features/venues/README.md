# features/venues

Phase 2, first slice: implemented (list/select only).

`domain/venue.dart` — model. `data/venues_repository.dart` — Supabase-backed repository
(RLS does the authorization). `application/venues_providers.dart` — Riverpod providers,
including `activeVenueProvider`, the single source of truth for "which venue is the user
currently acting within," which `app/router.dart` uses to redirect to venue selection when
unset.

Not yet implemented: venue creation/settings UI (the `venues_insert_org_admins` /
`venues_update_org_admins` RLS policies already support this for
organization_owner/organization_admin — the UI just doesn't exist yet), and persisting the
last-selected venue across app restarts (currently in-memory only; see the note in
`venues_providers.dart`).

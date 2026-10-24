# features/venues

Phase 2, first slice: implemented (list/select only).

`domain/venue.dart` — model. `data/venues_repository.dart` — Supabase-backed repository
(RLS does the authorization). `application/venues_providers.dart` — Riverpod providers,
including `activeVenueProvider`, the single source of truth for "which venue is the user
currently acting within," which `app/router.dart` uses to redirect to venue selection when
unset.

Not yet implemented: a standalone "add another venue to my existing org" UI (the
`venues_insert_org_admins` / `venues_update_org_admins` RLS policies already support this for
organization_owner/organization_admin — the UI just doesn't exist yet) and venue settings, and
persisting the last-selected venue across app restarts (currently in-memory only; see the note
in `venues_providers.dart`). The one venue-creation path that does exist is bundled into
signing up a brand-new organization — see `features/organizations/README.md`'s "Workspace
creation" section.

**Venue location** (launch review S1): `presentation/venue_location_screen.dart` (`/venue-location`,
from Settings, the dashboard prompt and the Time Clock) lets managers set the map position
(typed or "use my current location"), a street address for people, and the clock-in radius via
`public.set_venue_location` (managers of the venue, validated, audited).
`presentation/venue_location_prompt.dart` is the manager-only "set your venue's location" card
shown while none is set; the time clock refuses clock-ins until then. There is no geocoding: the
address is not turned into a position.

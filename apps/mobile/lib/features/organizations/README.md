# features/organizations

Phase 2, first slice: implemented.

`domain/organization.dart` — model. `data/organizations_repository.dart` — Supabase-backed
repository (RLS does the authorization, not this code). `application/` — Riverpod providers.
`presentation/organization_venue_switcher_screen.dart` — the post-auth landing screen when no
venue is selected (see `features/venues/application/venues_providers.dart`'s
`activeVenueProvider` and `app/router.dart`'s redirect logic).

Not yet implemented: organization creation/renaming (server-mediated via an Edge Function per
the migration plan — there is no client-side insert/update policy on `organizations` at all),
and an organization settings screen.

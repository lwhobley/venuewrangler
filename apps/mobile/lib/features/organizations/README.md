# features/organizations

Phase 2, first slice: implemented. Workspace creation (below): implemented.

`domain/organization.dart` — model. `data/organizations_repository.dart` — Supabase-backed
repository (RLS does the authorization, not this code). `application/` — Riverpod providers.
`presentation/organization_venue_switcher_screen.dart` — the post-auth landing screen when no
venue is selected (see `features/venues/application/venues_providers.dart`'s
`activeVenueProvider` and `app/router.dart`'s redirect logic).

## Workspace creation ("Launch Workspace")

There is still no client-facing INSERT policy on `organizations`/`memberships` — a brand-new
user can't just insert their way into owning one. Instead `OrganizationsRepository.
createWorkspace()` calls `public.create_workspace` (supabase/migrations), a SECURITY DEFINER
RPC that's the one deliberate, audited bypass: given an authenticated caller, it creates a new
organization + venue and grants that caller an `organization_owner` membership on it, nothing
else. `features/auth/sign_up_screen.dart` is the UI; `pendingWorkspaceCreationTriggerProvider`
in `application/organizations_providers.dart` is what actually calls it, watched once at the
app root (`app/app.dart`) rather than inline in the sign-up screen — see that provider's doc
comment for why (the signUp call that starts this doesn't always hand back a session on the
same tick).

Not yet implemented: organization renaming, and a general organization settings screen.

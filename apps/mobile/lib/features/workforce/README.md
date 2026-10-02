# features/workforce

Staff roster + invites, backed by `supabase/migrations/20261002100000_workforce_invites.sql`.

- `domain/workforce_models.dart` — `RosterMember` (a `memberships` row joined with its
  `profiles.display_name`), `Invite`, `WorkforceRole`.
- `data/workforce_repository.dart` — `WorkforceRepository` interface + Supabase
  implementation: `fetchRosterForVenue`, `fetchInvitesForVenue`, `createInvite`,
  `revokeInvite`.
- `application/workforce_providers.dart` — repository + roster/invites providers.
- `presentation/workforce_roster_screen.dart` — routed at `/workforce`: lists the roster and
  pending invites, lets a manager invite someone by email/role or revoke a pending invite, and
  has an "Import from paste" action that calls `AiRepository.parseStaffImport` and turns each
  parsed row with an email into a one-tap invite.

**Not implemented (by design, see the migration's header comment):** invite *redemption* — an
invitee accepting and becoming an actual `memberships` row. That requires a server-mediated
Edge Function (matching the migration plan's "invite-member Edge Function" item) so a new
user's signup can be safely matched to a pending invite; it's a reasonable next slice once
Phase 3's Edge Function pattern (see `supabase/functions/ai-assistant/`) is extended here.

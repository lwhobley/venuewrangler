# features/workforce

Staff roster + invites, backed by `supabase/migrations/20261002100000_workforce_invites.sql`.

- `domain/workforce_models.dart` — `RosterMember` (a `memberships` row joined with its
  `profiles.display_name`), `Invite`, `WorkforceRole`.
- `data/workforce_repository.dart` — `WorkforceRepository` interface + Supabase
  implementation: `fetchRosterForVenue`, `fetchInvitesForVenue`, `createInvite` /
  `resendInvite` (the `create_invite` / `resend_invite` RPCs in
  `supabase/migrations/20261022110000_invite_onboarding.sql`), `sendInviteEmail` (the
  `invite-send-email` Edge Function) and `revokeInvite`.
- `application/workforce_providers.dart` — repository + roster/invites providers.
- `presentation/workforce_roster_screen.dart` — routed at `/workforce`: lists the roster and
  pending invites (`pending_invites_section.dart`: emailed/expired status, Resend, Revoke).
- `presentation/invite_staff_dialog.dart` — the invite form (full name, email, role) and the
  "Paste a staff list" import (`AiRepository.parseStaffImport`, each parsed row with an email
  becomes a pre-filled invite). Both validate and save inside the dialog and close only on
  success.

Invites: the name the manager types becomes the member's display name when they join. An
expired invite never blocks a new one (it is marked `expired` and replaced). Managers can
invite supervisors and staff only; inviting a venue manager takes an organization owner or
admin (owner decision, enforced by `app_hidden.can_manage_member_role`).

Redemption lives in `features/invites`: the invitation email links to `/join`, where the
person signs up ("Join your team", no venue fields) or signs in, and the invite is accepted
once their email is verified (`inviteRedemptionTriggerProvider`).

**Names** (launch review U5): `domain/member_name.dart` is the one fallback label for a member.
The name itself comes from `app_hidden.member_display_name` on the server (own display name →
staff-profile preferred/legal name → name on the accepted invite or sign-up metadata), used by
`venue_roster`, `venue_schedule_roster`, `team_members`, `chat_contacts` and the time clock RPCs.
Saving a staff profile refreshes the roster providers so a newly entered name shows at once.

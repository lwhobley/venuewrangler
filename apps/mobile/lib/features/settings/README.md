# features/settings

Profile, account, and app settings. Uses the `profiles` table directly (no new migration —
`profiles_select_self`/`profiles_update_self` in
`supabase/migrations/20261002000000_foundation_schema.sql` already scope a user to their own
row).

- `domain/profile.dart` — `Profile`.
- `data/settings_repository.dart` — `SettingsRepository` interface + Supabase implementation:
  `fetchMyProfile`, `updateDisplayName`, `deleteAccount`.
- `application/settings_providers.dart` — repository + the current user's profile provider.
- `presentation/settings_screen.dart` — routed at `/settings`: shows the signed-in email,
  lets the user set/edit their display name, and sign out.
- `presentation/delete_account_button.dart` — personal "delete my account" (App Store/Play
  Store require this for any app that supports account creation), calling
  `public.request_account_deletion` (supabase/migrations/20261007180000_account_deletion.sql)
  then the same sign-out path as the button above. Not organization/tenant offboarding — see
  that migration's header comment and docs/soc2/data-retention-disposal-policy.md §4. A
  standalone widget rather than inline in `SettingsScreen` specifically so it's testable
  without needing to fake `supabaseClientProvider`.

**Not implemented yet:** organization/venue-level settings (there isn't much to configure
there yet beyond what `features/organizations` and `features/workforce` already cover), any
notion of app-wide preferences beyond theme, and tenant/organization offboarding (full
cascade-delete of a venue's data + Stripe subscription cancellation) — deliberately out of
scope for the personal-deletion flow above.

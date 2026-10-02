# features/settings

Profile, account, and app settings. Uses the `profiles` table directly (no new migration —
`profiles_select_self`/`profiles_update_self` in
`supabase/migrations/20261002000000_foundation_schema.sql` already scope a user to their own
row).

- `domain/profile.dart` — `Profile`.
- `data/settings_repository.dart` — `SettingsRepository` interface + Supabase implementation:
  `fetchMyProfile`, `updateDisplayName`.
- `application/settings_providers.dart` — repository + the current user's profile provider.
- `presentation/settings_screen.dart` — routed at `/settings`: shows the signed-in email,
  lets the user set/edit their display name, and sign out.

**Not implemented yet:** organization/venue-level settings (there isn't much to configure
there yet beyond what `features/organizations` and `features/workforce` already cover) and any
notion of app-wide preferences (theme, notifications).

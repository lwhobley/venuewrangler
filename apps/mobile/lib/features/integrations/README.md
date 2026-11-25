# features/integrations

Square/QuickBooks/Gusto connection, status, and disconnect, backed by
`supabase/migrations/20261002140000_payroll_connections_schema.sql` and the
`square-oauth`, `quickbooks-oauth`, `gusto-oauth` Edge Functions. Never renders a provider
secret or raw OAuth token; all of that lives only in `payroll_connections`' encrypted columns,
which a client can never select at all (RLS limits the row to a venue's manager tier, and a
Postgres column-level GRANT additionally excludes the encrypted columns even for them — see
the migration's header comment).

- `domain/payroll_connection.dart` — `PayrollProvider`, `PayrollConnection`.
- `data/integrations_repository.dart` — `IntegrationsRepository` interface + Supabase
  implementation: `fetchConnectionsForVenue` reads the non-secret columns directly;
  `createConnectUrl`/`disconnect` invoke `{provider}-oauth`'s `/connect`/`/disconnect` routes.
- `application/integrations_providers.dart` — repository + connections-for-venue provider.
- `presentation/integrations_screen.dart` — routed at `/integrations`: one row per provider
  with its connection status and a Connect (opens the hosted authorize URL via `url_launcher`)
  or Disconnect button.

**Not independently verified against a live provider sandbox:** none of Square/QuickBooks/
Gusto had real OAuth app credentials available in this environment. Each Edge Function's own
header comment says so and links the provider's OAuth docs to confirm against before
production use — in particular exact scopes, and Gusto's `external_account_id` (left `null`
today; populating it needs a follow-up call to Gusto's own API after token exchange, not
returned by the OAuth callback itself).

## BrightHR

Backed by `supabase/migrations/20261125100000_brighthr_integration.sql` and the `brighthr`
Edge Function (`supabase/functions/brighthr`, API client in `_shared/brighthr.ts`).

- BrightHR only supports OAuth2 client credentials, so there is no consent redirect: a BrightHR
  admin creates a Client ID/Secret at account.brighthr.com/manage-api and a venue manager pastes
  them into `presentation/brighthr_screen.dart` (routed at `/integrations/brighthr`). `/connect`
  verifies them against BrightHR before storing the secret AES-GCM encrypted (bound to
  `venue_id:brighthr`); a column-level grant keeps it out of every client.
- Sync runs on connect, on "Sync now", and every 30 minutes via pg_cron → `brighthr/dispatch`
  (needs Vault entries `brighthr_sync_dispatch_url` / `brighthr_sync_dispatch_secret` and the
  `BRIGHTHR_SYNC_DISPATCH_SECRET` function secret).
- Employees are imported in full; a manager links each one to a team member
  (`public.link_brighthr_employee`), and the member id is written back to BrightHR as the
  employee's `externalReference`. Absences (−30 to +180 days) and Blip clock-ins (last 14 days)
  are imported **only for linked employees**, and kept for 90 days.
- Sickness `reason`, absence `note`s and certification flags are never stored.
- Read-only otherwise: BrightHR's API cannot create shifts, timesheets or leave.

**Not verified against a live BrightHR tenant.** BrightHR's reference leaves several shapes
undocumented (absence `end`, Blip `start`/`end` format, `breaks[].start`, the date format of
`filters.from`/`to`); the parsers accept the plausible variants and skip anything they cannot
read. Check a real sync's `brighthr_sync_runs` and imported rows before relying on it.

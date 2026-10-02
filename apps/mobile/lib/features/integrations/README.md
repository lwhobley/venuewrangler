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

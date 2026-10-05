# Push dispatch setup

Database triggers write `notification_events` for **shift assigned** and **new staff request**
(`supabase/migrations/20261005220028_notification_triggers_and_dispatch.sql`). Rows tagged
`data.origin = 'db'` are fanned out to devices by an `AFTER INSERT` trigger that calls the
internal `notifications-dispatch` Edge Function through `pg_net`.

| Piece | Where | Notes |
|---|---|---|
| `PUSH_DISPATCH_SECRET` | Edge Function secret | shared secret, >= 32 chars |
| `push_dispatch_secret` | Postgres Vault | **same value** as above |
| `push_dispatch_url` | Postgres Vault | `https://<ref>.supabase.co/functions/v1/notifications-dispatch` |

Until both Vault entries exist the trigger is a no-op (in-app notifications still work), and a
failed dispatch only raises a WARNING — it can never roll back the shift or request being saved.

To rotate: set a new `PUSH_DISPATCH_SECRET` (`supabase secrets set`) and update the Vault entry
(`select vault.update_secret(id, 'new-value') from vault.secrets where name = 'push_dispatch_secret'`).

`notifications-send` (a signed-in manager sending an ad-hoc notification) is unchanged for
callers; both functions deliver through `supabase/functions/_shared/push-delivery.ts`.

## POS webhook cutover

`toast-pos` replaces the legacy API's POS webhook and uses a different contract. Any POS gateway
posting to the old API must be reconfigured:

- header `X-Venue-Webhook-Secret` (>= 32 chars) instead of `x-webhook-secret`
- the venue's `pos_connections.webhook_secret_hash` must hold the lowercase SHA-256 of that secret
- closed/paid checks are final: later events for them are acknowledged but ignored
- amounts must be whole non-negative cents

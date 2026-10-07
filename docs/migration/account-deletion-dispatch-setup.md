# Account deletion dispatch setup

`public.request_account_deletion` (`supabase/migrations/20261007180000_account_deletion.sql`)
does all the synchronous, RLS-governed cleanup for a self-service "delete my account" request
(see that migration's header comment for exactly what and why), then queues an
`account_deletion_jobs` row and calls the internal `account-deletion-worker` Edge Function
through `pg_net` to finish the one step SQL can't do: deleting the `auth.users` row via the
Auth Admin API.

| Piece | Where | Notes |
|---|---|---|
| `ACCOUNT_DELETION_DISPATCH_SECRET` | Edge Function secret | shared secret, >= 32 chars |
| `account_deletion_dispatch_secret` | Postgres Vault | **same value** as above |
| `account_deletion_dispatch_url` | Postgres Vault | `https://<ref>.supabase.co/functions/v1/account-deletion-worker` |

Until both Vault entries exist, `request_account_deletion` still does everything *except*
actually deleting the `auth.users` row — the account is already fully removed from the
product (profile, memberships, HR data gone; time entries preserved anonymized) with a
`pending` `account_deletion_jobs` row sitting unprocessed. The `account-deletion-sweep`
pg_cron job (every 10 minutes) re-dispatches anything still pending/failed once those
secrets are set, so provisioning them later still catches up every request made before they
existed — nothing needs to be replayed manually.

To rotate: set a new `ACCOUNT_DELETION_DISPATCH_SECRET` (`supabase secrets set`) and update
the Vault entry (`select vault.update_secret(id, 'new-value') from vault.secrets where name =
'account_deletion_dispatch_secret'`).

A job is only ever marked `completed`/`failed`/`dead` by the Edge Function itself (it has the
real Auth Admin API response; the dispatching SQL functions only fire-and-forget via
`net.http_post` and never see it) — a job stuck on `pending` past a few sweep cycles means the
worker isn't reachable or the Vault entries are missing/wrong, not that deletion failed.

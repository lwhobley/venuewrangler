# Storage deletion worker

`storage-deletion-worker` removes objects through the Supabase Storage API. The database cron
dispatcher is enabled only when `pg_cron`, `pg_net`, and both Vault entries are available.
Without those deployed settings, deletion jobs remain queued and are not falsely marked complete.

Configure these values per Supabase environment before applying
`20261010160000_storage_api_deletion_worker.sql`:

- Edge Function secret `STORAGE_DELETION_DISPATCH_SECRET`: generate a random value with at
  least 32 characters and set the same value in Supabase Vault as
  `storage_deletion_dispatch_secret`.
- Vault secret `storage_deletion_dispatch_url`: the HTTPS URL for that project's deployed
  `storage-deletion-worker` Edge Function.
- Deploy the function with `verify_jwt = false`; its constant-time dispatch-secret check is
  the authentication boundary. Do not commit the secret or use a URL from another environment.

The worker claims at most 100 jobs with a database lease, uses Storage `remove`, and records
completion only after the API call succeeds. A failed job is retried up to ten times; stale
processing leases become claimable after 15 minutes. Confirm cron installation, Vault values,
function secret parity, and a disposable-object deletion in each environment before treating
the worker as operational.

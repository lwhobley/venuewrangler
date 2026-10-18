# supabase/tests

`database/*.test.sql` are pgTAP authorization tests for the RLS policies in
`supabase/migrations/`. They assume the `auth` schema, `auth.uid()`, the
`anon`/`authenticated`/`service_role` roles, and (for the Storage policy tests) the `storage`
schema's `buckets`/`objects` tables already exist, exactly as a real Supabase project
provides them.

## Running locally with the Supabase CLI (preferred once available)

```
supabase test db
```

## Running against a plain Postgres instance (what CI does, and what this repo was
authored/verified against — no Supabase CLI was available in that environment)

```
createdb supabase_migration_check
psql -d supabase_migration_check -f supabase/tests/ci_auth_stub.sql
psql -d supabase_migration_check -f supabase/tests/ci_storage_stub.sql
for f in supabase/migrations/*.sql; do psql -d supabase_migration_check -f "$f"; done
psql -d supabase_migration_check -f supabase/tests/ci_grants_stub.sql
psql -d supabase_migration_check -c "CREATE SCHEMA IF NOT EXISTS tap; CREATE EXTENSION IF NOT EXISTS pgtap SCHEMA tap;"
psql -d supabase_migration_check -c "GRANT USAGE ON SCHEMA tap TO PUBLIC; GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA tap TO PUBLIC;"
psql -d supabase_migration_check -c "ALTER DATABASE supabase_migration_check SET search_path = public, tap;"
pg_prove --dbname supabase_migration_check supabase/tests/database/*.test.sql
```

Note the order: `ci_storage_stub.sql` must run *before* the migrations (the storage-buckets
migration inserts into `storage.buckets` and adds policies to `storage.objects`, which this
stub is what creates at all outside a real Supabase project), whereas `ci_grants_stub.sql`
must run *after* (it grants on tables the migrations create).

`ci_auth_stub.sql`, `ci_storage_stub.sql`, and `ci_grants_stub.sql` are CI-only fixtures —
never apply them to a real Supabase project, which already provides everything they stub
out. See the comment at the top of each file. If the Supabase CLI becomes available in CI,
prefer `supabase test db` and retire all three.

## Why pgTAP lives in its own `tap` schema

Migration `20261017100000_audit_member_lifecycle_and_integrity.sql` removes the implicit PUBLIC
execute grant from every function the migration role creates (and all anon/authenticated access
to new tables and functions in `public`). pgTAP must therefore be installed in a schema that is
opened up explicitly, otherwise tests that `set local role authenticated` cannot call `is()`,
`throws_ok()` and friends. Keeping it out of `public` also lets
`database/security_invariants.test.sql` assert that `public` contains only application objects.

When you add a table or function that a client or an RLS policy must use, grant it explicitly in
the same migration; `security_invariants.test.sql` fails if a new table lacks RLS or a policy-backed
grant, or if a SECURITY DEFINER function does not pin its `search_path`.

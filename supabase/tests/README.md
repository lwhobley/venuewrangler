# supabase/tests

`database/*.test.sql` are pgTAP authorization tests for the RLS policies in
`supabase/migrations/`. They assume the `auth` schema, `auth.uid()`, and the
`anon`/`authenticated`/`service_role` roles already exist, exactly as a real Supabase
project provides them.

## Running locally with the Supabase CLI (preferred once available)

```
supabase test db
```

## Running against a plain Postgres instance (what CI does, and what this repo was
authored/verified against — no Supabase CLI was available in that environment)

```
createdb supabase_migration_check
psql -d supabase_migration_check -f supabase/tests/ci_auth_stub.sql
for f in supabase/migrations/*.sql; do psql -d supabase_migration_check -f "$f"; done
psql -d supabase_migration_check -f supabase/tests/ci_grants_stub.sql
psql -d supabase_migration_check -c "CREATE EXTENSION IF NOT EXISTS pgtap;"
pg_prove --dbname supabase_migration_check supabase/tests/database/*.test.sql
```

`ci_auth_stub.sql` and `ci_grants_stub.sql` are CI-only fixtures — never apply them to a
real Supabase project, which already provides everything they stub out. See the comment
at the top of each file. If the Supabase CLI becomes available in CI, prefer `supabase
test db` and retire both files.

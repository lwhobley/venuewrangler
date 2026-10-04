-- CI-only fixture: stubs the parts of a real Supabase project that
-- supabase/migrations/*.sql assume already exist (the `auth` schema, `auth.uid()`, and the
-- anon/authenticated/service_role roles), so the RLS authorization tests under
-- supabase/tests/database can run against a plain Postgres instance in CI without the
-- Supabase CLI.
--
-- This file must NEVER be applied to a real Supabase project (which already provides all of
-- this) and is not itself a migration — it intentionally lives outside supabase/migrations/.
-- If the Supabase CLI becomes available in CI, prefer `supabase test db` against the real
-- local stack instead and retire this file.

create schema if not exists auth;

create table if not exists auth.users (
  id uuid primary key default gen_random_uuid(),
  email text,
  email_confirmed_at timestamptz
);

create or replace function auth.uid() returns uuid
language sql stable
as $$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then
    create role service_role nologin bypassrls;
  end if;
end
$$;

grant usage on schema public to anon, authenticated, service_role;
grant usage on schema auth to anon, authenticated, service_role;
grant select on auth.users to anon, authenticated, service_role;

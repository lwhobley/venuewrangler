-- CI-only fixture: stubs the parts of real Supabase Storage (the storage schema's
-- buckets/objects tables) that supabase/migrations/20261002040000_storage_buckets.sql
-- assumes already exist, so the Storage policy tests under supabase/tests/database can run
-- against a plain Postgres instance in CI without the Supabase CLI. See ci_auth_stub.sql for
-- the same reasoning applied to the `auth` schema.
--
-- This is a deliberately minimal stand-in — real Supabase Storage has considerably more
-- columns/triggers/functions than this — just enough surface for RLS policies keyed on
-- `bucket_id` and `name` (the object path) to be exercised. This file must NEVER be applied
-- to a real Supabase project and is not itself a migration.
--
-- Every create is guarded with "if not exists": a Postgres image that already bundles the
-- real Supabase Storage schema (used so pgtap/pg_net/pg_cron are available - see
-- supabase-ci.yml) creates these itself at container start, with its own, richer columns.
-- This stub only needs to fill the gap on a vanilla Postgres image.

create schema if not exists storage;

create table if not exists storage.buckets (
  id text primary key,
  name text not null,
  public boolean not null default false,
  file_size_limit bigint,
  allowed_mime_types text[],
  created_at timestamptz not null default now()
);

create table if not exists storage.objects (
  id uuid primary key default gen_random_uuid(),
  bucket_id text references storage.buckets (id),
  name text not null,
  owner uuid references auth.users (id),
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

alter table storage.objects enable row level security;

grant usage on schema storage to anon, authenticated, service_role;
grant select on storage.buckets to anon, authenticated, service_role;
grant select, insert, update, delete on storage.objects to anon, authenticated, service_role;

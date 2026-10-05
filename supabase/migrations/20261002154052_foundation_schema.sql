-- Phase 1 foundation schema: organizations, venues, memberships, roles, profiles, audit_log.
--
-- Design notes (see docs/migration/flutter-supabase-rebuild-plan.md §1, §6 OQ-1/OQ-2):
--   * Role mapping decision (OQ-1): the legacy 4-tier role model (staff/server/manager/owner)
--     is replaced by six roles. platform_admin is cross-organization and intentionally lives
--     in its own table (platform_admins), not in memberships, since it is not scoped to a
--     single organization. organization_owner/organization_admin are org-level memberships
--     (venue_id is null). venue_manager/supervisor/staff are venue-level memberships.
--   * Organization-layer decision (OQ-2): this migration only creates the table shape. The
--     backfill strategy for existing venues (1:1 org-per-venue vs. grouping multi-venue
--     customers) is a data migration to be written once that business decision is made —
--     it is intentionally not included here.
--   * Every policy below is additive on top of row-level security being enabled with no
--     policies (default-deny). There is no policy granting INSERT/UPDATE/DELETE on
--     organizations, memberships, platform_admins, or audit_log to `authenticated` at all:
--     those mutations are server-mediated (Edge Functions using the service role), per the
--     hard requirement that tenant authorization logic must not be bypassable by a modified
--     client.

create extension if not exists pgcrypto;

create type public.app_role as enum (
  'platform_admin',
  'organization_owner',
  'organization_admin',
  'venue_manager',
  'supervisor',
  'staff'
);

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

create table public.organizations (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(trim(name)) > 0),
  created_by uuid references auth.users (id),
  created_at timestamptz not null default now()
);

create table public.venues (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  name text not null check (char_length(trim(name)) > 0),
  created_by uuid references auth.users (id),
  created_at timestamptz not null default now()
);

create index venues_organization_id_idx on public.venues (organization_id);

-- One row per authenticated user, created automatically on sign-up (see trigger below).
create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  display_name text,
  created_at timestamptz not null default now()
);

-- platform_admin is deliberately NOT a row in `memberships`: it is a cross-organization
-- capability, not something scoped to one organization_id, so it cannot share that table's
-- (user_id, organization_id, venue_id) shape without becoming nullable in a way that weakens
-- every other policy's assumptions.
create table public.platform_admins (
  user_id uuid primary key references auth.users (id) on delete cascade,
  created_by uuid references auth.users (id),
  created_at timestamptz not null default now()
);

-- venue_id = null means an organization-level membership (organization_owner,
-- organization_admin): the member can act across every venue in that organization.
-- venue_id set means a venue-scoped membership (venue_manager, supervisor, staff).
create table public.memberships (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  organization_id uuid not null references public.organizations (id) on delete cascade,
  venue_id uuid references public.venues (id) on delete cascade,
  role public.app_role not null,
  created_by uuid references auth.users (id),
  created_at timestamptz not null default now(),
  constraint memberships_org_level_roles_check check (
    (venue_id is null and role in ('organization_owner', 'organization_admin'))
    or (venue_id is not null and role in ('venue_manager', 'supervisor', 'staff'))
  ),
  constraint memberships_not_platform_admin check (role <> 'platform_admin'),
  unique (user_id, organization_id, venue_id)
);

create index memberships_user_id_idx on public.memberships (user_id);
create index memberships_organization_id_idx on public.memberships (organization_id);
create index memberships_venue_id_idx on public.memberships (venue_id);

-- Append-only. No update/delete policy exists for any client role, and no insert policy
-- exists for `authenticated` either — rows are written exclusively by Edge Functions using
-- the service role (which bypasses RLS), so a modified client can never fabricate or alter
-- an audit entry.
create table public.audit_log (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid references public.organizations (id) on delete set null,
  venue_id uuid references public.venues (id) on delete set null,
  actor_user_id uuid references auth.users (id),
  action text not null,
  target_table text,
  target_id uuid,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index audit_log_organization_id_idx on public.audit_log (organization_id);
create index audit_log_created_at_idx on public.audit_log (created_at);

-- ---------------------------------------------------------------------------
-- Internal authorization helpers (not exposed to PostgREST; schema not in the API's
-- exposed-schema list). SECURITY DEFINER + a fixed search_path so they run as the schema
-- owner and therefore bypass RLS on `memberships`/`platform_admins` themselves — this is
-- what avoids infinite policy recursion when a policy on `memberships` calls a helper that
-- itself reads `memberships`.
-- ---------------------------------------------------------------------------

create schema if not exists app_hidden;
revoke all on schema app_hidden from public, anon, authenticated;

create or replace function app_hidden.is_platform_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.platform_admins pa where pa.user_id = auth.uid()
  );
$$;

create or replace function app_hidden.has_org_role(p_org_id uuid, p_roles public.app_role[])
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select
    app_hidden.is_platform_admin()
    or exists (
      select 1 from public.memberships m
      where m.user_id = auth.uid()
        and m.organization_id = p_org_id
        and m.venue_id is null
        and m.role = any(p_roles)
    );
$$;

create or replace function app_hidden.has_venue_role(p_venue_id uuid, p_roles public.app_role[])
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select
    app_hidden.is_platform_admin()
    or exists (
      select 1
      from public.memberships m
      join public.venues v on v.id = p_venue_id
      where m.user_id = auth.uid()
        and (
          (m.venue_id = p_venue_id and m.role = any(p_roles))
          or (m.venue_id is null and m.organization_id = v.organization_id and m.role = any(p_roles))
        )
    );
$$;

create or replace function app_hidden.is_org_member(p_org_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select
    app_hidden.is_platform_admin()
    or exists (
      select 1 from public.memberships m
      where m.user_id = auth.uid() and m.organization_id = p_org_id
    );
$$;

create or replace function app_hidden.is_venue_member(p_venue_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select
    app_hidden.is_platform_admin()
    or exists (
      select 1
      from public.memberships m
      join public.venues v on v.id = p_venue_id
      where m.user_id = auth.uid()
        and (m.venue_id = p_venue_id or (m.venue_id is null and m.organization_id = v.organization_id))
    );
$$;

create or replace function app_hidden.shares_scope_with(p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select
    app_hidden.is_platform_admin()
    or exists (
      select 1
      from public.memberships mine
      join public.memberships theirs
        on theirs.organization_id = mine.organization_id
       and (mine.venue_id is null or theirs.venue_id is null or mine.venue_id = theirs.venue_id)
      where mine.user_id = auth.uid()
        and theirs.user_id = p_user_id
    );
$$;

-- Auto-create a profile row on sign-up so `authenticated` never needs an INSERT policy on
-- `profiles` at all.
create or replace function app_hidden.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id) values (new.id)
  on conflict (id) do nothing;
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function app_hidden.handle_new_user();

-- ---------------------------------------------------------------------------
-- Row-level security: enable + FORCE on every tenant table, then add narrow policies.
-- FORCE ROW LEVEL SECURITY matters here because these tables are also owned by the
-- migration role; without FORCE, that owner (and anything running as it) would silently
-- bypass RLS, which is exactly the trust-boundary mistake flagged in Phase 0 (§1) for the
-- legacy NestJS/Prisma implementation. The only privileged writer should be the explicitly
-- BYPASSRLS `service_role`, never the table owner by default.
-- ---------------------------------------------------------------------------

alter table public.organizations enable row level security;
alter table public.organizations force row level security;
alter table public.venues enable row level security;
alter table public.venues force row level security;
alter table public.profiles enable row level security;
alter table public.profiles force row level security;
alter table public.platform_admins enable row level security;
alter table public.platform_admins force row level security;
alter table public.memberships enable row level security;
alter table public.memberships force row level security;
alter table public.audit_log enable row level security;
alter table public.audit_log force row level security;

-- organizations: members can read their own organization. No client-side insert/update/
-- delete policy exists anywhere in this file — organization creation/renaming/deletion is
-- server-mediated (an Edge Function using the service role), per the hard requirement that
-- platform-admin-level and tenant-provisioning actions must not be directly exposed.
create policy organizations_select_members on public.organizations
  for select to authenticated
  using (app_hidden.is_org_member(id));

-- venues: members (org-level or venue-level) can read. Only organization_owner/
-- organization_admin (or platform_admin) can create or rename venues directly; venue
-- deletion is intentionally left server-mediated (no delete policy) since it cascades
-- every venue-scoped table in the system.
create policy venues_select_members on public.venues
  for select to authenticated
  using (app_hidden.is_venue_member(id));

create policy venues_insert_org_admins on public.venues
  for insert to authenticated
  with check (app_hidden.has_org_role(organization_id, array['organization_owner', 'organization_admin']::public.app_role[]));

create policy venues_update_org_admins on public.venues
  for update to authenticated
  using (app_hidden.has_org_role(organization_id, array['organization_owner', 'organization_admin']::public.app_role[]))
  with check (app_hidden.has_org_role(organization_id, array['organization_owner', 'organization_admin']::public.app_role[]));

-- profiles: a user can always read/update their own profile; a user can read (but not
-- write) the profile of anyone who shares an organization or venue scope with them, so
-- venue rosters can show names without exposing every profile in the system.
create policy profiles_select_self on public.profiles
  for select to authenticated
  using (id = auth.uid());

create policy profiles_select_shared_scope on public.profiles
  for select to authenticated
  using (app_hidden.shares_scope_with(id));

create policy profiles_update_self on public.profiles
  for update to authenticated
  using (id = auth.uid())
  with check (id = auth.uid());

-- memberships: a user can always see their own membership rows; organization_owner/
-- organization_admin (or platform_admin) can see every membership in their organization,
-- which is what venue-admin screens need to render a roster. No insert/update/delete
-- policy exists for `authenticated` at all: granting, changing, or revoking a role is a
-- high-risk action that must go through an audited, device-attestation-checked Edge
-- Function, never a direct table write a modified client could forge.
create policy memberships_select_self on public.memberships
  for select to authenticated
  using (user_id = auth.uid());

create policy memberships_select_org_admins on public.memberships
  for select to authenticated
  using (app_hidden.has_org_role(organization_id, array['organization_owner', 'organization_admin']::public.app_role[]));

-- platform_admins: no policy at all for `authenticated`/`anon` — this table is fully
-- invisible to every client role. Only the service role (which bypasses RLS) can read or
-- write it, enforcing "keep platform-admin actions server-mediated" at the database level,
-- not just by convention in application code.

-- audit_log: organization_owner/organization_admin (or platform_admin) can read their
-- organization's audit trail. No insert/update/delete policy exists for any client role —
-- every audit row is written by a service-role Edge Function or trigger, so the log cannot
-- be forged or tampered with from a modified client.
create policy audit_log_select_org_admins on public.audit_log
  for select to authenticated
  using (
    organization_id is not null
    and app_hidden.has_org_role(organization_id, array['organization_owner', 'organization_admin']::public.app_role[])
  );

-- Migration: 20261002270000_pos_schema.sql
-- Module: pos (Phase 4, Batch 2)
-- Description: Bidirectional POS integration schema with pos_connections (encrypted tokens
-- and hashed secret withheld via column-level security), idempotent pos_checks,
-- and pos_outbound_commands queue table with batch claim worker and RLS.

-- -----------------------------------------------------------------------------
-- 1. POS Connections
-- -----------------------------------------------------------------------------
create table if not exists public.pos_connections (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  venue_id uuid not null references public.venues(id) on delete cascade,
  provider text not null check (char_length(trim(provider)) > 0),
  external_location_id text,
  status text not null default 'active' check (status in ('active', 'inactive', 'revoked')),
  webhook_secret_hash text,
  credentials_encrypted text,
  last_sync_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint pos_connections_venue_provider_unique unique (venue_id, provider)
);

create index if not exists pos_connections_venue_id_idx on public.pos_connections (venue_id);

create or replace function app_hidden.pos_connections_derive_org()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_org_id uuid;
begin
  if tg_op = 'INSERT' then
    select organization_id into v_org_id from public.venues where id = new.venue_id;
    if v_org_id is null then
      raise exception 'invalid_venue_id: venue does not exist' using errcode = '23503';
    end if;
    new.organization_id := v_org_id;
    new.created_at := now();
    new.updated_at := now();
    return new;
  elsif tg_op = 'UPDATE' then
    if new.venue_id <> old.venue_id then
      raise exception 'venue_id cannot be modified once set' using errcode = '42501';
    end if;
    if new.organization_id <> old.organization_id then
      raise exception 'organization_id cannot be modified once set' using errcode = '42501';
    end if;
    new.updated_at := now();
    return new;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_pos_connections_derive_org on public.pos_connections;
create trigger trg_pos_connections_derive_org
  before insert or update on public.pos_connections
  for each row
  execute function app_hidden.pos_connections_derive_org();

alter table public.pos_connections enable row level security;
alter table public.pos_connections force row level security;

-- -----------------------------------------------------------------------------
-- 2. POS Checks (Inbound Ingestion)
-- -----------------------------------------------------------------------------
create table if not exists public.pos_checks (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  venue_id uuid not null references public.venues(id) on delete cascade,
  pos_connection_id uuid references public.pos_connections(id) on delete set null,
  provider text not null,
  external_check_id text not null,
  table_label text,
  server_name text,
  guest_name text,
  guest_count integer,
  opened_at timestamptz not null,
  closed_at timestamptz,
  subtotal_cents integer not null default 0 check (subtotal_cents >= 0),
  tax_cents integer not null default 0 check (tax_cents >= 0),
  tip_cents integer not null default 0 check (tip_cents >= 0),
  total_cents integer not null default 0 check (total_cents >= 0),
  status text not null default 'closed' check (status in ('open', 'closed', 'voided')),
  menu_items jsonb not null default '[]'::jsonb,
  raw_payload jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint pos_checks_venue_provider_external_unique unique (venue_id, provider, external_check_id)
);

create index if not exists pos_checks_venue_opened_idx on public.pos_checks (venue_id, opened_at);
create index if not exists pos_checks_venue_status_idx on public.pos_checks (venue_id, status);

create or replace function app_hidden.pos_checks_derive_org()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_org_id uuid;
begin
  if tg_op = 'INSERT' then
    select organization_id into v_org_id from public.venues where id = new.venue_id;
    if v_org_id is null then
      raise exception 'invalid_venue_id: venue does not exist' using errcode = '23503';
    end if;
    new.organization_id := v_org_id;
    new.created_at := now();
    new.updated_at := now();
    return new;
  elsif tg_op = 'UPDATE' then
    if new.venue_id <> old.venue_id then
      raise exception 'venue_id cannot be modified once set' using errcode = '42501';
    end if;
    if new.organization_id <> old.organization_id then
      raise exception 'organization_id cannot be modified once set' using errcode = '42501';
    end if;
    new.updated_at := now();
    return new;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_pos_checks_derive_org on public.pos_checks;
create trigger trg_pos_checks_derive_org
  before insert or update on public.pos_checks
  for each row
  execute function app_hidden.pos_checks_derive_org();

alter table public.pos_checks enable row level security;
alter table public.pos_checks force row level security;

-- -----------------------------------------------------------------------------
-- 3. POS Outbound Commands (Queue Table for 86 Items, Menu Sync, etc.)
-- -----------------------------------------------------------------------------
create table if not exists public.pos_outbound_commands (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  venue_id uuid not null references public.venues(id) on delete cascade,
  pos_connection_id uuid not null references public.pos_connections(id) on delete cascade,
  provider text not null default 'toast',
  command_type text not null check (
    command_type in ('update_item_availability_86', 'sync_menu_item', 'void_item')
  ),
  payload jsonb not null default '{}'::jsonb,
  status text not null default 'pending' check (
    status in ('pending', 'processing', 'sent', 'failed', 'dead')
  ),
  attempts integer not null default 0 check (attempts >= 0),
  max_attempts integer not null default 5,
  last_error text,
  sent_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists pos_outbound_commands_pending_idx
  on public.pos_outbound_commands (status, created_at)
  where status in ('pending', 'failed');

create or replace function app_hidden.pos_outbound_commands_derive_org()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_conn_venue_id uuid;
  v_conn_org_id uuid;
begin
  select venue_id, organization_id into v_conn_venue_id, v_conn_org_id
  from public.pos_connections where id = new.pos_connection_id;

  if v_conn_venue_id is null then
    raise exception 'invalid_pos_connection_id: pos connection does not exist' using errcode = '23503';
  end if;

  new.venue_id := v_conn_venue_id;
  new.organization_id := v_conn_org_id;
  new.created_at := now();
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists trg_pos_outbound_commands_derive_org on public.pos_outbound_commands;
create trigger trg_pos_outbound_commands_derive_org
  before insert on public.pos_outbound_commands
  for each row
  execute function app_hidden.pos_outbound_commands_derive_org();

alter table public.pos_outbound_commands enable row level security;
alter table public.pos_outbound_commands force row level security;

-- Claim batch of outbound commands for worker
create or replace function app_hidden.claim_pos_outbound_commands_batch(p_batch_size integer default 10)
returns setof public.pos_outbound_commands
language plpgsql
security definer
set search_path = ''
as $$
begin
  return query
  update public.pos_outbound_commands
  set
    status = 'processing',
    attempts = attempts + 1,
    updated_at = now()
  where id in (
    select id
    from public.pos_outbound_commands
    where status in ('pending', 'failed')
      and attempts < max_attempts
    order by created_at asc
    limit p_batch_size
    for update skip locked
  )
  returning *;
end;
$$;

-- -----------------------------------------------------------------------------
-- 4. Row Level Security Policies
-- -----------------------------------------------------------------------------

-- POS CONNECTIONS RLS:
-- Managers and owners can view connections (non-secret columns)
create policy pos_connections_select_managers on public.pos_connections
  for select to authenticated
  using (
    app_hidden.has_venue_role(
      venue_id,
      array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
    )
  );

-- POS CHECKS RLS:
-- Venue members can view checks
create policy pos_checks_select_members on public.pos_checks
  for select to authenticated
  using (
    app_hidden.has_venue_role(
      venue_id,
      array['staff', 'supervisor', 'venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
    )
  );

-- POS OUTBOUND COMMANDS RLS:
-- Venue members can view queued commands
create policy pos_outbound_commands_select_members on public.pos_outbound_commands
  for select to authenticated
  using (
    app_hidden.has_venue_role(
      venue_id,
      array['staff', 'supervisor', 'venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
    )
  );

-- Managers only can enqueue outbound commands (86 items, menu changes)
create policy pos_outbound_commands_insert_managers on public.pos_outbound_commands
  for insert to authenticated
  with check (
    app_hidden.has_venue_role(
      venue_id,
      array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
    )
  );

-- -----------------------------------------------------------------------------
-- 5. Column-Level Security & Grants
-- -----------------------------------------------------------------------------

-- Hide webhook_secret_hash and credentials_encrypted from authenticated users
revoke all on public.pos_connections from authenticated;
grant select (
  id, organization_id, venue_id, provider, external_location_id, status, last_sync_at, created_at, updated_at
) on public.pos_connections to authenticated;

-- Grants for pos_checks (read-only for authenticated, writes happen via webhook service role)
grant select on public.pos_checks to authenticated;

-- Grants for pos_outbound_commands
grant select, insert on public.pos_outbound_commands to authenticated;

-- Migration: 20261002250000_guests_reservations_schema.sql
-- Modules: guests & reservations (Phase 4, Batch 2)
-- Description: Adds guests, guest_household_links, reservations, reservation_connections,
-- and webhook_replay_log tables with derive-don't-trust triggers, column-level security,
-- replay protection, and strict RLS.

-- -----------------------------------------------------------------------------
-- 1. Guests
-- -----------------------------------------------------------------------------
create table if not exists public.guests (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  venue_id uuid not null references public.venues(id) on delete cascade,
  full_name text not null check (char_length(trim(full_name)) > 0),
  phone text,
  email text,
  notes text,
  dietary_notes text,
  tags text[] not null default '{}',
  guest_tier text not null default 'standard',
  lifecycle_stage text not null default 'lead',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists guests_venue_id_idx on public.guests (venue_id);
create index if not exists guests_venue_phone_idx on public.guests (venue_id, phone);
create index if not exists guests_venue_email_idx on public.guests (venue_id, email);
create index if not exists guests_venue_name_idx on public.guests (venue_id, full_name);

-- Derive organization_id from venue_id trigger
create or replace function app_hidden.guests_derive_org_and_lock_venue()
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

drop trigger if exists trg_guests_derive_org on public.guests;
create trigger trg_guests_derive_org
  before insert or update on public.guests
  for each row
  execute function app_hidden.guests_derive_org_and_lock_venue();

alter table public.guests enable row level security;
alter table public.guests force row level security;

-- -----------------------------------------------------------------------------
-- 2. Guest Household Links
-- -----------------------------------------------------------------------------
create table if not exists public.guest_household_links (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  venue_id uuid not null references public.venues(id) on delete cascade,
  from_guest_id uuid not null references public.guests(id) on delete cascade,
  to_guest_id uuid not null references public.guests(id) on delete cascade,
  relationship text not null check (char_length(trim(relationship)) > 0),
  created_at timestamptz not null default now(),
  constraint guest_household_unique unique (from_guest_id, to_guest_id),
  constraint guest_household_no_self check (from_guest_id <> to_guest_id)
);

create index if not exists guest_household_links_venue_idx on public.guest_household_links (venue_id);
create index if not exists guest_household_links_to_guest_idx on public.guest_household_links (to_guest_id);

create or replace function app_hidden.guest_household_links_derive()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_from_venue_id uuid;
  v_from_org_id uuid;
  v_to_venue_id uuid;
begin
  select venue_id, organization_id into v_from_venue_id, v_from_org_id
  from public.guests where id = new.from_guest_id;

  select venue_id into v_to_venue_id
  from public.guests where id = new.to_guest_id;

  if v_from_venue_id is null or v_to_venue_id is null then
    raise exception 'invalid_guest_id: one or both guests do not exist' using errcode = '23503';
  end if;

  if v_from_venue_id <> v_to_venue_id then
    raise exception 'cross_venue_household_link_forbidden: guests must belong to the same venue'
      using errcode = '42501';
  end if;

  new.venue_id := v_from_venue_id;
  new.organization_id := v_from_org_id;
  new.created_at := now();
  return new;
end;
$$;

drop trigger if exists trg_guest_household_links_derive on public.guest_household_links;
create trigger trg_guest_household_links_derive
  before insert on public.guest_household_links
  for each row
  execute function app_hidden.guest_household_links_derive();

alter table public.guest_household_links enable row level security;
alter table public.guest_household_links force row level security;

-- -----------------------------------------------------------------------------
-- 3. Reservations
-- -----------------------------------------------------------------------------
create table if not exists public.reservations (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  venue_id uuid not null references public.venues(id) on delete cascade,
  guest_id uuid references public.guests(id) on delete set null,
  guest_name text not null check (char_length(trim(guest_name)) > 0),
  guest_phone text,
  guest_email text,
  party_size integer not null check (party_size > 0),
  reservation_time timestamptz not null,
  duration_minutes integer not null default 90 check (duration_minutes > 0),
  source text not null default 'direct',
  status text not null default 'confirmed' check (
    status in ('pending', 'confirmed', 'seated', 'completed', 'cancelled', 'no_show')
  ),
  special_requests text,
  tags text[] not null default '{}',
  estimated_value_cents integer check (estimated_value_cents is null or estimated_value_cents >= 0),
  deposit_due_cents integer check (deposit_due_cents is null or deposit_due_cents >= 0),
  deposit_status text not null default 'none' check (
    deposit_status in ('none', 'required', 'pending', 'paid', 'refunded')
  ),
  deposit_checkout_session_id text,
  deposit_payment_intent_id text,
  deposit_paid_at timestamptz,
  external_id text,
  last_external_event_at timestamptz,
  seated_at timestamptz,
  completed_at timestamptz,
  cancelled_at timestamptz,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index if not exists reservations_venue_source_external_idx
  on public.reservations (venue_id, source, external_id)
  where external_id is not null;

create index if not exists reservations_venue_time_idx on public.reservations (venue_id, reservation_time);
create index if not exists reservations_venue_status_idx on public.reservations (venue_id, status);
create index if not exists reservations_guest_id_idx on public.reservations (guest_id);

create or replace function app_hidden.reservations_derive_org_and_lock_venue()
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

drop trigger if exists trg_reservations_derive_org on public.reservations;
create trigger trg_reservations_derive_org
  before insert or update on public.reservations
  for each row
  execute function app_hidden.reservations_derive_org_and_lock_venue();

alter table public.reservations enable row level security;
alter table public.reservations force row level security;

-- -----------------------------------------------------------------------------
-- 4. Reservation Connections (Outbound/Inbound Sync Settings & Hashed Secret)
-- -----------------------------------------------------------------------------
create table if not exists public.reservation_connections (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  venue_id uuid not null references public.venues(id) on delete cascade,
  provider text not null check (char_length(trim(provider)) > 0),
  status text not null default 'active' check (status in ('active', 'inactive', 'revoked')),
  webhook_secret_hash text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint reservation_connections_venue_provider_unique unique (venue_id, provider)
);

create index if not exists reservation_connections_venue_idx on public.reservation_connections (venue_id);

create or replace function app_hidden.reservation_connections_derive_org()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_org_id uuid;
begin
  select organization_id into v_org_id from public.venues where id = new.venue_id;
  if v_org_id is null then
    raise exception 'invalid_venue_id: venue does not exist' using errcode = '23503';
  end if;
  new.organization_id := v_org_id;
  new.created_at := now();
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists trg_reservation_connections_derive_org on public.reservation_connections;
create trigger trg_reservation_connections_derive_org
  before insert on public.reservation_connections
  for each row
  execute function app_hidden.reservation_connections_derive_org();

alter table public.reservation_connections enable row level security;
alter table public.reservation_connections force row level security;

-- -----------------------------------------------------------------------------
-- 5. Webhook Replay Log (Replay protection for webhook endpoints)
-- -----------------------------------------------------------------------------
create table if not exists public.webhook_replay_log (
  id uuid primary key default gen_random_uuid(),
  venue_id uuid not null references public.venues(id) on delete cascade,
  webhook_id text not null,
  received_at timestamptz not null default now(),
  constraint webhook_replay_log_venue_webhook_unique unique (venue_id, webhook_id)
);

create index if not exists webhook_replay_log_received_at_idx on public.webhook_replay_log (received_at);

alter table public.webhook_replay_log enable row level security;
alter table public.webhook_replay_log force row level security;

-- Atomic replay check function: returns true if fresh and recorded, false if already seen
create or replace function app_hidden.record_and_check_webhook_replay(
  p_venue_id uuid,
  p_webhook_id text,
  p_received_at timestamptz default now()
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.webhook_replay_log (venue_id, webhook_id, received_at)
  values (p_venue_id, p_webhook_id, p_received_at);
  return true;
exception
  when unique_violation then
    return false;
end;
$$;

-- -----------------------------------------------------------------------------
-- 6. Row Level Security Policies
-- -----------------------------------------------------------------------------

-- GUESTS RLS:
-- Venue members (staff or managers) can view guests
create policy guests_select_venue_members on public.guests
  for select to authenticated
  using (
    app_hidden.has_venue_role(
      venue_id,
      array['staff', 'supervisor', 'venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
    )
  );

-- Staff and managers can insert/update guests
create policy guests_insert_venue_members on public.guests
  for insert to authenticated
  with check (
    app_hidden.has_venue_role(
      venue_id,
      array['staff', 'supervisor', 'venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
    )
  );

create policy guests_update_venue_members on public.guests
  for update to authenticated
  using (
    app_hidden.has_venue_role(
      venue_id,
      array['staff', 'supervisor', 'venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
    )
  )
  with check (
    app_hidden.has_venue_role(
      venue_id,
      array['staff', 'supervisor', 'venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
    )
  );

-- Managers only can delete guests
create policy guests_delete_managers on public.guests
  for delete to authenticated
  using (
    app_hidden.has_venue_role(
      venue_id,
      array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
    )
  );

-- GUEST HOUSEHOLD LINKS RLS:
create policy guest_household_links_select on public.guest_household_links
  for select to authenticated
  using (
    app_hidden.has_venue_role(
      venue_id,
      array['staff', 'supervisor', 'venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
    )
  );

create policy guest_household_links_insert on public.guest_household_links
  for insert to authenticated
  with check (
    app_hidden.has_venue_role(
      venue_id,
      array['staff', 'supervisor', 'venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
    )
  );

create policy guest_household_links_delete on public.guest_household_links
  for delete to authenticated
  using (
    app_hidden.has_venue_role(
      venue_id,
      array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
    )
  );

-- RESERVATIONS RLS:
create policy reservations_select_venue_members on public.reservations
  for select to authenticated
  using (
    app_hidden.has_venue_role(
      venue_id,
      array['staff', 'supervisor', 'venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
    )
  );

create policy reservations_insert_venue_members on public.reservations
  for insert to authenticated
  with check (
    app_hidden.has_venue_role(
      venue_id,
      array['staff', 'supervisor', 'venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
    )
  );

create policy reservations_update_venue_members on public.reservations
  for update to authenticated
  using (
    app_hidden.has_venue_role(
      venue_id,
      array['staff', 'supervisor', 'venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
    )
  )
  with check (
    app_hidden.has_venue_role(
      venue_id,
      array['staff', 'supervisor', 'venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
    )
  );

create policy reservations_delete_managers on public.reservations
  for delete to authenticated
  using (
    app_hidden.has_venue_role(
      venue_id,
      array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
    )
  );

-- RESERVATION CONNECTIONS RLS:
-- Managers only can view connection status
create policy reservation_connections_select_managers on public.reservation_connections
  for select to authenticated
  using (
    app_hidden.has_venue_role(
      venue_id,
      array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
    )
  );

-- -----------------------------------------------------------------------------
-- 7. Column-Level Security & Grants
-- -----------------------------------------------------------------------------

-- Revoke all access to webhook_replay_log from authenticated (internal service-role only)
revoke all on public.webhook_replay_log from authenticated;

-- For reservation_connections, revoke all and grant select ONLY on non-secret columns
revoke all on public.reservation_connections from authenticated;
grant select (
  id, organization_id, venue_id, provider, status, created_at, updated_at
) on public.reservation_connections to authenticated;

-- Ensure authenticated can select, insert, update, delete on guests & reservations per RLS
grant select, insert, update, delete on public.guests to authenticated;
grant select, insert, delete on public.guest_household_links to authenticated;
grant select, insert, update, delete on public.reservations to authenticated;

-- Migration: 20261002260000_floor_schema.sql
-- Module: floor (Phase 4, Batch 2)
-- Description: Adds floor_plans, floor_tables, floor_table_assignments tables,
-- derive triggers, advisory-locking transactional functions for merge, split,
-- assignment, and status updates, strict RLS, and Realtime publications.

-- -----------------------------------------------------------------------------
-- 1. Floor Plans
-- -----------------------------------------------------------------------------
create table if not exists public.floor_plans (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  venue_id uuid not null references public.venues(id) on delete cascade,
  name text not null check (char_length(trim(name)) > 0),
  width double precision not null default 1000.0 check (width > 0),
  height double precision not null default 800.0 check (height > 0),
  background_image_url text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists floor_plans_venue_id_idx on public.floor_plans (venue_id);
create index if not exists floor_plans_venue_active_idx on public.floor_plans (venue_id, is_active);

create or replace function app_hidden.floor_plans_derive_org()
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

drop trigger if exists trg_floor_plans_derive_org on public.floor_plans;
create trigger trg_floor_plans_derive_org
  before insert or update on public.floor_plans
  for each row
  execute function app_hidden.floor_plans_derive_org();

alter table public.floor_plans enable row level security;
alter table public.floor_plans force row level security;

-- -----------------------------------------------------------------------------
-- 2. Floor Tables
-- -----------------------------------------------------------------------------
create table if not exists public.floor_tables (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  venue_id uuid not null references public.venues(id) on delete cascade,
  floor_plan_id uuid not null references public.floor_plans(id) on delete cascade,
  label text not null check (char_length(trim(label)) > 0),
  shape text not null default 'rect' check (shape in ('round', 'square', 'rect', 'booth')),
  capacity integer not null default 4 check (capacity > 0),
  x double precision not null default 0.0,
  y double precision not null default 0.0,
  width double precision not null default 80.0 check (width > 0),
  height double precision not null default 80.0 check (height > 0),
  rotation double precision not null default 0.0,
  section text not null default 'main',
  min_spend_cents integer not null default 0 check (min_spend_cents >= 0),
  is_reservable boolean not null default true,
  status text not null default 'available' check (
    status in ('available', 'seated', 'dirty', 'reserved', 'held', 'out_of_service')
  ),
  party_size integer,
  seated_at timestamptz,
  last_activity_at timestamptz not null default now(),
  merge_group_id uuid,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists floor_tables_venue_id_idx on public.floor_tables (venue_id);
create index if not exists floor_tables_floor_plan_id_idx on public.floor_tables (floor_plan_id);
create index if not exists floor_tables_merge_group_idx on public.floor_tables (venue_id, merge_group_id);

create or replace function app_hidden.floor_tables_derive_org()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_plan_venue_id uuid;
  v_plan_org_id uuid;
begin
  select venue_id, organization_id into v_plan_venue_id, v_plan_org_id
  from public.floor_plans where id = new.floor_plan_id;

  if v_plan_venue_id is null then
    raise exception 'invalid_floor_plan_id: floor plan does not exist' using errcode = '23503';
  end if;

  if tg_op = 'INSERT' then
    new.venue_id := v_plan_venue_id;
    new.organization_id := v_plan_org_id;
    new.created_at := now();
    new.updated_at := now();
    new.last_activity_at := now();
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

drop trigger if exists trg_floor_tables_derive_org on public.floor_tables;
create trigger trg_floor_tables_derive_org
  before insert or update on public.floor_tables
  for each row
  execute function app_hidden.floor_tables_derive_org();

alter table public.floor_tables enable row level security;
alter table public.floor_tables force row level security;

-- -----------------------------------------------------------------------------
-- 3. Floor Table Assignments
-- -----------------------------------------------------------------------------
create table if not exists public.floor_table_assignments (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  venue_id uuid not null references public.venues(id) on delete cascade,
  table_id uuid not null references public.floor_tables(id) on delete cascade,
  reservation_id uuid references public.reservations(id) on delete set null,
  hold_type text not null default 'reserved' check (hold_type in ('reserved', 'held', 'seated')),
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  released_at timestamptz,
  released_reason text,
  created_at timestamptz not null default now(),
  constraint floor_table_assignments_time_check check (ends_at > starts_at)
);

create index if not exists floor_table_assignments_venue_idx on public.floor_table_assignments (venue_id);
create index if not exists floor_table_assignments_table_idx on public.floor_table_assignments (table_id);
create index if not exists floor_table_assignments_res_idx on public.floor_table_assignments (reservation_id);

create or replace function app_hidden.floor_table_assignments_derive()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_table_venue_id uuid;
  v_table_org_id uuid;
begin
  select venue_id, organization_id into v_table_venue_id, v_table_org_id
  from public.floor_tables where id = new.table_id;

  if v_table_venue_id is null then
    raise exception 'invalid_table_id: floor table does not exist' using errcode = '23503';
  end if;

  new.venue_id := v_table_venue_id;
  new.organization_id := v_table_org_id;
  new.created_at := now();
  return new;
end;
$$;

drop trigger if exists trg_floor_table_assignments_derive on public.floor_table_assignments;
create trigger trg_floor_table_assignments_derive
  before insert on public.floor_table_assignments
  for each row
  execute function app_hidden.floor_table_assignments_derive();

alter table public.floor_table_assignments enable row level security;
alter table public.floor_table_assignments force row level security;

-- -----------------------------------------------------------------------------
-- 4. Stored Procedures with Advisory-Locking and Transaction Guarantees
-- -----------------------------------------------------------------------------

-- Merge tables for a large party
create or replace function public.merge_floor_tables(
  p_venue_id uuid,
  p_table_ids uuid[],
  p_party_size integer default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_merge_group_id uuid;
  v_table_id uuid;
  v_table_count int;
begin
  -- Role authorization check
  if not app_hidden.has_venue_role(
    p_venue_id,
    array['staff', 'supervisor', 'venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
  ) then
    raise exception 'forbidden: insufficient venue permissions' using errcode = '42501';
  end if;

  if array_length(p_table_ids, 1) is null or array_length(p_table_ids, 1) < 2 then
    raise exception 'invalid_tables: select at least two tables to merge' using errcode = '22023';
  end if;

  -- Acquire advisory transaction locks on all tables sorted by UUID to prevent deadlocks
  for v_table_id in
    select unnest(p_table_ids) order by 1
  loop
    perform pg_advisory_xact_lock(hashtext('floor-table:' || p_venue_id::text || ':' || v_table_id::text));
  end loop;

  -- Verify all tables belong to this venue
  select count(*) into v_table_count
  from public.floor_tables
  where venue_id = p_venue_id and id = any(p_table_ids);

  if v_table_count <> array_length(p_table_ids, 1) then
    raise exception 'invalid_table_selection: one or more tables do not belong to this venue' using errcode = '42501';
  end if;

  v_merge_group_id := gen_random_uuid();

  update public.floor_tables
  set
    merge_group_id = v_merge_group_id,
    party_size = coalesce(p_party_size, party_size),
    last_activity_at = now(),
    updated_at = now()
  where venue_id = p_venue_id and id = any(p_table_ids);

  return v_merge_group_id;
end;
$$;

-- Split merged tables
create or replace function public.split_floor_tables(
  p_venue_id uuid,
  p_merge_group_id uuid
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_table_id uuid;
begin
  if not app_hidden.has_venue_role(
    p_venue_id,
    array['staff', 'supervisor', 'venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
  ) then
    raise exception 'forbidden: insufficient venue permissions' using errcode = '42501';
  end if;

  for v_table_id in
    select id from public.floor_tables where venue_id = p_venue_id and merge_group_id = p_merge_group_id order by id
  loop
    perform pg_advisory_xact_lock(hashtext('floor-table:' || p_venue_id::text || ':' || v_table_id::text));
  end loop;

  update public.floor_tables
  set
    merge_group_id = null,
    last_activity_at = now(),
    updated_at = now()
  where venue_id = p_venue_id and merge_group_id = p_merge_group_id;
end;
$$;

-- Assign tables to a reservation
create or replace function public.assign_tables_to_reservation(
  p_venue_id uuid,
  p_table_ids uuid[],
  p_reservation_id uuid,
  p_hold_type text default 'reserved',
  p_starts_at timestamptz default now(),
  p_ends_at timestamptz default now() + interval '90 minutes'
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_table_id uuid;
  v_new_status text;
begin
  if not app_hidden.has_venue_role(
    p_venue_id,
    array['staff', 'supervisor', 'venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
  ) then
    raise exception 'forbidden: insufficient venue permissions' using errcode = '42501';
  end if;

  for v_table_id in
    select unnest(p_table_ids) order by 1
  loop
    perform pg_advisory_xact_lock(hashtext('floor-table:' || p_venue_id::text || ':' || v_table_id::text));
  end loop;

  v_new_status := case when p_hold_type = 'seated' then 'seated' else 'reserved' end;

  for v_table_id in
    select unnest(p_table_ids)
  loop
    insert into public.floor_table_assignments (
      table_id, reservation_id, hold_type, starts_at, ends_at
    ) values (
      v_table_id, p_reservation_id, p_hold_type, p_starts_at, p_ends_at
    );
  end loop;

  update public.floor_tables
  set
    status = v_new_status,
    seated_at = case when p_hold_type = 'seated' then p_starts_at else seated_at end,
    last_activity_at = now(),
    updated_at = now()
  where venue_id = p_venue_id and id = any(p_table_ids);
end;
$$;

-- Update single table status
create or replace function public.update_floor_table_status(
  p_venue_id uuid,
  p_table_id uuid,
  p_status text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not app_hidden.has_venue_role(
    p_venue_id,
    array['staff', 'supervisor', 'venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
  ) then
    raise exception 'forbidden: insufficient venue permissions' using errcode = '42501';
  end if;

  if p_status not in ('available', 'seated', 'dirty', 'reserved', 'held', 'out_of_service') then
    raise exception 'invalid_table_status' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(hashtext('floor-table:' || p_venue_id::text || ':' || p_table_id::text));

  update public.floor_tables
  set
    status = p_status,
    seated_at = case when p_status = 'seated' then coalesce(seated_at, now()) else null end,
    last_activity_at = now(),
    updated_at = now()
  where venue_id = p_venue_id and id = p_table_id;
end;
$$;

-- -----------------------------------------------------------------------------
-- 5. Row Level Security Policies
-- -----------------------------------------------------------------------------

-- FLOOR PLANS RLS
create policy floor_plans_select_venue_members on public.floor_plans
  for select to authenticated
  using (
    app_hidden.has_venue_role(
      venue_id,
      array['staff', 'supervisor', 'venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
    )
  );

create policy floor_plans_write_managers on public.floor_plans
  for all to authenticated
  using (
    app_hidden.has_venue_role(
      venue_id,
      array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
    )
  )
  with check (
    app_hidden.has_venue_role(
      venue_id,
      array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
    )
  );

-- FLOOR TABLES RLS
create policy floor_tables_select_venue_members on public.floor_tables
  for select to authenticated
  using (
    app_hidden.has_venue_role(
      venue_id,
      array['staff', 'supervisor', 'venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
    )
  );

create policy floor_tables_write_members on public.floor_tables
  for all to authenticated
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

-- FLOOR TABLE ASSIGNMENTS RLS
create policy floor_table_assignments_select on public.floor_table_assignments
  for select to authenticated
  using (
    app_hidden.has_venue_role(
      venue_id,
      array['staff', 'supervisor', 'venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
    )
  );

create policy floor_table_assignments_write on public.floor_table_assignments
  for all to authenticated
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

-- -----------------------------------------------------------------------------
-- 6. Grants & Realtime Publications
-- -----------------------------------------------------------------------------
grant select, insert, update, delete on public.floor_plans to authenticated;
grant select, insert, update, delete on public.floor_tables to authenticated;
grant select, insert, update, delete on public.floor_table_assignments to authenticated;

grant execute on function public.merge_floor_tables to authenticated;
grant execute on function public.split_floor_tables to authenticated;
grant execute on function public.assign_tables_to_reservation to authenticated;
grant execute on function public.update_floor_table_status to authenticated;

-- supabase_realtime is a platform-managed publication that exists on every real Supabase
-- project but not on a vanilla local Postgres instance (e.g. the CI stub sequence in
-- supabase/tests/ci_*_stub.sql). Guard it so local verification doesn't break here.
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table public.floor_tables;
    alter publication supabase_realtime add table public.floor_table_assignments;
  end if;
end;
$$;

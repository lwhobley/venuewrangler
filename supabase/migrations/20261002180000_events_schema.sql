-- Phase 3 feature: events (a venue's calendar of planned events — not the CRM/BEO/contract
-- "event command center" from the reference app, which is a separate, larger feature not in
-- this rebuild pass). Same derive/manager-write/member-read shape as inventory_items/shifts.
create table public.events (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  venue_id uuid not null references public.venues (id) on delete cascade,
  name text not null check (char_length(trim(name)) > 0),
  start_time timestamptz not null,
  end_time timestamptz not null check (end_time > start_time),
  status text not null default 'planned' check (status in ('planned', 'confirmed', 'completed', 'cancelled')),
  notes text,
  created_by uuid references auth.users (id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index events_venue_id_idx on public.events (venue_id);
create index events_organization_id_idx on public.events (organization_id);
create index events_start_time_idx on public.events (start_time);

create or replace function app_hidden.prepare_event_insert()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org_id uuid;
begin
  select organization_id into v_org_id from public.venues where id = new.venue_id;
  if v_org_id is null then
    raise exception 'venue % does not exist', new.venue_id;
  end if;
  new.organization_id := v_org_id;
  new.created_by := auth.uid();
  return new;
end;
$$;

create trigger prepare_event_insert
  before insert on public.events
  for each row execute function app_hidden.prepare_event_insert();

create or replace function app_hidden.sync_event_update()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org_id uuid;
begin
  select organization_id into v_org_id from public.venues where id = new.venue_id;
  if v_org_id is null then
    raise exception 'venue % does not exist', new.venue_id;
  end if;
  new.organization_id := v_org_id;
  new.updated_at := now();
  return new;
end;
$$;

create trigger sync_event_update
  before update on public.events
  for each row execute function app_hidden.sync_event_update();

alter table public.events enable row level security;
alter table public.events force row level security;

create policy events_select_venue_members on public.events
  for select to authenticated
  using (app_hidden.is_venue_member(venue_id));

create policy events_insert_managers on public.events
  for insert to authenticated
  with check (
    app_hidden.has_venue_role(
      venue_id,
      array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
    )
  );

create policy events_update_managers on public.events
  for update to authenticated
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

create policy events_delete_managers on public.events
  for delete to authenticated
  using (
    app_hidden.has_venue_role(
      venue_id,
      array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
    )
  );

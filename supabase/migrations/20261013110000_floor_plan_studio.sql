-- Floor Plan Studio: measured room dimensions and a generated round-table layout per
-- floor plan. Feeds the 3D room preview on the CRM banquet order screen. Config-like data:
-- managers write, venue members read. No state machine.

create table if not exists public.floor_plan_studio_layouts (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  venue_id uuid not null references public.venues(id) on delete cascade,
  floor_plan_id uuid not null unique references public.floor_plans(id) on delete cascade,
  width_feet double precision not null check (width_feet > 0),
  depth_feet double precision not null check (depth_feet > 0),
  verified boolean not null default false,
  table_diameter_feet double precision not null default 6 check (table_diameter_feet > 0),
  seats_per_table integer not null default 10 check (seats_per_table > 0),
  layout jsonb not null default '[]'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists floor_plan_studio_layouts_venue_id_idx
  on public.floor_plan_studio_layouts (venue_id);

create or replace function app_hidden.floor_plan_studio_layouts_derive()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_org_id uuid;
  v_plan_venue_id uuid;
begin
  if tg_op = 'INSERT' then
    select organization_id into v_org_id from public.venues where id = new.venue_id;
    if v_org_id is null then
      raise exception 'invalid_venue_id: venue does not exist' using errcode = '23503';
    end if;
    select venue_id into v_plan_venue_id from public.floor_plans where id = new.floor_plan_id;
    if v_plan_venue_id is null or v_plan_venue_id <> new.venue_id then
      raise exception 'floor_plan_id does not belong to venue_id' using errcode = '23503';
    end if;
    new.organization_id := v_org_id;
    new.created_at := now();
    new.updated_at := now();
    return new;
  elsif tg_op = 'UPDATE' then
    if new.venue_id <> old.venue_id or new.organization_id <> old.organization_id
       or new.floor_plan_id <> old.floor_plan_id then
      raise exception 'venue, organization and floor plan cannot be changed once set' using errcode = '42501';
    end if;
    new.updated_at := now();
    return new;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_floor_plan_studio_layouts_derive on public.floor_plan_studio_layouts;
create trigger trg_floor_plan_studio_layouts_derive
  before insert or update on public.floor_plan_studio_layouts
  for each row
  execute function app_hidden.floor_plan_studio_layouts_derive();

alter table public.floor_plan_studio_layouts enable row level security;
alter table public.floor_plan_studio_layouts force row level security;

create policy floor_plan_studio_layouts_select_venue_members on public.floor_plan_studio_layouts
  for select to authenticated
  using (
    app_hidden.has_venue_role(
      venue_id,
      array['staff', 'supervisor', 'venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
    )
  );

create policy floor_plan_studio_layouts_write_managers on public.floor_plan_studio_layouts
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

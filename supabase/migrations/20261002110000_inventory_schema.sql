-- Phase 3 feature: bar/kitchen inventory. Same "derive, don't trust" shape as
-- operational_tasks: organization_id is derived from venue_id, never client-supplied, and
-- every venue member may read while only a manager tier may write (a plain, uniform policy
-- set — unlike tasks, there is no assignee-style split here, so no column-level trigger is
-- needed).
create table public.inventory_items (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  venue_id uuid not null references public.venues (id) on delete cascade,
  name text not null check (char_length(trim(name)) > 0),
  quantity numeric(12, 2),
  unit text,
  unit_cost_usd numeric(10, 2),
  updated_by uuid references auth.users (id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index inventory_items_venue_id_idx on public.inventory_items (venue_id);
create index inventory_items_organization_id_idx on public.inventory_items (organization_id);

create or replace function app_hidden.prepare_inventory_item_insert()
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
  new.updated_by := auth.uid();
  return new;
end;
$$;

create trigger prepare_inventory_item_insert
  before insert on public.inventory_items
  for each row execute function app_hidden.prepare_inventory_item_insert();

create or replace function app_hidden.sync_inventory_item_update()
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
  new.updated_by := auth.uid();
  new.updated_at := now();
  return new;
end;
$$;

create trigger sync_inventory_item_update
  before update on public.inventory_items
  for each row execute function app_hidden.sync_inventory_item_update();

alter table public.inventory_items enable row level security;
alter table public.inventory_items force row level security;

create policy inventory_items_select_venue_members on public.inventory_items
  for select to authenticated
  using (app_hidden.is_venue_member(venue_id));

create policy inventory_items_insert_managers on public.inventory_items
  for insert to authenticated
  with check (
    app_hidden.has_venue_role(
      venue_id,
      array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
    )
  );

create policy inventory_items_update_managers on public.inventory_items
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

create policy inventory_items_delete_managers on public.inventory_items
  for delete to authenticated
  using (
    app_hidden.has_venue_role(
      venue_id,
      array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
    )
  );

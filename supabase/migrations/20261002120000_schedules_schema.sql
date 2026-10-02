-- Phase 3 feature: shift scheduling. Same "derive, don't trust" + manager-write/member-read
-- shape as inventory_items; `staff_id` is optional (an unassigned/open shift), same as
-- operational_tasks.assigned_to, and is not itself constrained to a venue member here — same
-- scope as operational_tasks today, left for a future pass alongside a real swap-request flow.
create table public.shifts (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  venue_id uuid not null references public.venues (id) on delete cascade,
  staff_id uuid references auth.users (id),
  role_label text,
  start_time timestamptz not null,
  end_time timestamptz not null check (end_time > start_time),
  status text not null default 'scheduled' check (status in ('scheduled', 'completed', 'cancelled')),
  created_by uuid references auth.users (id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index shifts_venue_id_idx on public.shifts (venue_id);
create index shifts_organization_id_idx on public.shifts (organization_id);
create index shifts_staff_id_idx on public.shifts (staff_id);
create index shifts_start_time_idx on public.shifts (start_time);

create or replace function app_hidden.prepare_shift_insert()
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

create trigger prepare_shift_insert
  before insert on public.shifts
  for each row execute function app_hidden.prepare_shift_insert();

create or replace function app_hidden.sync_shift_update()
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

create trigger sync_shift_update
  before update on public.shifts
  for each row execute function app_hidden.sync_shift_update();

alter table public.shifts enable row level security;
alter table public.shifts force row level security;

create policy shifts_select_venue_members on public.shifts
  for select to authenticated
  using (app_hidden.is_venue_member(venue_id));

create policy shifts_insert_managers on public.shifts
  for insert to authenticated
  with check (
    app_hidden.has_venue_role(
      venue_id,
      array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
    )
  );

create policy shifts_update_managers on public.shifts
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

create policy shifts_delete_managers on public.shifts
  for delete to authenticated
  using (
    app_hidden.has_venue_role(
      venue_id,
      array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
    )
  );

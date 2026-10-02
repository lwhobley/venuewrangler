-- Phase 2 feature: operational tasks. First of the four offline-writable workflows named in
-- the migration plan (tasks, checklist responses, incident drafts, media-upload retry) — its
-- schema/RLS establishes patterns (organization_id auto-derived from venue_id, a
-- manager-vs-assignee update split enforced by trigger, not just RLS) that checklists and
-- incidents will reuse.

create table public.operational_tasks (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  venue_id uuid not null references public.venues (id) on delete cascade,
  title text not null check (char_length(trim(title)) > 0),
  description text,
  status text not null default 'open' check (status in ('open', 'in_progress', 'completed', 'cancelled')),
  assigned_to uuid references auth.users (id),
  due_at timestamptz,
  completed_at timestamptz,
  created_by uuid references auth.users (id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index operational_tasks_venue_id_idx on public.operational_tasks (venue_id);
create index operational_tasks_assigned_to_idx on public.operational_tasks (assigned_to);
create index operational_tasks_organization_id_idx on public.operational_tasks (organization_id);

-- organization_id is derived from venue_id, never trusted from the client: a client could
-- otherwise claim a task belongs to a different organization than its venue actually does,
-- which would desync every org-scoped query/report. created_by is likewise always the
-- calling user, never client-supplied, so a task can't be forged as having been created by
-- someone else.
create or replace function app_hidden.prepare_task_insert()
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

create trigger prepare_task_insert
  before insert on public.operational_tasks
  for each row execute function app_hidden.prepare_task_insert();

create or replace function app_hidden.sync_task_organization_id()
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
  return new;
end;
$$;

create trigger sync_task_organization_id
  before update of venue_id on public.operational_tasks
  for each row execute function app_hidden.sync_task_organization_id();

create or replace function app_hidden.sync_task_timestamps()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  new.updated_at := now();
  if new.status = 'completed' and old.status is distinct from 'completed' then
    new.completed_at := now();
  elsif new.status <> 'completed' then
    new.completed_at := null;
  end if;
  return new;
end;
$$;

create trigger sync_task_timestamps
  before update on public.operational_tasks
  for each row execute function app_hidden.sync_task_timestamps();

-- RLS only decides WHICH ROW a client may touch (any venue member may read; a manager or the
-- assignee may update). It cannot express "the assignee may change this column but not that
-- one" — Postgres row-level security has no column granularity — so this trigger enforces
-- the column-level split: a manager may change anything, but a non-manager may only move
-- `status` (and the `completed_at` that follows from it via sync_task_timestamps above).
create or replace function app_hidden.enforce_task_update_scope()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if app_hidden.has_venue_role(
    new.venue_id,
    array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
  ) then
    return new;
  end if;

  if old.assigned_to is distinct from auth.uid() then
    raise exception 'not authorized to update this task' using errcode = '42501';
  end if;

  if new.title is distinct from old.title
    or new.description is distinct from old.description
    or new.venue_id is distinct from old.venue_id
    or new.organization_id is distinct from old.organization_id
    or new.assigned_to is distinct from old.assigned_to
    or new.due_at is distinct from old.due_at
    or new.created_by is distinct from old.created_by
    or new.created_at is distinct from old.created_at
  then
    raise exception 'the assignee may only change a task''s status' using errcode = '42501';
  end if;

  return new;
end;
$$;

create trigger enforce_task_update_scope
  before update on public.operational_tasks
  for each row execute function app_hidden.enforce_task_update_scope();

alter table public.operational_tasks enable row level security;
alter table public.operational_tasks force row level security;

create policy operational_tasks_select_venue_members on public.operational_tasks
  for select to authenticated
  using (app_hidden.is_venue_member(venue_id));

create policy operational_tasks_insert_managers on public.operational_tasks
  for insert to authenticated
  with check (
    app_hidden.has_venue_role(
      venue_id,
      array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
    )
  );

-- The coarse row-level gate: a manager may touch any task in their scope, and the current
-- assignee may touch their own task. enforce_task_update_scope (above) then narrows what the
-- assignee specifically may change within that row.
create policy operational_tasks_update_managers_or_assignee on public.operational_tasks
  for update to authenticated
  using (
    app_hidden.has_venue_role(
      venue_id,
      array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
    )
    or assigned_to = auth.uid()
  )
  with check (
    app_hidden.has_venue_role(
      venue_id,
      array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
    )
    or assigned_to = auth.uid()
  );

create policy operational_tasks_delete_managers on public.operational_tasks
  for delete to authenticated
  using (
    app_hidden.has_venue_role(
      venue_id,
      array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
    )
  );

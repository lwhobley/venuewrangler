-- Phase 2 feature: checklists. Second of the four offline-writable workflows. Unlike
-- operational_tasks (an UPDATE to an existing row, which needs optimistic-concurrency
-- conflict detection), completing a checklist is an INSERT of a new row — there is no
-- existing row to conflict with, so the offline queue handler for this feature is simpler
-- (plain retry-until-success), which is deliberately exercised as a second shape for the
-- same queue abstraction (see apps/mobile/lib/core/offline).

create table public.checklist_templates (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  venue_id uuid not null references public.venues (id) on delete cascade,
  title text not null check (char_length(trim(title)) > 0),
  created_by uuid references auth.users (id),
  created_at timestamptz not null default now()
);

create index checklist_templates_venue_id_idx on public.checklist_templates (venue_id);

-- organization_id is derived from venue_id, never trusted from the client, same reasoning as
-- operational_tasks' prepare_task_insert.
create or replace function app_hidden.prepare_checklist_template_insert()
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

create trigger prepare_checklist_template_insert
  before insert on public.checklist_templates
  for each row execute function app_hidden.prepare_checklist_template_insert();

create table public.checklist_template_items (
  id uuid primary key default gen_random_uuid(),
  template_id uuid not null references public.checklist_templates (id) on delete cascade,
  -- Denormalized from the parent template (see the trigger below) so RLS can scope directly
  -- by venue_id, the same pattern as operational_tasks, rather than joining to the parent
  -- table inside every policy.
  venue_id uuid not null,
  label text not null check (char_length(trim(label)) > 0),
  position integer not null default 0,
  created_at timestamptz not null default now()
);

create index checklist_template_items_template_id_idx on public.checklist_template_items (template_id);
create index checklist_template_items_venue_id_idx on public.checklist_template_items (venue_id);

create or replace function app_hidden.sync_checklist_item_venue_id()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_venue_id uuid;
begin
  select venue_id into v_venue_id from public.checklist_templates where id = new.template_id;
  if v_venue_id is null then
    raise exception 'checklist template % does not exist', new.template_id;
  end if;
  new.venue_id := v_venue_id;
  return new;
end;
$$;

create trigger sync_checklist_item_venue_id
  before insert or update of template_id on public.checklist_template_items
  for each row execute function app_hidden.sync_checklist_item_venue_id();

-- One row per completion *run* of a template by a venue member. item_results holds the
-- per-item checked state as submitted; this is intentionally a jsonb blob rather than a
-- normalized child table for this first slice — see features/checklists/README.md in the
-- Flutter app for why, and what would motivate normalizing it later (e.g. per-item evidence
-- photos, which need their own row to carry a Storage object reference).
create table public.checklist_completions (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  venue_id uuid not null references public.venues (id) on delete cascade,
  template_id uuid not null references public.checklist_templates (id) on delete cascade,
  completed_by uuid references auth.users (id),
  item_results jsonb not null default '[]'::jsonb,
  notes text,
  created_at timestamptz not null default now()
);

create index checklist_completions_venue_id_idx on public.checklist_completions (venue_id);
create index checklist_completions_template_id_idx on public.checklist_completions (template_id);

create or replace function app_hidden.prepare_checklist_completion_insert()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org_id uuid;
  v_venue_id uuid;
begin
  select organization_id, venue_id into v_org_id, v_venue_id
  from public.checklist_templates
  where id = new.template_id;

  if v_org_id is null then
    raise exception 'checklist template % does not exist', new.template_id;
  end if;

  new.organization_id := v_org_id;
  new.venue_id := v_venue_id;
  new.completed_by := auth.uid();
  return new;
end;
$$;

create trigger prepare_checklist_completion_insert
  before insert on public.checklist_completions
  for each row execute function app_hidden.prepare_checklist_completion_insert();

alter table public.checklist_templates enable row level security;
alter table public.checklist_templates force row level security;
alter table public.checklist_template_items enable row level security;
alter table public.checklist_template_items force row level security;
alter table public.checklist_completions enable row level security;
alter table public.checklist_completions force row level security;

create policy checklist_templates_select_venue_members on public.checklist_templates
  for select to authenticated
  using (app_hidden.is_venue_member(venue_id));

create policy checklist_templates_insert_managers on public.checklist_templates
  for insert to authenticated
  with check (
    app_hidden.has_venue_role(
      venue_id,
      array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
    )
  );

create policy checklist_templates_update_managers on public.checklist_templates
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

create policy checklist_templates_delete_managers on public.checklist_templates
  for delete to authenticated
  using (
    app_hidden.has_venue_role(
      venue_id,
      array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
    )
  );

-- Items inherit the same read/write scope as their parent template.
create policy checklist_template_items_select_venue_members on public.checklist_template_items
  for select to authenticated
  using (app_hidden.is_venue_member(venue_id));

create policy checklist_template_items_insert_managers on public.checklist_template_items
  for insert to authenticated
  with check (
    exists (
      select 1 from public.checklist_templates t
      where t.id = template_id
        and app_hidden.has_venue_role(
          t.venue_id,
          array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
        )
    )
  );

create policy checklist_template_items_update_managers on public.checklist_template_items
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

create policy checklist_template_items_delete_managers on public.checklist_template_items
  for delete to authenticated
  using (
    app_hidden.has_venue_role(
      venue_id,
      array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
    )
  );

-- Completions: any venue member may record one (the whole point of a checklist is that
-- staff, not just managers, complete it) and read the venue's completion history. Only
-- managers may amend or remove a submitted completion (e.g. to correct a mistake) — the
-- person who completed it cannot quietly edit their own record afterward, unlike
-- operational_tasks' assignee-may-update-status pattern, because a checklist completion is
-- meant to be an immutable record of what was actually checked at the time.
create policy checklist_completions_select_venue_members on public.checklist_completions
  for select to authenticated
  using (app_hidden.is_venue_member(venue_id));

create policy checklist_completions_insert_venue_members on public.checklist_completions
  for insert to authenticated
  with check (app_hidden.is_venue_member(venue_id));

create policy checklist_completions_update_managers on public.checklist_completions
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

create policy checklist_completions_delete_managers on public.checklist_completions
  for delete to authenticated
  using (
    app_hidden.has_venue_role(
      venue_id,
      array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
    )
  );

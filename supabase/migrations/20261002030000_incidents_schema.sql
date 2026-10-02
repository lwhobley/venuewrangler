-- Phase 2 feature: incidents. Third of the four offline-writable workflows (incident
-- drafts). Combines both shapes already exercised: an INSERT any venue member may make
-- (like checklist completions) and an UPDATE with a manager-vs-reporter column split (like
-- operational_tasks), plus a new piece — an append-only audit trail of status changes,
-- written into the existing public.audit_log table via trigger rather than a new table.

create table public.incidents (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  venue_id uuid not null references public.venues (id) on delete cascade,
  title text not null check (char_length(trim(title)) > 0),
  description text,
  severity text not null default 'low' check (severity in ('low', 'medium', 'high', 'critical')),
  status text not null default 'open' check (status in ('open', 'investigating', 'resolved', 'closed')),
  reported_by uuid references auth.users (id),
  resolved_by uuid references auth.users (id),
  resolved_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index incidents_venue_id_idx on public.incidents (venue_id);
create index incidents_organization_id_idx on public.incidents (organization_id);
create index incidents_status_idx on public.incidents (status);

-- organization_id derived from venue_id and reported_by always the calling user, never
-- client-supplied — same reasoning as operational_tasks' prepare_task_insert.
create or replace function app_hidden.prepare_incident_insert()
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
  new.reported_by := auth.uid();
  return new;
end;
$$;

create trigger prepare_incident_insert
  before insert on public.incidents
  for each row execute function app_hidden.prepare_incident_insert();

create or replace function app_hidden.sync_incident_resolution()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  new.updated_at := now();
  if new.status in ('resolved', 'closed') and old.status not in ('resolved', 'closed') then
    new.resolved_at := now();
    new.resolved_by := auth.uid();
  elsif new.status not in ('resolved', 'closed') then
    new.resolved_at := null;
    new.resolved_by := null;
  end if;
  return new;
end;
$$;

create trigger sync_incident_resolution
  before update on public.incidents
  for each row execute function app_hidden.sync_incident_resolution();

-- RLS gates WHICH incident a client may update (a manager, or the reporter while it's still
-- open); this trigger narrows WHAT the reporter specifically may change within that row,
-- same column-granularity gap as operational_tasks' enforce_task_update_scope. The
-- reporter's edit window is also enforced at the RLS layer (see
-- incidents_update_managers_or_reporter_while_open below) via `status = 'open'` in USING, so
-- this trigger does not need to re-check status itself.
create or replace function app_hidden.enforce_incident_update_scope()
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

  if old.reported_by is distinct from auth.uid() then
    raise exception 'not authorized to update this incident' using errcode = '42501';
  end if;

  if new.status is distinct from old.status
    or new.severity is distinct from old.severity
    or new.venue_id is distinct from old.venue_id
    or new.organization_id is distinct from old.organization_id
    or new.reported_by is distinct from old.reported_by
    or new.resolved_by is distinct from old.resolved_by
    or new.resolved_at is distinct from old.resolved_at
    or new.created_at is distinct from old.created_at
  then
    raise exception
      'the reporter may only edit title/description, and only while the incident is open'
      using errcode = '42501';
  end if;

  return new;
end;
$$;

create trigger enforce_incident_update_scope
  before update on public.incidents
  for each row execute function app_hidden.enforce_incident_update_scope();

-- Append-only audit trail of status changes, written into the existing audit_log table
-- (foundation schema) rather than a new incident-specific table. Runs as the schema owner
-- (SECURITY DEFINER), so it can insert into audit_log even though no INSERT policy on
-- audit_log exists for `authenticated` — exactly the "service-mediated write" pattern the
-- foundation migration's comments describe, just triggered from SQL instead of an Edge
-- Function.
create or replace function app_hidden.log_incident_status_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.status is distinct from old.status then
    insert into public.audit_log (organization_id, venue_id, actor_user_id, action, target_table, target_id, metadata)
    values (
      new.organization_id,
      new.venue_id,
      auth.uid(),
      'incident.status_changed',
      'incidents',
      new.id,
      jsonb_build_object('from', old.status, 'to', new.status)
    );
  end if;
  return new;
end;
$$;

create trigger log_incident_status_change
  after update on public.incidents
  for each row execute function app_hidden.log_incident_status_change();

alter table public.incidents enable row level security;
alter table public.incidents force row level security;

create policy incidents_select_venue_members on public.incidents
  for select to authenticated
  using (app_hidden.is_venue_member(venue_id));

create policy incidents_insert_venue_members on public.incidents
  for insert to authenticated
  with check (app_hidden.is_venue_member(venue_id));

create policy incidents_update_managers_or_reporter_while_open on public.incidents
  for update to authenticated
  using (
    app_hidden.has_venue_role(
      venue_id,
      array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
    )
    or (reported_by = auth.uid() and status = 'open')
  )
  with check (
    app_hidden.has_venue_role(
      venue_id,
      array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
    )
    or reported_by = auth.uid()
  );

create policy incidents_delete_managers on public.incidents
  for delete to authenticated
  using (
    app_hidden.has_venue_role(
      venue_id,
      array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
    )
  );

-- BrightHR Customer API integration (https://docs.bright.hr). Read-only import of the BrightHR
-- employee list, approved absences, and Blip clock-ins, plus a write-back of the app's member id
-- as each linked BrightHR employee's `externalReference`.
--
-- BrightHR offers only the OAuth2 client-credentials grant: a BrightHR admin creates a Client ID
-- and Secret at account.brighthr.com/manage-api and a venue manager pastes them into the app.
-- There is no consent redirect, so none of the oauth_pending_connections machinery applies.
--
-- Same "derive, don't trust" shape as payroll_connections:
--  * every write goes through the `brighthr` Edge Function (service role) or the SECURITY DEFINER
--    RPCs below; `authenticated` has no insert/update/delete grant on any table here;
--  * a venue's manager tier can read the non-secret columns; the encrypted client secret is
--    excluded by a column-level grant, so not even a manager can select it.
--
-- Privacy: BrightHR returns a sickness `reason`, free-text `note`s and an `isCertified` flag for
-- absences. Those are health/HR data that scheduling does not need, so they are never stored.
-- Absences and clockings are fetched only for employees a manager has linked to a team member.

create table public.brighthr_connections (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  venue_id uuid not null unique references public.venues (id) on delete cascade,
  status text not null default 'connected' check (status in ('connected', 'error')),
  client_id text not null check (length(trim(client_id)) between 1 and 200),
  -- AES-256-GCM, bound to `${venue_id}:brighthr` (see supabase/functions/_shared/crypto.ts).
  encrypted_client_secret text not null,
  last_sync_at timestamptz,
  last_sync_status text check (last_sync_status in ('succeeded', 'partial', 'failed')),
  last_error text check (char_length(last_error) <= 500),
  next_sync_at timestamptz not null default now(),
  sync_lease_until timestamptz,
  connected_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index brighthr_connections_organization_id_idx on public.brighthr_connections (organization_id);
create index brighthr_connections_due_idx on public.brighthr_connections (next_sync_at);

create or replace function app_hidden.prepare_brighthr_connection()
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
    raise exception 'venue % does not exist', new.venue_id;
  end if;
  new.organization_id := v_org_id;
  new.updated_at := now();
  return new;
end;
$$;

revoke all on function app_hidden.prepare_brighthr_connection() from public, anon, authenticated;

create trigger prepare_brighthr_connection
  before insert or update on public.brighthr_connections
  for each row execute function app_hidden.prepare_brighthr_connection();

-- The BrightHR employee directory as last seen. Names and email are what a manager needs to link
-- an employee to a team member; nothing else from the HR record is kept.
create table public.brighthr_employees (
  connection_id uuid not null references public.brighthr_connections (id) on delete cascade,
  external_employee_id text not null check (length(trim(external_employee_id)) between 1 and 100),
  given_name text check (char_length(given_name) <= 200),
  family_name text check (char_length(family_name) <= 200),
  email text check (char_length(email) <= 320),
  job_title text check (char_length(job_title) <= 200),
  employment_start date,
  employment_end date,
  external_reference text check (char_length(external_reference) <= 200),
  synced_at timestamptz not null default now(),
  primary key (connection_id, external_employee_id)
);

-- Manager-reviewed link between a BrightHR employee and a venue team member.
create table public.brighthr_employee_mappings (
  connection_id uuid not null references public.brighthr_connections (id) on delete cascade,
  external_employee_id text not null,
  staff_id uuid not null references auth.users (id) on delete cascade,
  linked_by uuid references auth.users (id) on delete set null,
  linked_at timestamptz not null default now(),
  -- When the Edge Function last wrote staff_id back as BrightHR's externalReference.
  external_reference_synced_at timestamptz,
  -- Last time this employee's absences/clockings were fetched. A sync works through the
  -- least-recently-synced employees first, so a large roster converges across several runs.
  data_synced_at timestamptz,
  primary key (connection_id, external_employee_id),
  unique (connection_id, staff_id),
  foreign key (connection_id, external_employee_id)
    references public.brighthr_employees (connection_id, external_employee_id) on delete cascade
);

create index brighthr_employee_mappings_staff_id_idx on public.brighthr_employee_mappings (staff_id);

create table public.brighthr_absences (
  connection_id uuid not null references public.brighthr_connections (id) on delete cascade,
  external_absence_id text not null check (length(trim(external_absence_id)) between 1 and 100),
  external_employee_id text not null,
  absence_type text not null check (absence_type in ('Sickness', 'Toil', 'Holiday', 'Other')),
  display_name text check (char_length(display_name) <= 200),
  -- Inclusive bounds, local to the employee (BrightHR's own convention).
  start_date date not null,
  start_part text not null default 'FullDay' check (start_part in ('FirstHalf', 'SecondHalf', 'FullDay')),
  end_date date not null,
  end_part text not null default 'FullDay' check (end_part in ('FirstHalf', 'SecondHalf', 'FullDay')),
  duration_days numeric check (duration_days >= 0),
  duration_minutes numeric check (duration_minutes >= 0),
  synced_at timestamptz not null default now(),
  primary key (connection_id, external_absence_id),
  check (end_date >= start_date)
);

create index brighthr_absences_employee_dates_idx
  on public.brighthr_absences (connection_id, external_employee_id, start_date, end_date);

create table public.brighthr_clockings (
  connection_id uuid not null references public.brighthr_connections (id) on delete cascade,
  external_clocking_id text not null check (length(trim(external_clocking_id)) between 1 and 100),
  external_employee_id text not null,
  clock_in_at timestamptz not null,
  clock_out_at timestamptz,
  start_time_zone text check (char_length(start_time_zone) <= 64),
  end_time_zone text check (char_length(end_time_zone) <= 64),
  break_periods jsonb not null default '[]'::jsonb check (jsonb_typeof(break_periods) = 'array'),
  synced_at timestamptz not null default now(),
  primary key (connection_id, external_clocking_id),
  check (clock_out_at is null or clock_out_at >= clock_in_at)
);

create index brighthr_clockings_employee_time_idx
  on public.brighthr_clockings (connection_id, external_employee_id, clock_in_at);

create table public.brighthr_sync_runs (
  id uuid primary key default gen_random_uuid(),
  connection_id uuid not null references public.brighthr_connections (id) on delete cascade,
  trigger text not null check (trigger in ('connect', 'manual', 'scheduled')),
  status text not null default 'running' check (status in ('running', 'succeeded', 'partial', 'failed')),
  employees_synced integer not null default 0,
  absences_synced integer not null default 0,
  clockings_synced integer not null default 0,
  error_code text check (char_length(error_code) <= 100),
  started_at timestamptz not null default now(),
  finished_at timestamptz
);

create index brighthr_sync_runs_connection_idx on public.brighthr_sync_runs (connection_id, started_at desc);

-- ---------------------------------------------------------------------------
-- RLS: manager-tier read only. No client write grant on any table.
-- ---------------------------------------------------------------------------

alter table public.brighthr_connections enable row level security;
alter table public.brighthr_connections force row level security;
revoke all on public.brighthr_connections from public, anon, authenticated;

create policy brighthr_connections_manager_read on public.brighthr_connections
  for select to authenticated
  using (
    app_hidden.has_venue_role(
      venue_id,
      array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
    )
  );

grant select (
  id, organization_id, venue_id, status, client_id, last_sync_at, last_sync_status, last_error,
  next_sync_at, connected_by, created_at, updated_at
) on public.brighthr_connections to authenticated;
grant select, insert, update, delete on public.brighthr_connections to service_role;

do $$ declare t text; begin
  foreach t in array array['brighthr_employees', 'brighthr_employee_mappings',
    'brighthr_absences', 'brighthr_clockings', 'brighthr_sync_runs'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('alter table public.%I force row level security', t);
    execute format('revoke all on public.%I from public, anon, authenticated', t);
    execute format('create policy %I on public.%I for select to authenticated using (exists
      (select 1 from public.brighthr_connections c where c.id = connection_id and
       app_hidden.has_venue_role(c.venue_id,
       array[''venue_manager'',''organization_owner'',''organization_admin'']::public.app_role[])))',
      t || '_manager_read', t);
    execute format('grant select on public.%I to authenticated', t);
    execute format('grant select, insert, update, delete on public.%I to service_role', t);
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- Linking a BrightHR employee to a team member (manager action).
-- ---------------------------------------------------------------------------

-- Links (or, with p_staff_id null, unlinks) one BrightHR employee. The staff member must belong to
-- the connection's venue, or be an owner/admin of its organization (the same people venue_roster
-- lists). Called by the `brighthr` Edge Function with the caller's own JWT, so auth.uid() is the
-- manager; the function then writes the external reference to BrightHR.
create or replace function public.link_brighthr_employee(
  p_connection_id uuid,
  p_external_employee_id text,
  p_staff_id uuid
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_venue_id uuid;
  v_org_id uuid;
begin
  select c.venue_id, c.organization_id into v_venue_id, v_org_id
  from public.brighthr_connections c
  where c.id = p_connection_id;

  if auth.uid() is null or v_venue_id is null or not app_hidden.has_venue_role(
    v_venue_id,
    array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
  ) then
    raise exception 'Not allowed to manage this BrightHR connection' using errcode = '42501';
  end if;

  if not exists (
    select 1 from public.brighthr_employees e
    where e.connection_id = p_connection_id and e.external_employee_id = p_external_employee_id
  ) then
    raise exception 'Unknown BrightHR employee' using errcode = 'P0002';
  end if;

  if p_staff_id is null then
    delete from public.brighthr_employee_mappings
    where connection_id = p_connection_id and external_employee_id = p_external_employee_id;
    return;
  end if;

  if not exists (
    select 1 from public.memberships m
    where m.user_id = p_staff_id
      and m.organization_id = v_org_id
      and (m.venue_id = v_venue_id
           or (m.venue_id is null and m.role in ('organization_owner', 'organization_admin')))
  ) then
    raise exception 'That person is not a member of this venue' using errcode = '22023';
  end if;

  -- A team member maps to at most one BrightHR employee: moving a link replaces the old one.
  delete from public.brighthr_employee_mappings
  where connection_id = p_connection_id
    and staff_id = p_staff_id
    and external_employee_id <> p_external_employee_id;

  insert into public.brighthr_employee_mappings
    (connection_id, external_employee_id, staff_id, linked_by, linked_at, external_reference_synced_at)
  values (p_connection_id, p_external_employee_id, p_staff_id, auth.uid(), now(), null)
  on conflict (connection_id, external_employee_id) do update
    set staff_id = excluded.staff_id,
        linked_by = excluded.linked_by,
        linked_at = excluded.linked_at,
        external_reference_synced_at = case
          when public.brighthr_employee_mappings.staff_id = excluded.staff_id
            then public.brighthr_employee_mappings.external_reference_synced_at
          else null
        end;
end;
$$;

revoke all on function public.link_brighthr_employee(uuid, text, uuid) from public, anon;
grant execute on function public.link_brighthr_employee(uuid, text, uuid) to authenticated;

-- A removed team member must not stay linked (their BrightHR data would keep syncing).
create or replace function app_hidden.unlink_brighthr_on_membership_delete()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  delete from public.brighthr_employee_mappings bm
  using public.brighthr_connections c
  where bm.connection_id = c.id
    and bm.staff_id = old.user_id
    and c.organization_id = old.organization_id
    and (old.venue_id is null or c.venue_id = old.venue_id)
    and not exists (
      select 1 from public.memberships m
      where m.user_id = old.user_id
        and m.organization_id = c.organization_id
        and m.id <> old.id
        and (m.venue_id = c.venue_id
             or (m.venue_id is null and m.role in ('organization_owner', 'organization_admin')))
    );
  return old;
end;
$$;

revoke all on function app_hidden.unlink_brighthr_on_membership_delete() from public, anon, authenticated;

create trigger unlink_brighthr_on_membership_delete
  after delete on public.memberships
  for each row execute function app_hidden.unlink_brighthr_on_membership_delete();

-- ---------------------------------------------------------------------------
-- Scheduled sync: pg_cron -> pg_net -> POST brighthr/dispatch (shared-secret header).
-- ---------------------------------------------------------------------------

-- Leases up to p_limit due connections so overlapping dispatches never sync the same one twice.
create or replace function public.claim_brighthr_sync(p_limit integer default 10)
returns table (connection_id uuid, venue_id uuid)
language plpgsql
security definer
set search_path = ''
as $$
begin
  return query
  update public.brighthr_connections c
  set sync_lease_until = now() + interval '10 minutes'
  where c.id in (
    select c2.id from public.brighthr_connections c2
    where c2.next_sync_at <= now()
      and (c2.sync_lease_until is null or c2.sync_lease_until < now())
    order by c2.next_sync_at
    limit greatest(1, least(coalesce(p_limit, 10), 50))
    for update skip locked
  )
  returning c.id, c.venue_id;
end;
$$;

revoke all on function public.claim_brighthr_sync(integer) from public, anon, authenticated;
grant execute on function public.claim_brighthr_sync(integer) to service_role;

create or replace function app_hidden.dispatch_brighthr_sync()
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_url text;
  v_secret text;
  v_request_id bigint;
begin
  select decrypted_secret into v_url
  from vault.decrypted_secrets where name = 'brighthr_sync_dispatch_url';
  select decrypted_secret into v_secret
  from vault.decrypted_secrets where name = 'brighthr_sync_dispatch_secret';
  if coalesce(v_url, '') = '' or coalesce(v_secret, '') = '' then
    raise exception 'BrightHR sync dispatch secrets are not configured';
  end if;

  select net.http_post(
    url := v_url,
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-dispatch-secret', v_secret),
    body := '{}'::jsonb,
    timeout_milliseconds := 10000
  ) into v_request_id;
  return v_request_id;
end;
$$;

revoke all on function app_hidden.dispatch_brighthr_sync() from public, anon, authenticated;

-- Keep only the last 30 days of run history.
create or replace function app_hidden.cleanup_brighthr_sync_runs()
returns bigint
language plpgsql
set search_path = ''
as $$
declare
  v_deleted bigint;
begin
  delete from public.brighthr_sync_runs where started_at < now() - interval '30 days';
  get diagnostics v_deleted = row_count;
  return v_deleted;
end;
$$;

revoke all on function app_hidden.cleanup_brighthr_sync_runs() from public, anon, authenticated;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    if exists (select 1 from cron.job where jobname = 'brighthr-sync') then
      perform cron.unschedule('brighthr-sync');
    end if;
    if exists (select 1 from cron.job where jobname = 'brighthr-sync-runs-cleanup') then
      perform cron.unschedule('brighthr-sync-runs-cleanup');
    end if;
    perform cron.schedule(
      'brighthr-sync-runs-cleanup', '17 3 * * *',
      'select app_hidden.cleanup_brighthr_sync_runs();'
    );
    -- Each connection syncs at most every 30 minutes (next_sync_at); dispatch checks every 10.
    if exists (select 1 from pg_extension where extname = 'pg_net')
       and exists (select 1 from vault.decrypted_secrets where name = 'brighthr_sync_dispatch_url')
       and exists (select 1 from vault.decrypted_secrets where name = 'brighthr_sync_dispatch_secret') then
      perform cron.schedule(
        'brighthr-sync', '*/10 * * * *',
        'select app_hidden.dispatch_brighthr_sync();'
      );
    end if;
  end if;
exception when others then
  null;
end;
$$;

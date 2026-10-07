-- POS schedule foundation. Provider traffic remains disabled until a verified adapter and
-- merchant authorization are provisioned. The existing pos_outbound_commands table is
-- reserved for legacy menu commands; schedule jobs use a separate ordered outbox.
alter table public.pos_connections
  add column if not exists product text not null default 'restaurant',
  add column if not exists readiness text not null default 'approval_required',
  add column if not exists credential_ref text,
  add column if not exists last_inbound_at timestamptz,
  add column if not exists last_outbound_at timestamptz;
alter table public.pos_connections add constraint pos_connection_readiness_check
  check (readiness in ('approval_required','configuration_required','connected','disconnected','failed'));
-- A historical "active" flag is not evidence that an API call succeeded.
update public.pos_connections set readiness = 'configuration_required' where status = 'active';
-- Legacy queue has no delivery worker. A modified client must not enqueue it directly.
revoke insert on public.pos_outbound_commands from authenticated;
revoke all on public.pos_connections from authenticated;
grant select (id, organization_id, venue_id, provider, product, external_location_id,
  status, readiness, last_sync_at, last_inbound_at, last_outbound_at, created_at,
  updated_at) on public.pos_connections to authenticated;

create table public.pos_connection_capabilities (
  connection_id uuid not null references public.pos_connections(id) on delete cascade,
  capability text not null check (capability in ('sales_read','employees_read','jobs_read',
    'time_entries_read','scheduled_shifts_read','scheduled_shifts_create',
    'scheduled_shifts_update','scheduled_shifts_cancel','scheduled_shifts_publish')),
  state text not null default 'unverified' check (state in
    ('verified_supported','verified_unsupported','requires_approval','unverified')),
  evidence_url text,
  verified_at date,
  primary key (connection_id, capability),
  check (state <> 'verified_supported' or (evidence_url is not null and verified_at is not null))
);

create table public.pos_location_mappings (
  id uuid primary key default gen_random_uuid(),
  connection_id uuid not null references public.pos_connections(id) on delete cascade,
  venue_id uuid not null references public.venues(id),
  external_location_id text not null check (length(trim(external_location_id)) > 0),
  unique (connection_id, venue_id), unique (connection_id, external_location_id)
);
create table public.pos_employee_mappings (
  connection_id uuid not null references public.pos_connections(id) on delete cascade,
  staff_id uuid not null references auth.users(id),
  external_employee_id text not null check (length(trim(external_employee_id)) > 0),
  reviewed_at timestamptz not null default now(),
  primary key (connection_id, staff_id), unique (connection_id, external_employee_id)
);
create table public.pos_job_mappings (
  connection_id uuid not null references public.pos_connections(id) on delete cascade,
  role_label text not null check (length(trim(role_label)) > 0),
  external_job_id text not null check (length(trim(external_job_id)) > 0),
  reviewed_at timestamptz not null default now(),
  primary key (connection_id, role_label), unique (connection_id, external_job_id)
);
create table public.pos_external_shift_mappings (
  connection_id uuid not null references public.pos_connections(id) on delete cascade,
  shift_id uuid not null references public.shifts(id),
  external_shift_id text,
  provider_revision text,
  ownership text not null default 'venue_wrangler' check (ownership in ('venue_wrangler','external')),
  sync_status text not null default 'pending' check (sync_status in
    ('pending','synced','conflict','cancel_pending','cancelled','failed')),
  last_published_version bigint not null default 0,
  updated_at timestamptz not null default now(),
  primary key (connection_id, shift_id), unique (connection_id, external_shift_id)
);
grant select on public.pos_external_shift_mappings to service_role;
create table public.pos_schedule_versions (
  connection_id uuid primary key references public.pos_connections(id) on delete cascade,
  version bigint not null default 0 check (version >= 0),
  published_at timestamptz,
  published_by uuid references auth.users(id)
);
create table public.pos_outbound_jobs (
  id uuid primary key default gen_random_uuid(),
  connection_id uuid not null references public.pos_connections(id) on delete cascade,
  shift_id uuid not null references public.shifts(id),
  version bigint not null,
  operation text not null check (operation in ('create','update','cancel')),
  snapshot jsonb not null,
  idempotency_key text not null unique,
  status text not null default 'pending' check (status in
    ('pending','processing','reconciling','synced','retryable','blocked','dead')),
  attempts integer not null default 0 check (attempts >= 0),
  max_attempts integer not null default 8 check (max_attempts > 0),
  next_attempt_at timestamptz not null default now(),
  lease_until timestamptz,
  error_code text,
  error_detail text,
  created_at timestamptz not null default now(),
  completed_at timestamptz,
  unique (connection_id, shift_id, version)
);
create index pos_outbound_jobs_claim_idx on public.pos_outbound_jobs
  (status, next_attempt_at, created_at) where status in ('pending','retryable');
grant select on public.pos_outbound_jobs to service_role;
create table public.pos_sync_conflicts (
  id uuid primary key default gen_random_uuid(),
  connection_id uuid not null references public.pos_connections(id) on delete cascade,
  shift_id uuid references public.shifts(id),
  kind text not null,
  status text not null default 'open' check (status in ('open','resolved')),
  detail text not null,
  created_at timestamptz not null default now(),
  resolved_at timestamptz
);
create table public.pos_sales (
  connection_id uuid not null references public.pos_connections(id) on delete cascade,
  external_sale_id text not null,
  business_date date not null,
  currency char(3) not null,
  gross_cents bigint not null,
  discount_cents bigint not null default 0,
  refund_cents bigint not null default 0,
  tax_cents bigint not null default 0,
  tip_cents bigint not null default 0,
  net_cents bigint not null,
  source_revision text,
  source_timestamp timestamptz,
  synced_at timestamptz not null default now(),
  primary key (connection_id, external_sale_id)
);
create table public.pos_time_entries (
  connection_id uuid not null references public.pos_connections(id) on delete cascade,
  external_entry_id text not null,
  external_employee_id text not null,
  clock_in_at timestamptz not null,
  clock_out_at timestamptz,
  break_periods jsonb not null default '[]'::jsonb,
  tips_cents bigint,
  source_revision text,
  synced_at timestamptz not null default now(),
  primary key (connection_id, external_entry_id),
  check (clock_out_at is null or clock_out_at > clock_in_at)
);
create table public.pos_sync_runs (
  id uuid primary key default gen_random_uuid(),
  connection_id uuid not null references public.pos_connections(id) on delete cascade,
  direction text not null check (direction in ('inbound','outbound','reconcile')),
  status text not null check (status in ('running','partial','succeeded','failed')),
  checkpoint text,
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  error_code text
);
create table public.pos_audit_events (
  id uuid primary key default gen_random_uuid(),
  connection_id uuid not null references public.pos_connections(id) on delete cascade,
  actor_id uuid references auth.users(id),
  event_type text not null,
  entity_id uuid,
  detail jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

-- No client writes to integration state. Service workers use the service role.
do $$ declare t text; begin
  foreach t in array array['pos_connection_capabilities','pos_location_mappings',
    'pos_employee_mappings','pos_job_mappings','pos_external_shift_mappings',
    'pos_schedule_versions','pos_outbound_jobs','pos_sync_conflicts',
    'pos_sales','pos_time_entries',
    'pos_sync_runs','pos_audit_events'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('alter table public.%I force row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
    execute format('create policy %I on public.%I for select to authenticated using (exists
      (select 1 from public.pos_connections c where c.id = connection_id and
       app_hidden.has_venue_role(c.venue_id,
       array[''venue_manager'',''organization_owner'',''organization_admin'']::public.app_role[])))',
      t || '_manager_read', t);
    execute format('grant select on public.%I to authenticated', t);
  end loop;
end $$;
-- The manager read policy above uses connection_id; location, employee, and job mapping
-- rows cannot be moved to a different tenant through the API because no write grant exists.

-- A manager may request onboarding without entering a credential or claiming provider access.
-- This is the only client-initiated connection mutation; authorization stays in the DB.
create or replace function public.request_pos_connection(p_venue_id uuid, p_provider text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  v_connection_id uuid;
  v_product text;
begin
  if not app_hidden.has_venue_role(p_venue_id,
      array['venue_manager','organization_owner','organization_admin']::public.app_role[]) then
    raise exception 'forbidden_pos_venue' using errcode = '42501';
  end if;
  v_product := case p_provider
    when 'toast' then 'restaurant'
    when 'square' then 'restaurant'
    when 'spoton' then 'restaurant'
    when 'clover' then 'restaurant'
    when 'lightspeed_restaurant_k' then 'K-Series'
    when 'lightspeed_restaurant_l' then 'L-Series'
    when 'oracle_simphony' then 'Simphony'
    when 'ncr_aloha' then 'Aloha'
    else null end;
  if v_product is null then
    raise exception 'unsupported_pos_provider' using errcode = '22023';
  end if;
  insert into public.pos_connections(venue_id, provider, product, status, readiness)
    values (p_venue_id, p_provider, v_product, 'inactive', 'approval_required')
    on conflict (venue_id, provider) do nothing returning id into v_connection_id;
  if v_connection_id is null then
    select id into v_connection_id from public.pos_connections
      where venue_id = p_venue_id and provider = p_provider;
    return v_connection_id;
  end if;
  insert into public.pos_connection_capabilities(connection_id, capability)
    select v_connection_id, unnest(array['sales_read','employees_read','jobs_read',
      'time_entries_read','scheduled_shifts_read','scheduled_shifts_create',
      'scheduled_shifts_update','scheduled_shifts_cancel','scheduled_shifts_publish']);
  insert into public.pos_audit_events(connection_id, actor_id, event_type)
    values (v_connection_id, auth.uid(), 'setup_requested');
  return v_connection_id;
end $$;
revoke all on function public.request_pos_connection(uuid, text) from public, anon;
grant execute on function public.request_pos_connection(uuid, text) to authenticated;

create or replace function public.publish_pos_schedule(p_connection_id uuid)
returns bigint language plpgsql security definer set search_path = '' as $$
declare
  c public.pos_connections%rowtype;
  v bigint;
  s public.shifts%rowtype;
  m public.pos_external_shift_mappings%rowtype;
  op text;
  employee_external text;
  job_external text;
  location_external text;
  required_capability text;
begin
  select * into c from public.pos_connections where id = p_connection_id for update;
  if not found or not app_hidden.has_venue_role(c.venue_id,
      array['venue_manager','organization_owner','organization_admin']::public.app_role[]) then
    raise exception 'forbidden_pos_connection' using errcode = '42501';
  end if;
  if c.readiness <> 'connected' or c.status <> 'active' then
    raise exception 'pos_connection_not_ready' using errcode = 'P0001';
  end if;
  if exists (select 1 from public.pos_outbound_jobs
    where connection_id = c.id and status <> 'synced') then
    raise exception 'previous_pos_publication_unresolved' using errcode = 'P0001';
  end if;
  select external_location_id into location_external from public.pos_location_mappings
    where connection_id = c.id and venue_id = c.venue_id;
  if location_external is null then
    raise exception 'missing_location_mapping' using errcode = 'P0001';
  end if;
  insert into public.pos_schedule_versions(connection_id) values (c.id)
    on conflict (connection_id) do nothing;
  update public.pos_schedule_versions set version = version + 1,
    published_at = now(), published_by = auth.uid()
    where connection_id = c.id returning version into v;
  for s in select sh.* from public.shifts sh where sh.venue_id = c.venue_id
    and (sh.status = 'scheduled' or exists (select 1 from public.pos_external_shift_mappings x
      where x.connection_id = c.id and x.shift_id = sh.id and x.sync_status <> 'cancelled'))
    order by sh.id loop
    select * into m from public.pos_external_shift_mappings
      where connection_id = c.id and shift_id = s.id;
    if m.ownership = 'external' then
      raise exception 'external_shift_conflict' using errcode = 'P0001';
    end if;
    if s.status = 'cancelled' then
      if m.external_shift_id is null then continue; end if;
      op := 'cancel';
    elsif m.external_shift_id is null then op := 'create';
    else op := 'update'; end if;
    required_capability := 'scheduled_shifts_' || op;
    if not exists (select 1 from public.pos_connection_capabilities
      where connection_id = c.id and capability = required_capability
        and state = 'verified_supported') then
      raise exception 'unsupported_or_unverified_capability: %', required_capability
        using errcode = 'P0001';
    end if;
    if c.provider = 'square' and not exists (select 1 from public.pos_connection_capabilities
      where connection_id = c.id and capability = 'scheduled_shifts_publish'
        and state = 'verified_supported') then
      raise exception 'unsupported_or_unverified_capability: scheduled_shifts_publish'
        using errcode = 'P0001';
    end if;
    if op <> 'cancel' then
      if s.staff_id is null or s.role_label is null then
        raise exception 'unassigned_or_unroled_shift: %', s.id using errcode = 'P0001';
      end if;
      select external_employee_id into employee_external from public.pos_employee_mappings
        where connection_id = c.id and staff_id = s.staff_id;
      select external_job_id into job_external from public.pos_job_mappings
        where connection_id = c.id and role_label = s.role_label;
      if employee_external is null or job_external is null then
        raise exception 'missing_employee_or_job_mapping: %', s.id using errcode = 'P0001';
      end if;
    end if;
    insert into public.pos_external_shift_mappings(connection_id, shift_id)
      values (c.id, s.id) on conflict (connection_id, shift_id) do nothing;
    insert into public.pos_outbound_jobs(connection_id, shift_id, version,
      operation, snapshot, idempotency_key) values (c.id, s.id, v, op,
      jsonb_build_object('venue_id', c.venue_id, 'external_location_id', location_external,
        'external_employee_id', employee_external, 'external_job_id', job_external,
        'external_shift_id', m.external_shift_id, 'provider_revision', m.provider_revision,
        'start_time', s.start_time, 'end_time', s.end_time,
        'timezone', (select timezone from public.venues where id = c.venue_id)),
      c.id::text || ':' || s.id::text || ':' || v::text);
    employee_external := null; job_external := null;
  end loop;
  insert into public.pos_audit_events(connection_id, actor_id, event_type, detail)
    values (c.id, auth.uid(), 'schedule_published', jsonb_build_object('version', v));
  return v;
end $$;
revoke all on function public.publish_pos_schedule(uuid) from public, anon;
grant execute on function public.publish_pos_schedule(uuid) to authenticated;

-- A service-role worker may claim only the oldest unresolved operation for a shift.
-- An expired processing lease moves to reconciliation; it must not be sent again blindly
-- because a provider could have accepted the original request before the response was lost.
create or replace function public.claim_pos_outbound_jobs(p_batch_size integer default 10)
returns setof public.pos_outbound_jobs language plpgsql security definer
set search_path = '' as $$
begin
  if p_batch_size < 1 or p_batch_size > 100 then
    raise exception 'invalid_batch_size' using errcode = '22023';
  end if;
  update public.pos_outbound_jobs set status = 'reconciling', lease_until = null,
    error_code = 'acknowledgment_uncertain'
    where status = 'processing' and lease_until < now();
  return query
  update public.pos_outbound_jobs j set status = 'processing',
    attempts = j.attempts + 1, lease_until = now() + interval '2 minutes'
  where j.id in (
    select candidate.id from public.pos_outbound_jobs candidate
    where candidate.status in ('pending','retryable')
      and candidate.next_attempt_at <= now()
      and candidate.attempts < candidate.max_attempts
      and not exists (select 1 from public.pos_outbound_jobs earlier
        where earlier.connection_id = candidate.connection_id
          and earlier.shift_id = candidate.shift_id
          and earlier.version < candidate.version
          and earlier.status <> 'synced')
    order by candidate.created_at, candidate.id
    limit p_batch_size for update skip locked
  ) returning j.*;
end $$;
revoke all on function public.claim_pos_outbound_jobs(integer) from public, anon, authenticated;
grant execute on function public.claim_pos_outbound_jobs(integer) to service_role;

-- Called only after a provider acknowledgment or after reconciliation finds the write.
-- A lost HTTP response may still be acknowledged later without creating another shift.
create or replace function public.ack_pos_outbound_job(
  p_job_id uuid, p_external_shift_id text, p_provider_revision text default null
)
returns void language plpgsql security definer set search_path = '' as $$
declare
  j public.pos_outbound_jobs%rowtype;
  existing_id text;
begin
  select * into j from public.pos_outbound_jobs where id = p_job_id for update;
  if not found then raise exception 'pos_job_not_found' using errcode = '22023'; end if;
  if j.status = 'synced' then
    if p_external_shift_id is not null and exists (
      select 1 from public.pos_external_shift_mappings
      where connection_id = j.connection_id and shift_id = j.shift_id
        and external_shift_id is distinct from p_external_shift_id
    ) then
      raise exception 'external_shift_id_conflict' using errcode = 'P0001';
    end if;
    return;
  end if;
  if j.status not in ('processing','reconciling') then
    raise exception 'pos_job_not_claimed' using errcode = 'P0001';
  end if;
  if j.operation <> 'cancel' and
      (p_external_shift_id is null or length(trim(p_external_shift_id)) = 0 or
       length(p_external_shift_id) > 256) then
    raise exception 'missing_external_shift_id' using errcode = '22023';
  end if;
  select external_shift_id into existing_id from public.pos_external_shift_mappings
    where connection_id = j.connection_id and shift_id = j.shift_id for update;
  if not found then
    raise exception 'pos_shift_mapping_missing' using errcode = 'P0001';
  end if;
  if j.operation = 'cancel' and existing_id is null then
    raise exception 'missing_external_shift_id' using errcode = 'P0001';
  end if;
  if existing_id is not null and p_external_shift_id is not null and
      existing_id <> p_external_shift_id then
    raise exception 'external_shift_id_conflict' using errcode = 'P0001';
  end if;
  update public.pos_external_shift_mappings set
    external_shift_id = coalesce(existing_id, p_external_shift_id),
    provider_revision = p_provider_revision,
    last_published_version = j.version,
    sync_status = case when j.operation = 'cancel' then 'cancelled' else 'synced' end,
    updated_at = now()
    where connection_id = j.connection_id and shift_id = j.shift_id;
  update public.pos_outbound_jobs set status = 'synced', lease_until = null,
    error_code = null, error_detail = null, completed_at = now()
    where id = j.id;
  update public.pos_connections set last_outbound_at = now() where id = j.connection_id;
  insert into public.pos_audit_events(connection_id, event_type, entity_id, detail)
    values (j.connection_id, 'provider_acknowledged', j.shift_id,
      jsonb_build_object('job_id', j.id, 'version', j.version, 'operation', j.operation));
end $$;
revoke all on function public.ack_pos_outbound_job(uuid, text, text)
  from public, anon, authenticated;
grant execute on function public.ack_pos_outbound_job(uuid, text, text) to service_role;

-- The worker supplies a short redacted code, never raw provider payloads or tokens.
create or replace function public.fail_pos_outbound_job(
  p_job_id uuid, p_error_code text, p_retryable boolean, p_uncertain boolean default false
)
returns text language plpgsql security definer set search_path = '' as $$
declare
  j public.pos_outbound_jobs%rowtype;
  next_status text;
begin
  select * into j from public.pos_outbound_jobs where id = p_job_id for update;
  if not found then raise exception 'pos_job_not_found' using errcode = '22023'; end if;
  if j.status <> 'processing' then
    raise exception 'pos_job_not_processing' using errcode = 'P0001';
  end if;
  if p_error_code is null or p_error_code !~ '^[a-z0-9_]{1,80}$' then
    raise exception 'invalid_redacted_error_code' using errcode = '22023';
  end if;
  next_status := case
    when p_uncertain then 'reconciling'
    when p_retryable and j.attempts < j.max_attempts then 'retryable'
    when p_retryable then 'dead'
    else 'blocked' end;
  update public.pos_outbound_jobs set status = next_status,
    lease_until = null, error_code = p_error_code,
    next_attempt_at = case when next_status = 'retryable' then
      now() + make_interval(secs => least(3600, 5 * power(2, least(j.attempts, 10)))::integer)
      else next_attempt_at end
    where id = j.id;
  insert into public.pos_audit_events(connection_id, event_type, entity_id, detail)
    values (j.connection_id, 'provider_write_failed', j.shift_id,
      jsonb_build_object('job_id', j.id, 'status', next_status, 'error_code', p_error_code));
  return next_status;
end $$;
revoke all on function public.fail_pos_outbound_job(uuid, text, boolean, boolean)
  from public, anon, authenticated;
grant execute on function public.fail_pos_outbound_job(uuid, text, boolean, boolean)
  to service_role;

-- Prevent hard deletion of shifts with retained POS identifiers or pending operations.
create or replace function app_hidden.protect_pos_shift_delete()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if exists (select 1 from public.pos_external_shift_mappings
    where shift_id = old.id and sync_status <> 'cancelled') then
    raise exception 'cancel_and_publish_pos_shift_before_delete' using errcode = 'P0001';
  end if;
  return old;
end $$;
create trigger protect_pos_shift_delete before delete on public.shifts
  for each row execute function app_hidden.protect_pos_shift_delete();

-- Preserve the old local-draft delete behavior while retaining any shift with POS history
-- so its cancellation can be published. Both branches require a venue manager.
create or replace function public.remove_or_cancel_shift(p_shift_id uuid)
returns text language plpgsql security definer set search_path = '' as $$
declare
  s public.shifts%rowtype;
begin
  select * into s from public.shifts where id = p_shift_id for update;
  if not found then raise exception 'shift_not_found' using errcode = '22023'; end if;
  if not app_hidden.has_venue_role(s.venue_id,
      array['venue_manager','organization_owner','organization_admin']::public.app_role[]) then
    raise exception 'forbidden_shift' using errcode = '42501';
  end if;
  if exists (select 1 from public.pos_external_shift_mappings
    where shift_id = s.id) then
    if s.status = 'completed' then
      raise exception 'completed_shift_cannot_cancel' using errcode = 'P0001';
    end if;
    update public.shifts set status = 'cancelled' where id = s.id;
    return 'cancelled';
  end if;
  delete from public.shifts where id = s.id;
  return 'deleted';
end $$;
revoke all on function public.remove_or_cancel_shift(uuid) from public, anon;
grant execute on function public.remove_or_cancel_shift(uuid) to authenticated;

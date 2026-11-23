-- Remediation for code-review H8, M1, M2, M5, M7:
--   H8  Replace settable session GUCs (app.*) used as authorization bypass gates with a
--       private app_hidden.privilege_gate table that only SECURITY DEFINER helpers can write.
--   M1  accept_invite updates membership role on conflict and refuses to mark accepted unless
--       the membership matches the invite role.
--   M2  pending→accepted only via accept_invite (privilege gate); expose revoke_invite RPC.
--   M5  erase_guest scrubs POS checks by guest_id, not display-name equality.
--   M7  Manager path in enforce_shift_swap_update still freezes immutable columns.

-- =============================================================================
-- H8: privilege gate (private; no client grants)
-- =============================================================================
create table if not exists app_hidden.privilege_gate (
  backend_pid integer not null,
  txid xid8 not null,
  flag text not null,
  opened_at timestamptz not null default now(),
  primary key (backend_pid, txid, flag)
);

revoke all on table app_hidden.privilege_gate from public, anon, authenticated;
alter table app_hidden.privilege_gate enable row level security;
alter table app_hidden.privilege_gate force row level security;

create or replace function app_hidden.open_privilege_gate(p_flag text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_flag is null or length(trim(p_flag)) = 0 then
    raise exception 'privilege gate flag is required' using errcode = '22023';
  end if;

  -- Drop stale rows for this backend (prior xacts) and for dead backends.
  delete from app_hidden.privilege_gate g
   where (g.backend_pid = pg_backend_pid() and g.txid is distinct from pg_current_xact_id())
      or not exists (select 1 from pg_stat_activity a where a.pid = g.backend_pid);

  insert into app_hidden.privilege_gate (backend_pid, txid, flag)
  values (pg_backend_pid(), pg_current_xact_id(), p_flag)
  on conflict do nothing;
end;
$$;

create or replace function app_hidden.close_privilege_gate(p_flag text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  delete from app_hidden.privilege_gate
   where backend_pid = pg_backend_pid()
     and txid = pg_current_xact_id()
     and flag = p_flag;
end;
$$;

create or replace function app_hidden.privilege_gate_is_open(p_flag text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
      from app_hidden.privilege_gate g
     where g.backend_pid = pg_backend_pid()
       and g.txid = pg_current_xact_id()
       and g.flag = p_flag
  );
$$;

revoke all on function app_hidden.open_privilege_gate(text) from public, anon, authenticated;
revoke all on function app_hidden.close_privilege_gate(text) from public, anon, authenticated;
revoke all on function app_hidden.privilege_gate_is_open(text) from public, anon, authenticated;

-- Account-deletion helper now reads the private gate instead of a settable GUC.
create or replace function app_hidden.account_deletion_in_progress()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select app_hidden.privilege_gate_is_open('account_deletion');
$$;

-- =============================================================================
-- H8: rewrite DEFINER writers / triggers that previously used app.* GUCs
-- =============================================================================

-- correct_time_entry
create or replace function public.correct_time_entry(
  p_entry_id uuid,
  p_clock_out_at timestamptz default null,
  p_breaks jsonb default null,
  p_reason text default null
)
returns public.time_entries
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_entry public.time_entries;
  v_before jsonb;
begin
  select * into v_entry from public.time_entries where id = p_entry_id;
  if v_entry.id is null then
    raise exception 'time entry % does not exist', p_entry_id using errcode = 'P0002';
  end if;

  if not app_hidden.has_venue_role(
    v_entry.venue_id,
    array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
  ) then
    raise exception 'forbidden: only managers can correct time entries' using errcode = '42501';
  end if;

  if v_entry.user_id = auth.uid() then
    raise exception 'managers cannot correct their own time entries' using errcode = '42501';
  end if;

  if p_clock_out_at is not null then
    if p_clock_out_at <= v_entry.clock_in_at then
      raise exception 'clock-out must be after clock-in' using errcode = '22023';
    end if;
    if p_clock_out_at > now() + interval '1 minute' then
      raise exception 'clock-out cannot be in the future' using errcode = '22023';
    end if;
  end if;

  v_before := app_hidden.scrub_time_entry_json(to_jsonb(v_entry));

  perform app_hidden.open_privilege_gate('time_entry_correction');

  update public.time_entries
  set
    clock_out_at = coalesce(p_clock_out_at, clock_out_at),
    is_open = case when p_clock_out_at is not null then false else is_open end,
    breaks = coalesce(p_breaks, breaks)
  where id = p_entry_id
  returning * into v_entry;

  perform app_hidden.close_privilege_gate('time_entry_correction');

  insert into public.audit_log (
    organization_id, venue_id, actor_user_id, action, target_table, target_id, metadata
  ) values (
    v_entry.organization_id, v_entry.venue_id, auth.uid(), 'time_entry.correct',
    'time_entries', v_entry.id,
    jsonb_build_object(
      'before', v_before,
      'after', app_hidden.scrub_time_entry_json(to_jsonb(v_entry)),
      'reason', p_reason
    )
  );

  return v_entry;
end;
$$;

revoke all on function public.correct_time_entry(uuid, timestamptz, jsonb, text) from public, anon;
grant execute on function public.correct_time_entry(uuid, timestamptz, jsonb, text) to authenticated;

-- record_attested_punch
create or replace function public.record_attested_punch(
  p_user_id uuid,
  p_venue_id uuid,
  p_kind text,
  p_lat double precision,
  p_lng double precision,
  p_accuracy_m double precision,
  p_mocked boolean,
  p_attested boolean
)
returns public.time_entries
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_org uuid;
  v_entry public.time_entries;
begin
  if p_kind not in ('in', 'out') then
    raise exception 'invalid punch kind' using errcode = '22023';
  end if;

  select v.organization_id into v_org from public.venues v where v.id = p_venue_id;
  if v_org is null or not exists (
    select 1 from public.memberships m
    where m.user_id = p_user_id and m.organization_id = v_org
      and (m.venue_id = p_venue_id or m.venue_id is null)
  ) then
    raise exception 'not a member of this venue' using errcode = '42501';
  end if;

  perform set_config('request.jwt.claim.sub', p_user_id::text, true);
  if coalesce(p_attested, false) then
    perform app_hidden.open_privilege_gate('attested_punch');
  end if;

  if p_kind = 'in' then
    insert into public.time_entries (venue_id, clock_in_lat, clock_in_lng, clock_in_accuracy_m, clock_in_mocked)
    values (p_venue_id, p_lat, p_lng, p_accuracy_m, coalesce(p_mocked, false))
    returning * into v_entry;
  else
    update public.time_entries
       set is_open = false,
           clock_out_lat = p_lat, clock_out_lng = p_lng, clock_out_accuracy_m = p_accuracy_m,
           clock_out_mocked = coalesce(p_mocked, false)
     where user_id = p_user_id and venue_id = p_venue_id and is_open
    returning * into v_entry;
    if v_entry.id is null then
      perform app_hidden.close_privilege_gate('attested_punch');
      raise exception 'no open punch to close' using errcode = 'P0002';
    end if;
  end if;

  perform app_hidden.close_privilege_gate('attested_punch');
  return v_entry;
end;
$$;

revoke all on function public.record_attested_punch(uuid, uuid, text, double precision, double precision, double precision, boolean, boolean)
  from public, anon, authenticated;
grant execute on function public.record_attested_punch(uuid, uuid, text, double precision, double precision, double precision, boolean, boolean)
  to service_role;

-- record_contract_signature
create or replace function public.record_contract_signature(
  p_contract_id uuid,
  p_signer_name text,
  p_fully_signed boolean default true,
  p_note text default null
)
returns public.crm_contracts
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_contract public.crm_contracts;
  v_name text := trim(coalesce(p_signer_name, ''));
  v_status text := case when coalesce(p_fully_signed, true) then 'fully_signed' else 'partially_signed' end;
  v_hash text;
  v_ip text;
  v_agent text;
  v_headers jsonb;
begin
  select * into v_contract from public.crm_contracts where id = p_contract_id for update;
  if not found then
    raise exception 'contract not found' using errcode = 'P0002';
  end if;

  if auth.uid() is null or not app_hidden.has_venue_role(
    v_contract.venue_id, array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
  ) then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  if v_contract.status not in ('draft', 'sent', 'viewed', 'partially_signed') then
    raise exception 'contract is % and cannot be signed', v_contract.status using errcode = 'P0001';
  end if;
  if char_length(v_name) < 2 or char_length(v_name) > 120 then
    raise exception 'signer name must be 2-120 characters' using errcode = '22023';
  end if;

  v_hash := encode(
    sha256(convert_to((to_jsonb(v_contract) - 'status' - 'updated_at' - 'client_signature_name' - 'client_signature_date')::text, 'UTF8')),
    'hex'
  );

  begin
    v_headers := nullif(current_setting('request.headers', true), '')::jsonb;
  exception when others then
    v_headers := null;
  end;
  v_ip := left(split_part(coalesce(v_headers ->> 'x-forwarded-for', ''), ',', 1), 64);
  v_agent := left(coalesce(v_headers ->> 'user-agent', ''), 300);

  perform app_hidden.open_privilege_gate('contract_signing');
  update public.crm_contracts
     set client_signature_name = v_name,
         client_signature_date = now(),
         status = v_status
   where id = v_contract.id
  returning * into v_contract;
  perform app_hidden.close_privilege_gate('contract_signing');

  insert into public.contract_signature_events (
    contract_id, organization_id, venue_id, signer_name, resulting_status, note, content_sha256,
    recorded_by, client_ip, user_agent
  ) values (
    v_contract.id, v_contract.organization_id, v_contract.venue_id, v_name, v_status,
    nullif(trim(coalesce(p_note, '')), ''), v_hash, auth.uid(), nullif(v_ip, ''), nullif(v_agent, '')
  );

  perform app_hidden.audit_event(
    v_contract.organization_id, v_contract.venue_id, 'contract.signature_recorded', 'crm_contracts', v_contract.id,
    jsonb_build_object('status', v_status, 'content_sha256', v_hash)
  );

  return v_contract;
end;
$$;

revoke all on function public.record_contract_signature(uuid, text, boolean, text) from public, anon;
grant execute on function public.record_contract_signature(uuid, text, boolean, text) to authenticated;

-- guard_contract_signature
create or replace function app_hidden.guard_contract_signature()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_signing boolean := app_hidden.privilege_gate_is_open('contract_signing');
  v_terms_old jsonb;
  v_terms_new jsonb;
begin
  if app_hidden.account_deletion_in_progress() then
    return new;
  end if;

  if tg_op = 'INSERT' then
    if not v_signing and (
      new.status in ('partially_signed', 'fully_signed')
      or new.client_signature_name is not null
      or new.client_signature_date is not null
    ) then
      raise exception 'contracts are signed through record_contract_signature' using errcode = '42501';
    end if;
    return new;
  end if;

  if not v_signing then
    if new.client_signature_name is distinct from old.client_signature_name
       or new.client_signature_date is distinct from old.client_signature_date
       or (new.status in ('partially_signed', 'fully_signed') and new.status is distinct from old.status) then
      raise exception 'contracts are signed through record_contract_signature' using errcode = '42501';
    end if;

    if old.status = 'fully_signed' and new.status not in ('fully_signed', 'disputed', 'cancelled') then
      raise exception 'a fully signed contract can only be disputed or cancelled' using errcode = '42501';
    end if;

    if old.status in ('partially_signed', 'fully_signed') then
      v_terms_old := to_jsonb(old) - 'status' - 'updated_at';
      v_terms_new := to_jsonb(new) - 'status' - 'updated_at';
      if v_terms_old is distinct from v_terms_new then
        raise exception 'the terms of a signed contract cannot be changed' using errcode = '42501';
      end if;
    end if;
  end if;

  return new;
end;
$$;

-- prepare_time_entry_insert (attestation via gate)
CREATE OR REPLACE FUNCTION app_hidden.prepare_time_entry_insert()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_attested boolean := app_hidden.privilege_gate_is_open('attested_punch');
  v_venue record;
  v_dist double precision;
  v_prior_match record;
begin
  select id, organization_id, latitude, longitude, geofence_radius_m, timezone
  into v_venue
  from public.venues
  where id = new.venue_id;

  if v_venue.id is null then
    raise exception 'venue % does not exist', new.venue_id;
  end if;

  new.organization_id := v_venue.organization_id;
  if not app_hidden.has_venue_role(
    new.venue_id,
    array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
  ) or new.user_id is null then
    new.user_id := auth.uid();
  end if;

  if new.user_id is distinct from auth.uid() and not exists (
    select 1
    from public.memberships m
    where m.user_id = new.user_id
      and m.organization_id = v_venue.organization_id
      and (m.venue_id = new.venue_id or m.venue_id is null)
  ) then
    raise exception 'time entry user must belong to the same venue' using errcode = '23503';
  end if;

  if new.shift_id is not null and not exists (
    select 1
    from public.shifts s
    where s.id = new.shift_id
      and s.venue_id = new.venue_id
  ) then
    raise exception 'shift must belong to the same venue' using errcode = '23503';
  end if;

  new.clock_in_at := now();
  new.is_open := true;
  new.clock_out_at := null;

  new.clock_in_attested := v_attested;
  new.clock_out_attested := false;
  new.punch_source := case when v_attested then 'attested' else 'direct' end;
  if not v_attested and new.user_id is not distinct from auth.uid()
     and coalesce((select s.require_attested_punches from app_hidden.platform_settings s), false) then
    raise exception 'attested_punch_required' using errcode = '42501';
  end if;

  if new.clock_in_mocked then
    raise exception 'Mocked locations are not allowed' using errcode = '42501';
  end if;

  if new.clock_in_accuracy_m > 50.0 then
    raise exception 'Location accuracy must be 50m or better' using errcode = '42501';
  end if;

  if v_venue.latitude is not null and v_venue.longitude is not null
     and not (v_venue.latitude = 0.0 and v_venue.longitude = 0.0) then
    v_dist := app_hidden.haversine_distance_m(
      new.clock_in_lat,
      new.clock_in_lng,
      v_venue.latitude,
      v_venue.longitude
    );
    if v_dist > v_venue.geofence_radius_m then
      raise exception 'You are outside the venue geofence' using errcode = '42501';
    end if;
  end if;

  select clock_in_lat, clock_in_lng, clock_in_accuracy_m
  into v_prior_match
  from public.time_entries
  where user_id = new.user_id
    and clock_in_at < (
      ((now() at time zone coalesce(v_venue.timezone, 'UTC'))::date)::timestamp
        at time zone coalesce(v_venue.timezone, 'UTC')
    )
    and clock_in_lat = new.clock_in_lat
    and clock_in_lng = new.clock_in_lng
  limit 1;

  if v_prior_match is not null then
    if new.clock_in_accuracy_m <= 10.0 then
      raise exception 'This location reading is identical to an earlier punch and reports satellite-grade accuracy' using errcode = '42501';
    else
      new.location_anomaly := 'repeated_fix';
    end if;
  end if;

  return new;
end;
$function$;

-- enforce_time_entry_update (latest attested + gps_purge + correction via gates)
CREATE OR REPLACE FUNCTION app_hidden.enforce_time_entry_update()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_attested boolean := app_hidden.privilege_gate_is_open('attested_punch');
  v_venue record;
  v_dist double precision;
  v_correcting boolean := app_hidden.privilege_gate_is_open('time_entry_correction');
  v_old_breaks jsonb := coalesce(old.breaks, '[]'::jsonb);
  v_new_breaks jsonb := coalesce(new.breaks, '[]'::jsonb);
  v_old_len int := jsonb_array_length(v_old_breaks);
  v_new_len int := jsonb_array_length(v_new_breaks);
  v_changed boolean;
  i int;
  v_last jsonb;
begin
  if app_hidden.privilege_gate_is_open('gps_purge')
     and (to_jsonb(new) - 'clock_in_lat' - 'clock_in_lng' - 'clock_in_accuracy_m' - 'clock_out_lat' - 'clock_out_lng' - 'clock_out_accuracy_m' - 'updated_at')
         = (to_jsonb(old) - 'clock_in_lat' - 'clock_in_lng' - 'clock_in_accuracy_m' - 'clock_out_lat' - 'clock_out_lng' - 'clock_out_accuracy_m' - 'updated_at') then
    return new;
  end if;

  new.clock_in_attested := old.clock_in_attested;
  new.clock_out_attested := old.clock_out_attested;
  new.punch_source := old.punch_source;

  if new.organization_id is distinct from old.organization_id
     or new.venue_id is distinct from old.venue_id
     or new.user_id is distinct from old.user_id
     or new.clock_in_at is distinct from old.clock_in_at
     or new.clock_in_lat is distinct from old.clock_in_lat
     or new.clock_in_lng is distinct from old.clock_in_lng
     or new.clock_in_accuracy_m is distinct from old.clock_in_accuracy_m
     or new.clock_in_mocked is distinct from old.clock_in_mocked
  then
    raise exception 'clock-in fields and ownership are immutable' using errcode = '42501';
  end if;

  if v_correcting then
    new.updated_at := now();
    return new;
  end if;

  if not old.is_open then
    raise exception 'this time entry is closed; use a manager correction to change it'
      using errcode = '42501';
  end if;

  if not new.is_open then
    new.clock_out_at := now();

    new.clock_out_attested := v_attested;
    if not v_attested and auth.uid() is not distinct from old.user_id
       and coalesce((select s.require_attested_punches from app_hidden.platform_settings s), false) then
      raise exception 'attested_punch_required' using errcode = '42501';
    end if;

    if new.clock_out_mocked then
      raise exception 'Mocked locations are not allowed' using errcode = '42501';
    end if;

    if new.clock_out_accuracy_m is not null and new.clock_out_accuracy_m > 50.0 then
      raise exception 'Location accuracy must be 50m or better' using errcode = '42501';
    end if;

    if not app_hidden.has_venue_role(
      new.venue_id,
      array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
    ) then
      if new.clock_out_lat is null or new.clock_out_lng is null or new.clock_out_accuracy_m is null then
        raise exception 'Clock-out location and accuracy are required' using errcode = '42501';
      end if;
    end if;

    select id, latitude, longitude, geofence_radius_m
    into v_venue
    from public.venues
    where id = new.venue_id;

    if new.clock_out_lat is not null and new.clock_out_lng is not null
       and v_venue.latitude is not null and v_venue.longitude is not null
       and not (v_venue.latitude = 0.0 and v_venue.longitude = 0.0) then
      v_dist := app_hidden.haversine_distance_m(
        new.clock_out_lat,
        new.clock_out_lng,
        v_venue.latitude,
        v_venue.longitude
      );
      if v_dist > v_venue.geofence_radius_m then
        raise exception 'You are outside the venue geofence' using errcode = '42501';
      end if;
    end if;

    v_new_breaks := coalesce(new.breaks, '[]'::jsonb);
    v_new_len := jsonb_array_length(v_new_breaks);
    if v_new_len > 0 then
      v_last := v_new_breaks -> (v_new_len - 1);
      if (v_last ? 'end_at') = false or v_last -> 'end_at' = 'null'::jsonb then
        v_new_breaks := jsonb_set(v_new_breaks, array[(v_new_len - 1)::text, 'end_at'], to_jsonb(now()));
      end if;
    end if;
  end if;

  v_changed := v_new_len <> v_old_len;
  if not v_changed then
    for i in 0 .. v_old_len - 1 loop
      if not app_hidden.break_entries_equal(v_new_breaks -> i, v_old_breaks -> i) then
        v_changed := true;
        exit;
      end if;
    end loop;
  end if;

  if v_changed then
    if v_new_len = v_old_len and v_new_len > 0 then
      for i in 0 .. v_old_len - 2 loop
        if not app_hidden.break_entries_equal(v_new_breaks -> i, v_old_breaks -> i) then
          raise exception 'historical breaks cannot be modified' using errcode = '42501';
        end if;
      end loop;
      if (v_old_breaks -> (v_old_len - 1) ->> 'end_at') is not null then
        raise exception 'no open break to close' using errcode = '42501';
      end if;
      if not app_hidden.break_type_and_start_equal(
        v_new_breaks -> (v_old_len - 1), v_old_breaks -> (v_old_len - 1)
      ) then
        raise exception 'only a break''s end time may be set' using errcode = '42501';
      end if;
      v_new_breaks := jsonb_set(v_new_breaks, array[(v_new_len - 1)::text, 'end_at'], to_jsonb(now()));
    elsif v_new_len = v_old_len + 1 then
      for i in 0 .. v_old_len - 1 loop
        if not app_hidden.break_entries_equal(v_new_breaks -> i, v_old_breaks -> i) then
          raise exception 'historical breaks cannot be modified' using errcode = '42501';
        end if;
      end loop;
      if v_old_len > 0 and (v_old_breaks -> (v_old_len - 1) ->> 'end_at') is null then
        raise exception 'a break is already open' using errcode = '42501';
      end if;
      v_new_breaks := jsonb_set(v_new_breaks, array[(v_new_len - 1)::text, 'start_at'], to_jsonb(now()));
      if new.is_open then
        v_new_breaks := jsonb_set(v_new_breaks, array[(v_new_len - 1)::text, 'end_at'], 'null'::jsonb);
      else
        v_new_breaks := jsonb_set(v_new_breaks, array[(v_new_len - 1)::text, 'end_at'], to_jsonb(now()));
      end if;
    else
      raise exception 'breaks can only be appended to or have their open entry closed'
        using errcode = '42501';
    end if;
  end if;
  new.breaks := v_new_breaks;

  new.updated_at := now();
  return new;
end;
$function$;

-- guard_review_row_update: correction gate instead of GUC
create or replace function app_hidden.guard_review_row_update()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_new jsonb := to_jsonb(new);
  v_old jsonb := to_jsonb(old);
begin
  if v_new->>'organization_id' is distinct from v_old->>'organization_id'
     or v_new->>'venue_id' is distinct from v_old->>'venue_id' then
    raise exception 'row ownership cannot be changed' using errcode = '42501';
  end if;

  if tg_table_name = 'shift_swaps' then
    if v_new->>'shift_id' is distinct from v_old->>'shift_id' then
      raise exception 'swap shift cannot be changed' using errcode = '42501';
    end if;
    if v_new->>'status' = 'accepted' and v_old->>'status' is distinct from 'accepted' then
      if v_new->>'accepted_by' is null or not exists (
        select 1 from public.memberships m
        where m.user_id = (v_new->>'accepted_by')::uuid
          and m.organization_id = (v_old->>'organization_id')::uuid
          and (m.venue_id = (v_old->>'venue_id')::uuid or m.venue_id is null)
      ) then
        raise exception 'swap accepter must belong to the shift venue'
          using errcode = '42501';
      end if;
    end if;
  end if;

  if tg_table_name = 'time_entries'
     and (v_new->>'location_anomaly' is distinct from v_old->>'location_anomaly'
          or v_new->>'shift_id' is distinct from v_old->>'shift_id')
     and not app_hidden.privilege_gate_is_open('time_entry_correction') then
    raise exception 'punch integrity fields require a manager correction' using errcode = '42501';
  end if;

  return new;
end;
$$;

-- Retention cleanup: pos_retention / gps_purge via gates
create or replace function app_hidden.run_retention_cleanup()
returns table (
  audit_log_deleted bigint,
  attestation_challenges_deleted bigint,
  retained_time_entries_deleted bigint
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_audit bigint;
  v_audit_corrections bigint;
  v_challenges bigint;
  v_wage bigint;
  v_gps_days integer;
begin
  delete from public.audit_log
    where action not in ('time_entry.correct', 'time_entry.void')
      and created_at < now() - interval '365 days';
  get diagnostics v_audit = row_count;

  delete from public.audit_log
    where action in ('time_entry.correct', 'time_entry.void')
      and created_at < now() - interval '3 years';
  get diagnostics v_audit_corrections = row_count;
  v_audit := v_audit + v_audit_corrections;

  delete from public.attestation_challenges where expires_at < now() - interval '1 hour';
  get diagnostics v_challenges = row_count;

  delete from public.retained_time_entries
    where coalesce(clock_out_at, clock_in_at) < now() - interval '3 years';
  get diagnostics v_wage = row_count;

  delete from public.retained_wage_profiles where retained_at < now() - interval '3 years';

  perform app_hidden.open_privilege_gate('pos_retention');
  update public.pos_checks set raw_payload = null
    where raw_payload is not null and created_at < now() - interval '90 days';
  perform app_hidden.close_privilege_gate('pos_retention');

  update public.reservations
     set guest_name = 'Guest', guest_phone = null, guest_email = null
   where status in ('completed', 'cancelled', 'no_show')
     and reservation_time < now() - interval '24 months'
     and (guest_phone is not null or guest_email is not null or guest_name <> 'Guest');

  delete from public.invites
    where (status <> 'pending' and created_at < now() - interval '90 days')
       or (status = 'pending' and expires_at < now() - interval '30 days');

  delete from public.notification_events where created_at < now() - interval '180 days';

  delete from app_hidden.rate_limit_counters where window_start < now() - interval '2 days';

  select s.gps_retention_days into v_gps_days from app_hidden.platform_settings s;
  if v_gps_days is not null then
    perform app_hidden.open_privilege_gate('gps_purge');
    update public.time_entries
       set clock_in_lat = null, clock_in_lng = null, clock_in_accuracy_m = null,
           clock_out_lat = null, clock_out_lng = null, clock_out_accuracy_m = null
     where not is_open
       and clock_out_at < now() - make_interval(days => v_gps_days)
       and (clock_in_lat is not null or clock_out_lat is not null);
    perform app_hidden.close_privilege_gate('gps_purge');
  end if;

  return query select v_audit, v_challenges, v_wage;
end;
$$;

-- Account deletion: gate instead of GUC (body unchanged aside from open/close)
CREATE OR REPLACE FUNCTION public.request_account_deletion_impl(p_reason text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid uuid := auth.uid();
  v_label text;
  v_sole_owner_orgs integer;
  v_photo record;
  v_job_id uuid;
begin
  if v_uid is null then
    raise exception 'Must be signed in to delete your account' using errcode = '42501';
  end if;

  select count(*) into v_sole_owner_orgs
  from public.memberships m1
  where m1.user_id = v_uid
    and m1.role = 'organization_owner'
    and not exists (
      select 1 from public.memberships m2
      where m2.organization_id = m1.organization_id
        and m2.role = 'organization_owner'
        and m2.user_id <> v_uid
    );

  if v_sole_owner_orgs > 0 then
    raise exception 'You are the only owner of % organization(s). Add another organization owner before deleting your account.', v_sole_owner_orgs
      using errcode = '42501';
  end if;

  v_label := 'deleted_user_' || v_uid::text;

  perform app_hidden.open_privilege_gate('account_deletion');

  insert into public.retained_time_entries (
    original_time_entry_id, organization_id, venue_id, anonymized_user_label,
    shift_id, clock_in_at, clock_out_at, breaks, location_anomaly
  )
  select
    te.id, te.organization_id, te.venue_id, v_label,
    te.shift_id, te.clock_in_at, te.clock_out_at, te.breaks, te.location_anomaly
  from public.time_entries te
  where te.user_id = v_uid;

  insert into public.retained_wage_profiles (
    organization_id, venue_id, anonymized_user_label, legal_name, employee_number, job_title,
    hire_date, hourly_rate_cents
  )
  select v.organization_id, hp.venue_id, v_label, hp.legal_name, hp.employee_number, hp.job_title,
         hp.hire_date, hp.hourly_rate_cents
  from public.employee_hr_profiles hp
  join public.venues v on v.id = hp.venue_id
  where hp.user_id = v_uid and hp.hourly_rate_cents is not null;

  for v_photo in
    select v.organization_id, sp.venue_id, sp.storage_path
    from public.staff_photos sp
    join public.venues v on v.id = sp.venue_id
    where sp.user_id = v_uid
  loop
    insert into public.storage_deletion_jobs (organization_id, venue_id, bucket_id, object_path)
    values (v_photo.organization_id, v_photo.venue_id, 'profile-photos', v_photo.storage_path);
  end loop;

  update public.audit_log set actor_user_id = null where actor_user_id = v_uid;
  update public.organizations set created_by = null where created_by = v_uid;
  update public.venues set created_by = null where created_by = v_uid;
  update public.memberships set created_by = null where created_by = v_uid;
  update public.platform_admins set created_by = null where created_by = v_uid;
  update public.operational_tasks set assigned_to = null where assigned_to = v_uid;
  update public.operational_tasks set created_by = null where created_by = v_uid;
  update public.checklist_templates set created_by = null where created_by = v_uid;
  update public.checklist_completions set completed_by = null where completed_by = v_uid;
  update public.incidents set reported_by = null where reported_by = v_uid;
  update public.incidents set resolved_by = null where resolved_by = v_uid;
  update public.incident_attachments set uploaded_by = null where uploaded_by = v_uid;
  update public.ai_usage_events set user_id = null where user_id = v_uid;
  update public.invites set invited_by = null where invited_by = v_uid;
  update public.inventory_items set updated_by = null where updated_by = v_uid;
  update public.shifts set staff_id = null where staff_id = v_uid;
  update public.shifts set created_by = null where created_by = v_uid;
  update public.payroll_connections set connected_by = null where connected_by = v_uid;
  update public.events set created_by = null where created_by = v_uid;
  update public.documents set uploaded_by = null where uploaded_by = v_uid;
  update public.pos_schedule_versions set published_by = null where published_by = v_uid;
  update public.pos_audit_events set actor_id = null where actor_id = v_uid;

  update public.staff_requests set reviewer_id = null where reviewer_id = v_uid;
  update public.shift_insights set created_by = null where created_by = v_uid;
  update public.crm_activity_log set actor_id = null where actor_id = v_uid;
  update public.crm_beos set assigned_rep_id = null where assigned_rep_id = v_uid;
  update public.crm_leads set assigned_to = null where assigned_to = v_uid;
  update public.crm_notes set author_id = null where author_id = v_uid;
  update public.messages set sender_id = null where sender_id = v_uid;
  update public.reservations set assigned_to = null where assigned_to = v_uid;

  delete from public.shift_swaps where requested_by = v_uid;
  update public.shift_swaps set offered_to = null where offered_to = v_uid;
  update public.shift_swaps set accepted_by = null where accepted_by = v_uid;
  delete from public.pos_employee_mappings where staff_id = v_uid;
  delete from public.staff_requests where user_id = v_uid;

  delete from public.push_tokens where user_id = v_uid;
  delete from public.device_attestations where user_id = v_uid;
  delete from public.attestation_challenges where user_id = v_uid;
  delete from public.notification_events where target_user_id = v_uid;
  delete from public.conversation_members where user_id = v_uid;
  delete from public.conversation_reads where user_id = v_uid;

  update public.audit_log
     set metadata = metadata
       || case when metadata ? 'before' then jsonb_build_object('before', (metadata -> 'before') - 'user_id') else '{}'::jsonb end
       || case when metadata ? 'after' then jsonb_build_object('after', (metadata -> 'after') - 'user_id') else '{}'::jsonb end
   where action in ('time_entry.correct', 'time_entry.void')
     and (
       metadata -> 'before' ->> 'user_id' = v_uid::text
       or target_id in (select te.id from public.time_entries te where te.user_id = v_uid)
     );
  update public.audit_log set metadata = metadata - 'user_id' - 'new_owner_user_id'
   where (metadata ->> 'user_id' = v_uid::text or metadata ->> 'new_owner_user_id' = v_uid::text);

  delete from public.time_entries where user_id = v_uid;
  delete from public.memberships where user_id = v_uid;
  delete from public.employee_hr_profiles where user_id = v_uid;
  delete from public.staff_photos where user_id = v_uid;
  delete from public.profiles where id = v_uid;

  insert into public.audit_log (actor_user_id, action, target_table, target_id, metadata)
  values (null, 'account.delete_requested', 'auth.users', v_uid, jsonb_build_object('reason', p_reason));

  select id into v_job_id
  from public.account_deletion_jobs
  where user_id = v_uid and status not in ('completed', 'dead')
  order by created_at
  limit 1;

  if v_job_id is null then
    insert into public.account_deletion_jobs (user_id, requested_reason)
    values (v_uid, p_reason)
    returning id into v_job_id;
  end if;

  perform app_hidden.close_privilege_gate('account_deletion');

  perform app_hidden.dispatch_account_deletion_job(v_job_id);

  return v_job_id;
end;
$function$;

-- =============================================================================
-- M5: pos_checks.guest_id + erase_guest scrub by stable id
-- =============================================================================
alter table public.pos_checks
  add column if not exists guest_id uuid references public.guests(id) on delete set null;

create index if not exists pos_checks_guest_id_idx on public.pos_checks (guest_id);

create or replace function app_hidden.guard_pos_check_guest_venue()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.guest_id is null then
    return new;
  end if;
  if not exists (
    select 1 from public.guests g
    where g.id = new.guest_id and g.venue_id = new.venue_id
  ) then
    raise exception 'guest must belong to the same venue as the POS check' using errcode = '23503';
  end if;
  return new;
end;
$$;

drop trigger if exists guard_pos_check_guest_venue on public.pos_checks;
create trigger guard_pos_check_guest_venue
  before insert or update of guest_id, venue_id on public.pos_checks
  for each row execute function app_hidden.guard_pos_check_guest_venue();

revoke select on public.pos_checks from authenticated;
grant select (
  id, organization_id, venue_id, pos_connection_id, provider, external_check_id, table_label,
  server_name, guest_name, guest_id, guest_count, opened_at, closed_at, subtotal_cents, tax_cents,
  tip_cents, total_cents, status, menu_items, created_at, updated_at
) on public.pos_checks to authenticated;

create or replace function app_hidden.guard_pos_check_final_state()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.venue_id is distinct from old.venue_id then
    raise exception 'venue_id cannot be modified once set' using errcode = '42501';
  end if;
  if new.organization_id is distinct from old.organization_id then
    raise exception 'organization_id cannot be modified once set' using errcode = '42501';
  end if;
  -- Retention / erasure: only guest PII / raw payload / guest_id may change on a finished check.
  if app_hidden.privilege_gate_is_open('pos_retention')
     and (to_jsonb(new) - 'raw_payload' - 'guest_name' - 'guest_id' - 'updated_at')
         = (to_jsonb(old) - 'raw_payload' - 'guest_name' - 'guest_id' - 'updated_at') then
    return new;
  end if;
  if old.status = 'voided' or (old.status = 'closed' and new.status <> 'voided') then
    return old;
  end if;
  return new;
end;
$$;

create or replace function public.erase_guest(p_guest_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_g public.guests;
  v_leads uuid[];
begin
  select * into v_g from public.guests where id = p_guest_id for update;
  if not found then
    raise exception 'guest not found' using errcode = 'P0002';
  end if;

  if auth.uid() is null or not app_hidden.has_venue_role(
    v_g.venue_id, array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
  ) then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  update public.reservations r
     set guest_name = 'Erased guest', guest_phone = null, guest_email = null
   where r.venue_id = v_g.venue_id
     and (
       r.guest_id = v_g.id
       or (v_g.phone is not null and r.guest_phone = v_g.phone)
       or (v_g.email is not null and lower(r.guest_email) = lower(v_g.email))
     );

  select coalesce(array_agg(l.id), '{}') into v_leads
  from public.crm_leads l
  where l.venue_id = v_g.venue_id
    and (
      l.guest_id = v_g.id
      or (v_g.phone is not null and l.phone = v_g.phone)
      or (v_g.email is not null and lower(l.email) = lower(v_g.email))
    );

  delete from public.crm_notes where lead_id = any (v_leads);
  delete from public.crm_activity_log where lead_id = any (v_leads);
  update public.crm_leads
     set full_name = 'Erased lead', email = null, phone = null, company = null,
         tags = '{}', marketing_opt_in = false, deleted_at = coalesce(deleted_at, now())
   where id = any (v_leads);

  delete from public.guest_household_links where from_guest_id = v_g.id or to_guest_id = v_g.id;

  perform app_hidden.open_privilege_gate('pos_retention');
  update public.pos_checks
     set guest_name = null, raw_payload = null, guest_id = null
   where venue_id = v_g.venue_id and guest_id = v_g.id;
  perform app_hidden.close_privilege_gate('pos_retention');

  delete from public.guests where id = v_g.id;

  perform app_hidden.audit_event(
    v_g.organization_id, v_g.venue_id, 'guest.erase', 'guests', v_g.id,
    jsonb_build_object('leads_anonymized', coalesce(array_length(v_leads, 1), 0))
  );
end;
$$;

revoke all on function public.erase_guest(uuid) from public, anon;
grant execute on function public.erase_guest(uuid) to authenticated;

-- =============================================================================
-- M1 + M2: accept_invite / revoke_invite / invite status trigger
-- =============================================================================
create or replace function app_hidden.enforce_invite_revoke_only()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if app_hidden.account_deletion_in_progress() then
    return new;
  end if;

  if old.status <> 'pending' then
    raise exception 'invites can only move from pending to revoked or accepted' using errcode = '42501';
  end if;

  if new.status = 'revoked' then
    null; -- managers (RLS) or revoke_invite
  elsif new.status = 'accepted' then
    if not app_hidden.privilege_gate_is_open('invite_accept') then
      raise exception 'invites are accepted through accept_invite' using errcode = '42501';
    end if;
  else
    raise exception 'invites can only move from pending to revoked or accepted' using errcode = '42501';
  end if;

  if new.organization_id is distinct from old.organization_id
    or new.venue_id is distinct from old.venue_id
    or new.email is distinct from old.email
    or new.role is distinct from old.role
    or new.invited_by is distinct from old.invited_by
    or new.created_at is distinct from old.created_at
    or new.expires_at is distinct from old.expires_at
  then
    raise exception 'only an invite''s status may be changed' using errcode = '42501';
  end if;
  return new;
end;
$$;

create or replace function public.accept_invite(p_invite_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_email text;
  v_invite public.invites;
  v_role public.app_role;
begin
  if auth.uid() is null then
    raise exception 'Must be signed in' using errcode = '42501';
  end if;

  if exists (
    select 1 from public.account_deletion_jobs j
    where j.user_id = auth.uid() and j.status in ('pending', 'processing')
  ) then
    raise exception 'This account is being deleted' using errcode = '42501';
  end if;

  select lower(u.email) into v_email from auth.users u
  where u.id = auth.uid() and u.email_confirmed_at is not null;
  if v_email is null then
    raise exception 'email_not_verified' using errcode = '42501';
  end if;

  select * into v_invite from public.invites where id = p_invite_id for update;
  if not found or lower(v_invite.email) <> v_email then
    raise exception 'invite_not_found' using errcode = 'P0002';
  end if;
  if v_invite.status <> 'pending' or v_invite.expires_at <= now() then
    raise exception 'invite_not_pending' using errcode = 'P0001';
  end if;

  insert into public.memberships (user_id, organization_id, venue_id, role, created_by)
  values (auth.uid(), v_invite.organization_id, v_invite.venue_id, v_invite.role, v_invite.invited_by)
  on conflict (user_id, organization_id, venue_id) do update
    set role = excluded.role;

  select m.role into v_role
  from public.memberships m
  where m.user_id = auth.uid()
    and m.organization_id = v_invite.organization_id
    and m.venue_id is not distinct from v_invite.venue_id;

  if v_role is distinct from v_invite.role then
    raise exception 'membership_role_mismatch' using errcode = 'P0001';
  end if;

  perform app_hidden.open_privilege_gate('invite_accept');
  update public.invites set status = 'accepted' where id = v_invite.id;
  perform app_hidden.close_privilege_gate('invite_accept');

  perform app_hidden.audit_event(
    v_invite.organization_id, v_invite.venue_id, 'invite.accept', 'invites', v_invite.id,
    jsonb_build_object('role', v_invite.role)
  );
end;
$$;

revoke all on function public.accept_invite(uuid) from public, anon;
grant execute on function public.accept_invite(uuid) to authenticated;

create or replace function public.revoke_invite(p_invite_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_invite public.invites;
begin
  if auth.uid() is null then
    raise exception 'Must be signed in' using errcode = '42501';
  end if;

  select * into v_invite from public.invites where id = p_invite_id for update;
  if not found then
    raise exception 'invite_not_found' using errcode = 'P0002';
  end if;

  if not app_hidden.has_venue_role(
    v_invite.venue_id,
    array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
  ) then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  if v_invite.status <> 'pending' then
    raise exception 'invite_not_pending' using errcode = 'P0001';
  end if;

  update public.invites set status = 'revoked' where id = v_invite.id;

  perform app_hidden.audit_event(
    v_invite.organization_id, v_invite.venue_id, 'invite.revoke', 'invites', v_invite.id,
    jsonb_build_object('email', v_invite.email, 'role', v_invite.role)
  );
end;
$$;

revoke all on function public.revoke_invite(uuid) from public, anon;
grant execute on function public.revoke_invite(uuid) to authenticated;

-- =============================================================================
-- M7: freeze immutable shift_swap columns for managers too
-- =============================================================================
CREATE OR REPLACE FUNCTION app_hidden.enforce_shift_swap_update()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if app_hidden.account_deletion_in_progress() then
    return new;
  end if;

  -- Immutable columns are frozen for everyone, including managers.
  if new.organization_id is distinct from old.organization_id
    or new.venue_id is distinct from old.venue_id
    or new.shift_id is distinct from old.shift_id
    or new.requested_by is distinct from old.requested_by
    or new.offered_to is distinct from old.offered_to
    or new.created_at is distinct from old.created_at
  then
    raise exception 'only a swap request''s status and accepted_by may change' using errcode = '42501';
  end if;

  if app_hidden.has_venue_role(
    new.venue_id,
    array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
  ) then
    return new;
  end if;

  if old.status <> 'pending' then
    raise exception 'this swap request is no longer pending' using errcode = '42501';
  end if;

  if auth.uid() = old.requested_by then
    if new.status <> 'cancelled' then
      raise exception 'the requester may only cancel their own swap request' using errcode = '42501';
    end if;
  else
    if new.status <> 'accepted' or new.accepted_by is distinct from auth.uid() then
      raise exception 'you may only accept this swap request as yourself' using errcode = '42501';
    end if;
    if old.offered_to is not null and old.offered_to <> auth.uid() then
      raise exception 'this swap request was offered to someone else' using errcode = '42501';
    end if;
  end if;

  return new;
end;
$function$;

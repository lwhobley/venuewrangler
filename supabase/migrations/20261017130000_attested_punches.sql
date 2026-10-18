-- Attested time punches (audit F-01 / D-13). Until now the geofence, accuracy and "mocked" checks
-- ran on numbers the client reported, so anyone with the API (or a browser's DevTools sensors)
-- could clock in from home. This adds the server side of a proof-of-device punch:
--
--   * the `time-clock-punch` Edge Function verifies a per-request App Attest assertion (iOS) or
--     Play Integrity token (Android) whose hash covers the exact punch payload and a single-use
--     server nonce, then records the punch through record_attested_punch();
--   * time_entries remembers whether each end of a punch was attested (clock_in_attested /
--     clock_out_attested) so managers can review unattested punches;
--   * platform_settings.require_attested_punches (default OFF) makes the database refuse
--     self-recorded punches that did not come through the function. Turn it on only once the
--     app builds that implement the client side are the minimum supported versions.

alter table app_hidden.platform_settings
  add column if not exists require_attested_punches boolean not null default false;

alter table public.time_entries
  add column if not exists clock_in_attested boolean not null default false,
  add column if not exists clock_out_attested boolean not null default false,
  add column if not exists punch_source text not null default 'direct'
    check (punch_source in ('direct', 'attested'));

-- Attested device keys (App Attest public keys + assertion counters). Written and read only by
-- the Edge Functions (service role).
create table if not exists public.device_attestation_keys (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  platform text not null check (platform in ('ios', 'android')),
  key_id text not null check (char_length(key_id) between 1 and 200),
  public_key_spki text not null,
  counter bigint not null default 0 check (counter >= 0),
  attested_at timestamptz not null default now(),
  last_used_at timestamptz,
  revoked_at timestamptz,
  unique (user_id, platform, key_id)
);
alter table public.device_attestation_keys enable row level security;
alter table public.device_attestation_keys force row level security;
revoke all on public.device_attestation_keys from public, anon, authenticated;
grant select, insert, update, delete on public.device_attestation_keys to service_role;

-- Single-use, short-lived server nonces that bind a punch to one request.
create table if not exists public.punch_nonces (
  nonce_hash text primary key check (char_length(nonce_hash) = 64),
  user_id uuid not null references auth.users (id) on delete cascade,
  expires_at timestamptz not null,
  consumed_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists punch_nonces_expires_at_idx on public.punch_nonces (expires_at);
alter table public.punch_nonces enable row level security;
alter table public.punch_nonces force row level security;
revoke all on public.punch_nonces from public, anon, authenticated;
grant select, insert, update, delete on public.punch_nonces to service_role;

create or replace function public.issue_punch_nonce(p_user_id uuid, p_nonce_hash text, p_ttl_seconds integer default 120)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  delete from public.punch_nonces where expires_at < now() - interval '1 day';
  insert into public.punch_nonces (nonce_hash, user_id, expires_at)
  values (p_nonce_hash, p_user_id, now() + make_interval(secs => least(greatest(p_ttl_seconds, 10), 600)));
end;
$$;

create or replace function public.consume_punch_nonce(p_user_id uuid, p_nonce_hash text)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id text;
begin
  update public.punch_nonces
     set consumed_at = now()
   where nonce_hash = p_nonce_hash and user_id = p_user_id
     and consumed_at is null and expires_at > now()
  returning nonce_hash into v_id;
  return v_id is not null;
end;
$$;

create or replace function public.register_attestation_key(
  p_user_id uuid, p_platform text, p_key_id text, p_public_key_spki text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  -- Re-attesting an existing key refreshes the stored public key but NEVER lowers the counter:
  -- resetting it would reopen replay of earlier assertions.
  insert into public.device_attestation_keys (user_id, platform, key_id, public_key_spki)
  values (p_user_id, p_platform, p_key_id, p_public_key_spki)
  on conflict (user_id, platform, key_id)
  do update set public_key_spki = excluded.public_key_spki, revoked_at = null;
end;
$$;

-- Assertion counters must strictly increase; the compare-and-set makes a replay lose the race.
create or replace function public.advance_attestation_counter(
  p_user_id uuid, p_platform text, p_key_id text, p_counter bigint
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  update public.device_attestation_keys
     set counter = p_counter, last_used_at = now()
   where user_id = p_user_id and platform = p_platform and key_id = p_key_id
     and revoked_at is null and counter < p_counter
  returning id into v_id;
  return v_id is not null;
end;
$$;

-- Records a punch on behalf of a user whose request the Edge Function has verified. The caller
-- (service role) has no end-user JWT, so the function impersonates the user for this transaction
-- (auth.uid() reads request.jwt.claim.sub) and flags the statement as attested for the triggers.
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
  perform set_config('app.attested_punch', case when p_attested then 'on' else 'off' end, true);

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
      perform set_config('app.attested_punch', 'off', true);
      raise exception 'no open punch to close' using errcode = 'P0002';
    end if;
  end if;

  perform set_config('app.attested_punch', 'off', true);
  return v_entry;
end;
$$;

revoke all on function public.issue_punch_nonce(uuid, text, integer) from public, anon, authenticated;
revoke all on function public.consume_punch_nonce(uuid, text) from public, anon, authenticated;
revoke all on function public.register_attestation_key(uuid, text, text, text) from public, anon, authenticated;
revoke all on function public.advance_attestation_counter(uuid, text, text, bigint) from public, anon, authenticated;
revoke all on function public.record_attested_punch(uuid, uuid, text, double precision, double precision, double precision, boolean, boolean) from public, anon, authenticated;
grant execute on function public.issue_punch_nonce(uuid, text, integer) to service_role;
grant execute on function public.consume_punch_nonce(uuid, text) to service_role;
grant execute on function public.register_attestation_key(uuid, text, text, text) to service_role;
grant execute on function public.advance_attestation_counter(uuid, text, text, bigint) to service_role;
grant execute on function public.record_attested_punch(uuid, uuid, text, double precision, double precision, double precision, boolean, boolean) to service_role;

-- -----------------------------------------------------------------------------
-- Triggers: stamp attestation state (never client-controlled) and optionally require it.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION app_hidden.prepare_time_entry_insert()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_attested boolean := coalesce(current_setting('app.attested_punch', true), '') = 'on';
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

  -- A manager may record a punch for someone else only if that person belongs to this
  -- venue (venue-level row) or organization (org-level row).
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

  -- Always server time: a supplied clock_in_at is never trusted, including from managers
  -- recording a walk-in punch for someone else. Backdated corrections go through
  -- public.correct_time_entry instead, where they're audited.
  new.clock_in_at := now();
  new.is_open := true;
  new.clock_out_at := null;

  -- Attestation state is stamped here and never taken from the client. Self-recorded punches
  -- (the user is the actor) must be attested once platform_settings.require_attested_punches is
  -- on; managers recording a walk-in punch for someone else are exempt.
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

  -- Geofence check
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

  -- Anti-replay check against punches from earlier venue-local calendar days. The boundary
  -- is venue-local midnight as a timestamptz, not a session-timezone-dependent comparison.
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


CREATE OR REPLACE FUNCTION app_hidden.enforce_time_entry_update()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_attested boolean := coalesce(current_setting('app.attested_punch', true), '') = 'on';
  v_venue record;
  v_dist double precision;
  v_correcting boolean := coalesce(current_setting('app.time_entry_correction', true), '') = 'on';
  v_old_breaks jsonb := coalesce(old.breaks, '[]'::jsonb);
  v_new_breaks jsonb := coalesce(new.breaks, '[]'::jsonb);
  v_old_len int := jsonb_array_length(v_old_breaks);
  v_new_len int := jsonb_array_length(v_new_breaks);
  v_changed boolean;
  i int;
  v_last jsonb;
begin
  if coalesce(current_setting('app.gps_purge', true), '') = 'on'
     and (to_jsonb(new) - 'clock_in_lat' - 'clock_in_lng' - 'clock_in_accuracy_m' - 'clock_out_lat' - 'clock_out_lng' - 'clock_out_accuracy_m' - 'updated_at')
         = (to_jsonb(old) - 'clock_in_lat' - 'clock_in_lng' - 'clock_in_accuracy_m' - 'clock_out_lat' - 'clock_out_lng' - 'clock_out_accuracy_m' - 'updated_at') then
    return new;
  end if;

  -- Attestation columns are server-stamped: a client update can never change them (the close
  -- below sets clock_out_attested from the verified request flag).
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

    -- Staff must close with a location fix, as they must clock in with one. Managers closing
    -- an entry for a team member (remote close) are exempt, as before.
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
        -- Still open: the new break stays open until it is explicitly closed.
        v_new_breaks := jsonb_set(v_new_breaks, array[(v_new_len - 1)::text, 'end_at'], 'null'::jsonb);
      else
        -- Clock-out with an appended break: close it at server time instead of reopening it.
        -- The start is server-forced to now(), so a client end time earlier than that would
        -- yield negative paid time; server time is used in its place.
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


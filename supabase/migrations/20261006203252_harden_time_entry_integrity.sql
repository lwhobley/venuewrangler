-- Fixes a P1 finding: an authenticated employee could backdate a clock-in, submit a
-- future clock-out, edit a closed punch, reopen a closed punch, or rewrite `breaks` to
-- remove unpaid time — because the insert/close triggers preserved client-supplied
-- timestamps (`coalesce(new.x, now())`) and the update trigger only validated the single
-- "close" transition, leaving every other update (including to a closed row) unchecked.
--
-- New rules, enforced in the triggers below (not just the policy):
--   - clock_in_at is always server time; a client-supplied value is ignored.
--   - clock_out_at is always server time when self-service closes a punch.
--   - A closed entry (is_open = false) is fully immutable to ordinary UPDATEs. Managers
--     correct a closed punch only via public.correct_time_entry, which is audited.
--   - `breaks` may only be changed while the entry is open, and only by appending a new
--     open break (start forced to now()) or closing the single open break (end forced to
--     now()). Historical break rows can't be edited, reordered or removed, and no second
--     break may be open at once.
--   - Reopening a closed entry (is_open false -> true) is rejected outright.

-- A manager-run, audited correction path for closed entries (backdated punches, break
-- disputes, etc.) that the generic trigger above does not allow. SECURITY DEFINER so it can
-- set the session flag the trigger checks; permission is still re-checked inside.
create or replace function public.correct_time_entry(
  p_entry_id uuid,
  p_clock_out_at timestamptz default null,
  p_breaks jsonb default null,
  p_reason text default null
) returns public.time_entries
language plpgsql
security definer
set search_path = public
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

  v_before := to_jsonb(v_entry);

  -- Lets this one statement through the otherwise-blanket "closed entries are immutable"
  -- and breaks-validation rules in app_hidden.enforce_time_entry_update, for this
  -- transaction only.
  perform set_config('app.time_entry_correction', 'on', true);

  update public.time_entries
  set
    clock_out_at = coalesce(p_clock_out_at, clock_out_at),
    is_open = case when p_clock_out_at is not null then false else is_open end,
    breaks = coalesce(p_breaks, breaks)
  where id = p_entry_id
  returning * into v_entry;

  insert into public.audit_log (
    organization_id, venue_id, actor_user_id, action, target_table, target_id, metadata
  ) values (
    v_entry.organization_id, v_entry.venue_id, auth.uid(), 'time_entry.correct',
    'time_entries', v_entry.id,
    jsonb_build_object('before', v_before, 'after', to_jsonb(v_entry), 'reason', p_reason)
  );

  return v_entry;
end;
$$;

revoke execute on function public.correct_time_entry(uuid, timestamptz, jsonb, text) from public, anon;
grant execute on function public.correct_time_entry(uuid, timestamptz, jsonb, text) to authenticated;

create or replace function app_hidden.prepare_time_entry_insert()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
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

  -- Always server time: a supplied clock_in_at is never trusted, including from managers
  -- recording a walk-in punch for someone else. Backdated corrections go through
  -- public.correct_time_entry instead, where they're audited.
  new.clock_in_at := now();
  new.is_open := true;
  new.clock_out_at := null;

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

  -- Anti-replay check against punches from earlier calendar days
  select clock_in_lat, clock_in_lng, clock_in_accuracy_m
  into v_prior_match
  from public.time_entries
  where user_id = new.user_id
    and clock_in_at < date_trunc('day', now() at time zone coalesce(v_venue.timezone, 'UTC'))
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
$$;

create or replace function app_hidden.enforce_time_entry_update()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_venue record;
  v_dist double precision;
  v_correcting boolean := coalesce(current_setting('app.time_entry_correction', true), '') = 'on';
  v_old_breaks jsonb := coalesce(old.breaks, '[]'::jsonb);
  v_new_breaks jsonb := coalesce(new.breaks, '[]'::jsonb);
  v_old_len int := jsonb_array_length(v_old_breaks);
  v_new_len int := jsonb_array_length(v_new_breaks);
  i int;
  v_last jsonb;
begin
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
    -- public.correct_time_entry already checked the manager role and will audit-log this
    -- statement; skip the self-service rules below.
    new.updated_at := now();
    return new;
  end if;

  if not old.is_open then
    -- A closed punch is immutable outside the audited manager-correction path.
    raise exception 'this time entry is closed; use a manager correction to change it'
      using errcode = '42501';
  end if;

  if not new.is_open then
    -- Closing transition: ignore whatever clock_out_at the client sent.
    new.clock_out_at := now();

    if new.clock_out_mocked then
      raise exception 'Mocked locations are not allowed' using errcode = '42501';
    end if;

    if new.clock_out_accuracy_m is not null and new.clock_out_accuracy_m > 50.0 then
      raise exception 'Location accuracy must be 50m or better' using errcode = '42501';
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

    -- A break still open at clock-out is force-closed server-side rather than trusted
    -- from the client, same as a plain break-close (see below).
    if v_new_len > 0 then
      v_last := v_new_breaks -> (v_new_len - 1);
      if (v_last ? 'end_at') = false or v_last -> 'end_at' = 'null'::jsonb then
        v_new_breaks := jsonb_set(v_new_breaks, array[(v_new_len - 1)::text, 'end_at'], to_jsonb(now()));
      end if;
    end if;
  end if;

  -- `breaks`: append-only. The client may only (a) append one new open break, with its
  -- start forced to now(), or (b) close the single currently-open break, with its end
  -- forced to now(). Historical entries must match byte-for-byte.
  if v_new_breaks is distinct from v_old_breaks then
    if v_new_len = v_old_len and v_new_len > 0 then
      -- Closing the last (and only allowed-open) break.
      for i in 0 .. v_old_len - 2 loop
        if v_new_breaks -> i is distinct from v_old_breaks -> i then
          raise exception 'historical breaks cannot be modified' using errcode = '42501';
        end if;
      end loop;
      if (v_old_breaks -> (v_old_len - 1) -> 'end_at') is not null
         and (v_old_breaks -> (v_old_len - 1) -> 'end_at') <> 'null'::jsonb then
        raise exception 'no open break to close' using errcode = '42501';
      end if;
      v_new_breaks := jsonb_set(v_new_breaks, array[(v_new_len - 1)::text, 'end_at'], to_jsonb(now()));
      if (v_new_breaks -> (v_new_len - 1)) - 'end_at' is distinct from (v_old_breaks -> (v_old_len - 1)) - 'end_at' then
        raise exception 'only a break''s end time may be set' using errcode = '42501';
      end if;
    elsif v_new_len = v_old_len + 1 then
      -- Appending a new open break.
      for i in 0 .. v_old_len - 1 loop
        if v_new_breaks -> i is distinct from v_old_breaks -> i then
          raise exception 'historical breaks cannot be modified' using errcode = '42501';
        end if;
      end loop;
      if v_old_len > 0
         and ((v_old_breaks -> (v_old_len - 1) -> 'end_at') is null
              or (v_old_breaks -> (v_old_len - 1) -> 'end_at') = 'null'::jsonb) then
        raise exception 'a break is already open' using errcode = '42501';
      end if;
      v_new_breaks := jsonb_set(v_new_breaks, array[(v_new_len - 1)::text, 'start_at'], to_jsonb(now()));
      v_new_breaks := jsonb_set(v_new_breaks, array[(v_new_len - 1)::text, 'end_at'], 'null'::jsonb);
    else
      raise exception 'breaks can only be appended to or have their open entry closed'
        using errcode = '42501';
    end if;
    new.breaks := v_new_breaks;
  end if;

  new.updated_at := now();
  return new;
end;
$$;

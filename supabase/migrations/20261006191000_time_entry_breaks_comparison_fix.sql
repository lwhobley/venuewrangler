-- Follow-up to 20261006190000_harden_time_entry_integrity.sql: comparing historical break
-- elements with raw JSONB equality (`a -> i is distinct from b -> i`) is exact-text, so a
-- client that re-serializes an unchanged timestamp slightly differently (different
-- microsecond padding, offset notation, etc. — routine when round-tripping through
-- DateTime.parse/toIso8601String on the Flutter side) would be wrongly rejected as "editing
-- history". Compare by parsed value (type as text, start_at/end_at as timestamptz) instead.

create or replace function app_hidden.break_entries_equal(a jsonb, b jsonb)
returns boolean
language sql
immutable
as $$
  select
    (a ->> 'type') is not distinct from (b ->> 'type')
    and (a ->> 'start_at')::timestamptz is not distinct from (b ->> 'start_at')::timestamptz
    and (a ->> 'end_at')::timestamptz is not distinct from (b ->> 'end_at')::timestamptz
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
  v_changed boolean;
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
    new.updated_at := now();
    return new;
  end if;

  if not old.is_open then
    raise exception 'this time entry is closed; use a manager correction to change it'
      using errcode = '42501';
  end if;

  if not new.is_open then
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

    -- Re-derive v_new_breaks from whatever the client sent (possibly unchanged from old),
    -- force-closing a still-open break at clock-out time rather than trusting the client.
    v_new_breaks := coalesce(new.breaks, '[]'::jsonb);
    v_new_len := jsonb_array_length(v_new_breaks);
    if v_new_len > 0 then
      v_last := v_new_breaks -> (v_new_len - 1);
      if (v_last ? 'end_at') = false or v_last -> 'end_at' = 'null'::jsonb then
        v_new_breaks := jsonb_set(v_new_breaks, array[(v_new_len - 1)::text, 'end_at'], to_jsonb(now()));
      end if;
    end if;
  end if;

  -- `breaks`: append-only, compared by parsed value (see app_hidden.break_entries_equal).
  -- The client may only (a) append one new open break, with its start forced to now(), or
  -- (b) close the single currently-open break, with its end forced to now().
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
      if (v_new_breaks -> (v_old_len - 1) ->> 'type')
           is distinct from (v_old_breaks -> (v_old_len - 1) ->> 'type')
         or (v_new_breaks -> (v_old_len - 1) ->> 'start_at')::timestamptz
           is distinct from (v_old_breaks -> (v_old_len - 1) ->> 'start_at')::timestamptz
      then
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
      v_new_breaks := jsonb_set(v_new_breaks, array[(v_new_len - 1)::text, 'end_at'], 'null'::jsonb);
    else
      raise exception 'breaks can only be appended to or have their open entry closed'
        using errcode = '42501';
    end if;
  end if;
  new.breaks := v_new_breaks;

  new.updated_at := now();
  return new;
end;
$$;

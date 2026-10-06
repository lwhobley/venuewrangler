-- app_hidden.break_entries_equal cast its `start_at`/`end_at` text straight to timestamptz,
-- so a client sending non-timestamp garbage (or a now-forbidden mutation that happens to
-- include one) raised a raw Postgres cast error (22007) instead of the same clean 42501
-- every other rejection in this trigger uses. Garbage input should just compare unequal —
-- the existing structural rules then reject it as "historical breaks cannot be modified"
-- or similar — not blow up with an unrelated error code.
create or replace function app_hidden.break_entries_equal(a jsonb, b jsonb)
returns boolean
language plpgsql
immutable
as $$
begin
  return
    (a ->> 'type') is not distinct from (b ->> 'type')
    and (a ->> 'start_at')::timestamptz is not distinct from (b ->> 'start_at')::timestamptz
    and (a ->> 'end_at')::timestamptz is not distinct from (b ->> 'end_at')::timestamptz;
exception
  when invalid_datetime_format or datetime_field_overflow then
    return false;
end;
$$;

-- Same safety for the one other place enforce_time_entry_update casts a client-supplied
-- start_at directly (checking that a break being closed didn't also get its start_at or
-- type changed).
create or replace function app_hidden.break_type_and_start_equal(a jsonb, b jsonb)
returns boolean
language plpgsql
immutable
as $$
begin
  return
    (a ->> 'type') is not distinct from (b ->> 'type')
    and (a ->> 'start_at')::timestamptz is not distinct from (b ->> 'start_at')::timestamptz;
exception
  when invalid_datetime_format or datetime_field_overflow then
    return false;
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

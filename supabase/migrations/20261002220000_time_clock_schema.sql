-- Phase 4 feature: Time clock with geofencing and anti-replay verification.
-- Extends venues with geofencing coordinates and introduces public.time_entries.
-- Haversine distance and anti-replay GPS fix verification run server-side in PostgreSQL.

-- 1. Extend venues table
alter table public.venues
  add column if not null latitude double precision check (latitude is null or (latitude >= -90 and latitude <= 90)),
  add column if not null longitude double precision check (longitude is null or (longitude >= -180 and longitude <= 180)),
  add column if not null geofence_radius_m integer not null default 100 check (geofence_radius_m > 0),
  add column if not null timezone text not null default 'UTC',
  add column if not null early_clock_in_window_min integer not null default 10 check (early_clock_in_window_min >= 0);

-- 2. Haversine distance function in metres
create or replace function app_hidden.haversine_distance_m(
  lat1 double precision,
  lng1 double precision,
  lat2 double precision,
  lng2 double precision
) returns double precision
language plpgsql
immutable
as $$
declare
  r double precision := 6371000.0; -- Earth radius in metres
  dlat double precision;
  dlng double precision;
  a double precision;
begin
  dlat := radians(lat2 - lat1);
  dlng := radians(lng2 - lng1);
  a := sin(dlat / 2.0)^2 + cos(radians(lat1)) * cos(radians(lat2)) * sin(dlng / 2.0)^2;
  return 2.0 * r * asin(least(1.0::double precision, sqrt(a)));
end;
$$;

-- 3. Time entries table
create table public.time_entries (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  venue_id uuid not null references public.venues (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  shift_id uuid references public.shifts (id) on delete set null,
  clock_in_at timestamptz not null default now(),
  clock_in_lat double precision not null check (clock_in_lat >= -90 and clock_in_lat <= 90),
  clock_in_lng double precision not null check (clock_in_lng >= -180 and clock_in_lng <= 180),
  clock_in_accuracy_m double precision not null check (clock_in_accuracy_m >= 0),
  clock_in_mocked boolean not null default false,
  clock_out_at timestamptz,
  clock_out_lat double precision check (clock_out_lat is null or (clock_out_lat >= -90 and clock_out_lat <= 90)),
  clock_out_lng double precision check (clock_out_lng is null or (clock_out_lng >= -180 and clock_out_lng <= 180)),
  clock_out_accuracy_m double precision check (clock_out_accuracy_m is null or clock_out_accuracy_m >= 0),
  clock_out_mocked boolean,
  is_open boolean not null default true,
  breaks jsonb not null default '[]'::jsonb,
  location_anomaly text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint time_entries_open_state_check check (
    (is_open = true and clock_out_at is null) or
    (is_open = false and clock_out_at is not null)
  ),
  constraint time_entries_clock_order_check check (
    clock_out_at is null or clock_out_at >= clock_in_at
  ),
  constraint time_entries_clock_in_not_mocked check (clock_in_mocked = false),
  constraint time_entries_clock_out_not_mocked check (clock_out_mocked is null or clock_out_mocked = false)
);

create unique index time_entries_one_open_per_user_idx
  on public.time_entries (user_id)
  where (is_open = true);

create index time_entries_venue_id_idx on public.time_entries (venue_id);
create index time_entries_organization_id_idx on public.time_entries (organization_id);
create index time_entries_user_id_idx on public.time_entries (user_id);
create index time_entries_shift_id_idx on public.time_entries (shift_id);
create index time_entries_clock_in_at_idx on public.time_entries (clock_in_at desc);

-- 4. Triggers
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

  new.clock_in_at := coalesce(new.clock_in_at, now());
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

create trigger prepare_time_entry_insert
  before insert on public.time_entries
  for each row execute function app_hidden.prepare_time_entry_insert();

create or replace function app_hidden.enforce_time_entry_update()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_venue record;
  v_dist double precision;
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

  select id, latitude, longitude, geofence_radius_m
  into v_venue
  from public.venues
  where id = new.venue_id;

  -- If closing punch, validate clock_out location
  if old.is_open and not new.is_open then
    new.clock_out_at := coalesce(new.clock_out_at, now());

    if new.clock_out_mocked then
      raise exception 'Mocked locations are not allowed' using errcode = '42501';
    end if;

    if new.clock_out_accuracy_m is not null and new.clock_out_accuracy_m > 50.0 then
      raise exception 'Location accuracy must be 50m or better' using errcode = '42501';
    end if;

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
  end if;

  new.updated_at := now();
  return new;
end;
$$;

create trigger enforce_time_entry_update
  before update on public.time_entries
  for each row execute function app_hidden.enforce_time_entry_update();

-- 5. Row Level Security
alter table public.time_entries enable row level security;
alter table public.time_entries force row level security;

create policy time_entries_select on public.time_entries
  for select to authenticated
  using (
    (user_id = auth.uid() and app_hidden.is_venue_member(venue_id))
    or app_hidden.has_venue_role(
      venue_id,
      array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
    )
  );

create policy time_entries_insert on public.time_entries
  for insert to authenticated
  with check (app_hidden.is_venue_member(venue_id));

create policy time_entries_update on public.time_entries
  for update to authenticated
  using (
    (user_id = auth.uid() and app_hidden.is_venue_member(venue_id))
    or app_hidden.has_venue_role(
      venue_id,
      array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
    )
  )
  with check (
    (user_id = auth.uid() and app_hidden.is_venue_member(venue_id))
    or app_hidden.has_venue_role(
      venue_id,
      array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
    )
  );

create policy time_entries_delete on public.time_entries
  for delete to authenticated
  using (
    app_hidden.has_venue_role(
      venue_id,
      array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
    )
  );

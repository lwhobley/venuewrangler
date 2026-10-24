-- Launch review S1, D1, U5 (time clock part of D6 is client-side only).
--
--   S1  New venues never had a location, so prepare_time_entry_insert skipped the geofence and
--       staff could clock in from anywhere. Managers now set the venue's location with
--       set_venue_location(), and a self-recorded clock-in at a venue with no location is
--       refused ("venue_location_required") instead of silently accepted. Clock-out is left
--       alone so an entry opened before this migration can still be closed.
--   D1  Managers can review hours and close missed clock-outs: venue_clock_board() (names, for
--       supervisors and up), venue_timesheet() (a date range of punches with names and their
--       correction history) and a stricter correct_time_entry() (a reason is required, and a
--       break left open is closed at the corrected clock-out).
--   U5  One name rule for every roster-style RPC: app_hidden.member_display_name() falls back
--       from the person's own display name to the name a manager typed in their staff profile
--       (preferred, then legal), then a name recorded on their accepted invite or at sign-up.

-- -----------------------------------------------------------------------------
-- 1. Venue address + set_venue_location (S1)
-- -----------------------------------------------------------------------------
alter table public.venues
  add column if not exists address text check (address is null or char_length(address) <= 300);

-- The existing location audit (20261017100000) now records the address as well.
drop trigger if exists audit_venue_location_change on public.venues;
create trigger audit_venue_location_change after update on public.venues
  for each row execute function app_hidden.audit_row_change(
    'venue', 'latitude', 'longitude', 'geofence_radius_m', 'timezone', 'address'
  );

-- True when the venue has a usable location. (0, 0) is the "never set" value some clients
-- wrote before this existed, so it counts as no location.
create or replace function app_hidden.venue_has_location(p_latitude double precision, p_longitude double precision)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select p_latitude is not null and p_longitude is not null
     and not (p_latitude = 0.0 and p_longitude = 0.0);
$$;

-- Venue managers set their own venue's location (the venues UPDATE policy is owner/admin
-- only, and it would let them change anything else on the row too). Audited by the trigger
-- above.
create or replace function public.set_venue_location(
  p_venue_id uuid,
  p_latitude double precision,
  p_longitude double precision,
  p_geofence_radius_m integer default 100,
  p_address text default null
)
returns public.venues
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_venue public.venues;
  v_address text := nullif(btrim(coalesce(p_address, '')), '');
begin
  if auth.uid() is null or not app_hidden.has_venue_role(
    p_venue_id,
    array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
  ) then
    raise exception 'forbidden: only managers can set the venue location' using errcode = '42501';
  end if;

  if p_latitude is null or p_longitude is null
     or p_latitude < -90 or p_latitude > 90 or p_longitude < -180 or p_longitude > 180
     or not app_hidden.venue_has_location(p_latitude, p_longitude) then
    raise exception 'invalid venue location' using errcode = '22023';
  end if;

  -- GPS fixes are accepted at up to 50 m accuracy, so a smaller fence would refuse good fixes;
  -- above 1 km the check stops meaning "on site".
  if p_geofence_radius_m is null or p_geofence_radius_m < 50 or p_geofence_radius_m > 1000 then
    raise exception 'geofence radius must be between 50 and 1000 metres' using errcode = '22023';
  end if;

  if v_address is not null and char_length(v_address) > 300 then
    raise exception 'address must be 300 characters or fewer' using errcode = '22023';
  end if;

  update public.venues
     set latitude = p_latitude,
         longitude = p_longitude,
         geofence_radius_m = p_geofence_radius_m,
         address = v_address
   where id = p_venue_id
  returning * into v_venue;

  return v_venue;
end;
$$;

revoke all on function public.set_venue_location(uuid, double precision, double precision, integer, text) from public, anon;
grant execute on function public.set_venue_location(uuid, double precision, double precision, integer, text) to authenticated;

-- -----------------------------------------------------------------------------
-- 2. Clock-in requires a venue location (S1). Same body as 20261017130000 except the geofence
-- block: a venue without a location now refuses self-recorded punches.
-- -----------------------------------------------------------------------------
create or replace function app_hidden.prepare_time_entry_insert()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
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

  if app_hidden.venue_has_location(v_venue.latitude, v_venue.longitude) then
    v_dist := app_hidden.haversine_distance_m(
      new.clock_in_lat,
      new.clock_in_lng,
      v_venue.latitude,
      v_venue.longitude
    );
    if v_dist > v_venue.geofence_radius_m then
      raise exception 'You are outside the venue geofence' using errcode = '42501';
    end if;
  elsif new.user_id is not distinct from auth.uid() then
    -- No location to check against: refuse rather than accept a punch from anywhere. A manager
    -- sets it with set_venue_location(); the app prompts them to.
    raise exception 'venue_location_required' using errcode = '42501';
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
$$;

-- -----------------------------------------------------------------------------
-- 3. correct_time_entry (D1): reason required; closing an entry also closes its open break.
-- Same checks and audit record as 20261017100000 otherwise.
-- -----------------------------------------------------------------------------
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
  v_reason text := btrim(coalesce(p_reason, ''));
  v_breaks jsonb := p_breaks;
begin
  select * into v_entry from public.time_entries where id = p_entry_id for update;
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

  if char_length(v_reason) < 3 or char_length(v_reason) > 500 then
    raise exception 'a reason of 3-500 characters is required' using errcode = '22023';
  end if;

  if p_clock_out_at is null and p_breaks is null then
    raise exception 'nothing to correct' using errcode = '22023';
  end if;

  if p_clock_out_at is not null then
    if p_clock_out_at <= v_entry.clock_in_at then
      raise exception 'clock-out must be after clock-in' using errcode = '22023';
    end if;
    if p_clock_out_at > now() + interval '1 minute' then
      raise exception 'clock-out cannot be in the future' using errcode = '22023';
    end if;

    -- A break still open when the person forgot to clock out ends at the corrected clock-out
    -- (or at its own start, if it began later), so unpaid time stops counting.
    if v_breaks is null then
      select coalesce(jsonb_agg(
               case
                 when b ->> 'end_at' is null then
                   jsonb_set(b, '{end_at}', to_jsonb(greatest((b ->> 'start_at')::timestamptz, p_clock_out_at)))
                 else b
               end
               order by ord
             ), '[]'::jsonb)
        into v_breaks
        from jsonb_array_elements(coalesce(v_entry.breaks, '[]'::jsonb)) with ordinality as t(b, ord);
    end if;
  end if;

  if v_breaks is not null and jsonb_typeof(v_breaks) <> 'array' then
    raise exception 'breaks must be an array' using errcode = '22023';
  end if;

  v_before := app_hidden.scrub_time_entry_json(to_jsonb(v_entry));

  -- Lets this one statement through the otherwise-blanket "closed entries are immutable"
  -- and breaks-validation rules in app_hidden.enforce_time_entry_update, for this
  -- transaction only.
  perform set_config('app.time_entry_correction', 'on', true);

  update public.time_entries
  set
    clock_out_at = coalesce(p_clock_out_at, clock_out_at),
    is_open = case when p_clock_out_at is not null then false else is_open end,
    breaks = coalesce(v_breaks, breaks)
  where id = p_entry_id
  returning * into v_entry;

  -- Reset immediately so the bypass cannot outlive this statement within the transaction.
  perform set_config('app.time_entry_correction', 'off', true);

  insert into public.audit_log (
    organization_id, venue_id, actor_user_id, action, target_table, target_id, metadata
  ) values (
    v_entry.organization_id, v_entry.venue_id, auth.uid(), 'time_entry.correct',
    'time_entries', v_entry.id,
    jsonb_build_object(
      'before', v_before,
      'after', app_hidden.scrub_time_entry_json(to_jsonb(v_entry)),
      'reason', v_reason
    )
  );

  return v_entry;
end;
$$;

revoke all on function public.correct_time_entry(uuid, timestamptz, jsonb, text) from public, anon;
grant execute on function public.correct_time_entry(uuid, timestamptz, jsonb, text) to authenticated;

-- -----------------------------------------------------------------------------
-- 4. One name rule (U5).
-- -----------------------------------------------------------------------------
-- The name to show for [p_user_id] at [p_venue_id], or null when nobody has recorded one:
--   1. their own display name (profiles), which they control;
--   2. the name a manager entered in their staff profile at this venue (preferred, then legal);
--   3. the same from a staff profile at another venue of the organization;
--   4. a name recorded on their accepted invite to this venue, or in their sign-up metadata.
-- Invites and sign-up metadata are read by key (to_jsonb), so a name column added there
-- later is picked up without changing this function.
create or replace function app_hidden.member_display_name(p_venue_id uuid, p_user_id uuid)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_name text;
  v_org uuid;
  v_email text;
  v_meta jsonb;
begin
  select nullif(btrim(p.display_name), '') into v_name from public.profiles p where p.id = p_user_id;
  if v_name is not null then
    return v_name;
  end if;

  select coalesce(nullif(btrim(h.preferred_name), ''), nullif(btrim(h.legal_name), ''))
    into v_name
    from public.employee_hr_profiles h
   where h.venue_id = p_venue_id and h.user_id = p_user_id;
  if v_name is not null then
    return v_name;
  end if;

  select v.organization_id into v_org from public.venues v where v.id = p_venue_id;

  select coalesce(nullif(btrim(h.preferred_name), ''), nullif(btrim(h.legal_name), ''))
    into v_name
    from public.employee_hr_profiles h
    join public.venues v on v.id = h.venue_id
   where h.user_id = p_user_id and v.organization_id = v_org
     and coalesce(nullif(btrim(h.preferred_name), ''), nullif(btrim(h.legal_name), '')) is not null
   order by h.updated_at desc
   limit 1;
  if v_name is not null then
    return v_name;
  end if;

  -- Read by key as well: raw_user_meta_data is Supabase's column, absent from the CI auth stub.
  select u.email, to_jsonb(u) -> 'raw_user_meta_data' into v_email, v_meta
    from auth.users u where u.id = p_user_id;

  if v_email is not null then
    select coalesce(
             nullif(btrim(to_jsonb(i) ->> 'display_name'), ''),
             nullif(btrim(to_jsonb(i) ->> 'full_name'), ''),
             nullif(btrim(to_jsonb(i) ->> 'name'), '')
           )
      into v_name
      from public.invites i
     where i.organization_id = v_org and lower(i.email) = lower(v_email) and i.status = 'accepted'
     order by (i.venue_id = p_venue_id) desc, i.created_at desc
     limit 1;
    if v_name is not null then
      return v_name;
    end if;
  end if;

  return coalesce(
    nullif(btrim(v_meta ->> 'display_name'), ''),
    nullif(btrim(v_meta ->> 'full_name'), ''),
    nullif(btrim(v_meta ->> 'name'), '')
  );
end;
$$;

revoke all on function app_hidden.member_display_name(uuid, uuid) from public, anon, authenticated;

-- The roster-style RPCs keep their signatures and access rules; only display_name changes.
create or replace function public.team_members(p_venue_id uuid)
returns table (
  membership_id uuid,
  user_id uuid,
  role public.app_role,
  display_name text,
  venue_id uuid,
  organization_id uuid
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_org uuid;
begin
  if auth.uid() is null
     or not app_hidden.has_venue_role(
       p_venue_id,
       array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
     ) then
    raise exception 'Not allowed to view this venue team' using errcode = '42501';
  end if;

  select v.organization_id into v_org from public.venues v where v.id = p_venue_id;

  return query
    select r.id, r.user_id, r.role, r.display_name, r.venue_id, r.organization_id
    from (
      select m.id, m.user_id, m.role, app_hidden.member_display_name(p_venue_id, m.user_id) as display_name,
             m.venue_id, m.organization_id
      from public.memberships m
      where m.organization_id = v_org
        and (m.venue_id = p_venue_id or m.venue_id is null)
    ) r
    order by (r.venue_id is null) desc, r.display_name nulls last, r.user_id;
end;
$$;

create or replace function public.venue_roster(p_venue_id uuid)
returns table (user_id uuid, role public.app_role, display_name text)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null
     or not app_hidden.has_venue_role(
       p_venue_id,
       array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
     ) then
    raise exception 'Not allowed to view this venue roster' using errcode = '42501';
  end if;

  -- Venue-level members, plus the organization's owners/admins, who manage every venue in it
  -- through an org-level membership (venue_id null). One row per person, venue role first.
  return query
    select r.user_id, r.role, app_hidden.member_display_name(p_venue_id, r.user_id) as display_name
    from (
      select distinct on (m.user_id) m.user_id, m.role
      from public.memberships m
      join public.venues v on v.id = p_venue_id
      where m.venue_id = p_venue_id
         or (m.venue_id is null and m.organization_id = v.organization_id
             and m.role in ('organization_owner', 'organization_admin'))
      order by m.user_id, (m.venue_id is null)
    ) r
    order by 3 nulls last, r.user_id;
end;
$$;

create or replace function public.venue_schedule_roster(p_venue_id uuid)
returns table (user_id uuid, role public.app_role, display_name text)
language plpgsql stable security definer set search_path = '' as $$
begin
  if auth.uid() is null or not app_hidden.is_venue_member(p_venue_id) then
    raise exception 'Not allowed to view this schedule roster' using errcode = '42501';
  end if;

  -- Same rule as venue_roster: venue-level members, plus org-level owners/admins of the
  -- venue's organization. One row per person, venue role first.
  return query
    select r.user_id, r.role, app_hidden.member_display_name(p_venue_id, r.user_id) as display_name
    from (
      select distinct on (m.user_id) m.user_id, m.role
      from public.memberships m
      join public.venues v on v.id = p_venue_id
      where m.venue_id = p_venue_id
         or (m.venue_id is null and m.organization_id = v.organization_id
             and m.role in ('organization_owner', 'organization_admin'))
      order by m.user_id, (m.venue_id is null)
    ) r
    order by 3 nulls last, r.user_id;
end;
$$;

create or replace function public.chat_contacts(p_venue_id uuid)
returns table (user_id uuid, display_name text)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null
     or not app_hidden.has_venue_role(
       p_venue_id,
       array['staff', 'supervisor', 'venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
     ) then
    raise exception 'Not allowed to view this venue''s team' using errcode = '42501';
  end if;

  -- Venue-level members plus the organization's owners/admins, one row per person, minus
  -- the caller.
  return query
    select r.user_id, app_hidden.member_display_name(p_venue_id, r.user_id) as display_name
    from (
      select distinct on (m.user_id) m.user_id
      from public.memberships m
      join public.venues v on v.id = p_venue_id
      where (
          m.venue_id = p_venue_id
          or (m.venue_id is null and m.organization_id = v.organization_id
              and m.role in ('organization_owner', 'organization_admin'))
        )
        and m.user_id <> auth.uid()
      order by m.user_id
    ) r
    order by 2 nulls last, r.user_id;
end;
$$;

revoke all on function public.team_members(uuid) from public, anon;
revoke all on function public.venue_roster(uuid) from public, anon;
revoke all on function public.venue_schedule_roster(uuid) from public, anon;
revoke all on function public.chat_contacts(uuid) from public, anon;
grant execute on function public.team_members(uuid) to authenticated;
grant execute on function public.venue_roster(uuid) to authenticated;
grant execute on function public.venue_schedule_roster(uuid) to authenticated;
grant execute on function public.chat_contacts(uuid) to authenticated;

-- -----------------------------------------------------------------------------
-- 5. Clock board and timesheet (D1).
-- -----------------------------------------------------------------------------
-- Who is on the clock right now, by name. Supervisors run the floor too, so they see it; the
-- time_entries policy (self or manager) is unchanged, so this returns no GPS and no history.
create or replace function public.venue_clock_board(p_venue_id uuid)
returns table (
  time_entry_id uuid,
  user_id uuid,
  display_name text,
  clock_in_at timestamptz,
  breaks jsonb,
  clock_in_attested boolean,
  location_anomaly text
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null or not app_hidden.has_venue_role(
    p_venue_id,
    array['supervisor', 'venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
  ) then
    raise exception 'Not allowed to view this clock board' using errcode = '42501';
  end if;

  return query
    select e.id, e.user_id, app_hidden.member_display_name(p_venue_id, e.user_id),
           e.clock_in_at, e.breaks, e.clock_in_attested, e.location_anomaly
    from public.time_entries e
    where e.venue_id = p_venue_id and e.is_open
    order by e.clock_in_at;
end;
$$;

revoke all on function public.venue_clock_board(uuid) from public, anon;
grant execute on function public.venue_clock_board(uuid) to authenticated;

-- Punches whose clock-in falls in [p_from, p_to), plus any punch still open that began before
-- p_to (a missed clock-out stays visible until it is closed), each with its display name and
-- correction history (who, when, why, clock-out before and after) from the audit log. Managers
-- only; no GPS. The window is capped at 93 days.
create or replace function public.venue_timesheet(p_venue_id uuid, p_from timestamptz, p_to timestamptz)
returns table (
  time_entry_id uuid,
  user_id uuid,
  display_name text,
  clock_in_at timestamptz,
  clock_out_at timestamptz,
  is_open boolean,
  breaks jsonb,
  punch_source text,
  clock_in_attested boolean,
  clock_out_attested boolean,
  location_anomaly text,
  corrections jsonb
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null or not app_hidden.has_venue_role(
    p_venue_id,
    array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
  ) then
    raise exception 'Not allowed to view this venue''s hours' using errcode = '42501';
  end if;

  if p_from is null or p_to is null or p_to <= p_from or p_to - p_from > interval '93 days' then
    raise exception 'choose a date range of up to 93 days' using errcode = '22023';
  end if;

  return query
    select e.id, e.user_id, app_hidden.member_display_name(p_venue_id, e.user_id),
           e.clock_in_at, e.clock_out_at, e.is_open, e.breaks, e.punch_source,
           e.clock_in_attested, e.clock_out_attested, e.location_anomaly,
           coalesce((
             select jsonb_agg(jsonb_build_object(
                      'corrected_at', a.created_at,
                      'corrected_by', a.actor_user_id,
                      'corrected_by_name', app_hidden.member_display_name(p_venue_id, a.actor_user_id),
                      'reason', a.metadata ->> 'reason',
                      'clock_out_before', a.metadata -> 'before' ->> 'clock_out_at',
                      'clock_out_after', a.metadata -> 'after' ->> 'clock_out_at',
                      'breaks_changed', (a.metadata -> 'before' -> 'breaks') is distinct from (a.metadata -> 'after' -> 'breaks')
                    ) order by a.created_at)
               from public.audit_log a
              where a.target_table = 'time_entries' and a.target_id = e.id
                and a.action = 'time_entry.correct'
           ), '[]'::jsonb)
    from public.time_entries e
    where e.venue_id = p_venue_id
      and ((e.clock_in_at >= p_from and e.clock_in_at < p_to) or (e.is_open and e.clock_in_at < p_to))
    order by e.clock_in_at;
end;
$$;

revoke all on function public.venue_timesheet(uuid, timestamptz, timestamptz) from public, anon;
grant execute on function public.venue_timesheet(uuid, timestamptz, timestamptz) to authenticated;

create index if not exists audit_log_target_id_idx on public.audit_log (target_id);

-- Launch review S1, A1, D4, U1, U5. Additive changes; no production data removed.
alter table public.venues add column if not exists address text check (char_length(address) <= 500);
alter table public.invites add column if not exists display_name text check (char_length(display_name) <= 120);

create or replace function public.set_venue_location(p_venue_id uuid, p_address text,
  p_lat double precision, p_lng double precision, p_radius integer default 150)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not app_hidden.has_venue_role(p_venue_id,
    array['venue_manager','organization_admin','organization_owner']::public.app_role[]) then
    raise exception 'Only managers may configure venue location' using errcode = '42501';
  end if;
  if p_lat is null or p_lng is null or not (p_lat between -90 and 90)
    or not (p_lng between -180 and 180) or (p_lat = 0 and p_lng = 0)
    or p_radius is null or p_radius not between 25 and 1000
    or nullif(trim(p_address),'') is null then
    raise exception 'Provide an address, valid coordinates and a radius of 25–1000 metres' using errcode = '22023';
  end if;
  update public.venues set address = trim(p_address), latitude = p_lat,
    longitude = p_lng, geofence_radius_m = p_radius where id = p_venue_id;
end $$;
revoke all on function public.set_venue_location(uuid,text,double precision,double precision,integer) from public, anon;
grant execute on function public.set_venue_location(uuid,text,double precision,double precision,integer) to authenticated;

-- Refuse new punches until a manager configures a location. Existing open punches can close.
create or replace function app_hidden.require_clock_in_location()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if not exists (select 1 from public.venues v where v.id = new.venue_id
    and v.latitude between -90 and 90 and v.longitude between -180 and 180
    and not (v.latitude = 0 and v.longitude = 0)) then
    raise exception 'Venue location is not configured. Ask a manager to set it in Settings before clocking in.' using errcode = '42501';
  end if;
  return new;
end $$;
create trigger require_clock_in_location before insert on public.time_entries
for each row execute function app_hidden.require_clock_in_location();

-- Expire and replace under the same venue/email lock. No stale pending unique-key blocker.
create or replace function public.prepare_staff_invite(p_venue_id uuid, p_email text,
  p_role public.app_role, p_display_name text default null)
returns public.invites language plpgsql security definer set search_path = '' as $$
declare v_invite public.invites;
begin
  if not app_hidden.has_venue_role(p_venue_id,
    array['venue_manager','organization_admin','organization_owner']::public.app_role[]) then
    raise exception 'Only managers may invite staff' using errcode = '42501';
  end if;
  if p_role not in ('staff','supervisor','venue_manager') or p_role is null
    or p_email is null or length(p_email) > 254 or p_email !~ '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$' then
    raise exception 'Invalid invite email or role' using errcode = '22023';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(p_venue_id::text || lower(trim(p_email)), 0));
  -- Trusted replacement follows the same revoke transition clients may perform.
  update public.invites set status = 'revoked'
    where venue_id = p_venue_id and email = lower(trim(p_email)) and status = 'pending'
      and expires_at <= now();
  select * into v_invite from public.invites where venue_id = p_venue_id
    and email = lower(trim(p_email)) and status = 'pending';
  if found then return v_invite; end if;
  insert into public.invites(venue_id, email, role, display_name)
    values(p_venue_id, p_email, p_role, nullif(trim(p_display_name),'')) returning * into v_invite;
  return v_invite;
end $$;
revoke all on function public.prepare_staff_invite(uuid,text,public.app_role,text) from public, anon;
grant execute on function public.prepare_staff_invite(uuid,text,public.app_role,text) to authenticated;

-- Serialize every assignment/time mutation by venue, including swap-trigger writes.
create or replace function app_hidden.guard_shift_overlap()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  perform pg_advisory_xact_lock(hashtextextended('schedule:' || new.venue_id::text, 0));
  if tg_op = 'UPDATE' then
    if new.staff_id is not distinct from old.staff_id and new.start_time = old.start_time
      and new.end_time = old.end_time and new.status = old.status then return new; end if;
  end if;
  if new.staff_id is not null and new.status = 'scheduled' and exists (
    select 1 from public.shifts s where s.venue_id = new.venue_id and s.id <> new.id
      and s.staff_id = new.staff_id and s.status = 'scheduled'
      and s.start_time < new.end_time and s.end_time > new.start_time
  ) then
    raise exception 'This person already has an overlapping shift' using errcode = '23P01';
  end if;
  return new;
end $$;
create trigger guard_shift_overlap before insert or update on public.shifts
for each row execute function app_hidden.guard_shift_overlap();

-- Cancelling the reservation of a confirmed BEO cancels that BEO in the same transaction.
-- The forward BEO trigger already cancels its reservation; the status guard stops recursion.
create or replace function app_hidden.sync_reservation_beo_cancellation()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.beo_id is not null and new.status = 'cancelled' and old.status <> 'cancelled'
    and exists(select 1 from public.crm_beos where id = new.beo_id and status <> 'cancelled') then
    if auth.uid() is not null and not app_hidden.has_venue_role(new.venue_id,
      array['venue_manager','organization_admin','organization_owner']::public.app_role[]) then
      raise exception 'Only managers may cancel a private event' using errcode = '42501';
    end if;
    update public.crm_beos set status = 'cancelled' where id = new.beo_id and venue_id = new.venue_id;
  end if;
  return new;
end $$;
create trigger sync_reservation_beo_cancellation after update on public.reservations
for each row execute function app_hidden.sync_reservation_beo_cancellation();

-- Display a manager-entered operational name without granting access to the HR record.
create or replace function app_hidden.staff_display_name(p_venue uuid, p_user uuid)
returns text language sql stable security definer set search_path = '' as $$
  select coalesce(nullif(trim(h.preferred_name),''), nullif(trim(p.display_name),''),
    nullif(trim(h.legal_name),'')) from public.profiles p
    left join public.employee_hr_profiles h on h.user_id = p.id and h.venue_id = p_venue
    where p.id = p_user;
$$;
revoke all on function app_hidden.staff_display_name(uuid,uuid) from public, anon, authenticated;

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
    select r.user_id, r.role, r.display_name
    from (
      select distinct on (m.user_id) m.user_id, m.role, app_hidden.staff_display_name(p_venue_id, m.user_id) as display_name
      from public.memberships m
      join public.venues v on v.id = p_venue_id
      left join public.profiles p on p.id = m.user_id
      where m.venue_id = p_venue_id
         or (m.venue_id is null and m.organization_id = v.organization_id
             and m.role in ('organization_owner', 'organization_admin'))
      order by m.user_id, (m.venue_id is null)
    ) r
    order by r.display_name nulls last, r.user_id;
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
    select r.user_id, r.role, r.display_name
    from (
      select distinct on (m.user_id) m.user_id, m.role, app_hidden.staff_display_name(p_venue_id, m.user_id) as display_name
      from public.memberships m
      join public.venues v on v.id = p_venue_id
      left join public.profiles p on p.id = m.user_id
      where m.venue_id = p_venue_id
         or (m.venue_id is null and m.organization_id = v.organization_id
             and m.role in ('organization_owner', 'organization_admin'))
      order by m.user_id, (m.venue_id is null)
    ) r
    order by r.display_name nulls last, r.user_id;
end;
$$;

create or replace function app_hidden.handle_new_user()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles(id, display_name)
    values(new.id, left(nullif(trim(to_jsonb(new)->'raw_user_meta_data'->>'display_name'),''), 120))
    on conflict(id) do nothing;
  return new;
end $$;
do $$ begin
  if exists(select 1 from pg_publication where pubname = 'supabase_realtime')
    and not exists(select 1 from pg_publication_tables where pubname = 'supabase_realtime'
      and schemaname = 'public' and tablename = 'shifts') then
    alter publication supabase_realtime add table public.shifts;
  end if;
end $$;

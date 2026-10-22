-- Launch review D4 / U7: private-event cancellation is reversible, a BEO and its reservation hold
-- stay in step from either side, and a hold conflict names what is in the way.
--
--   1. crm_beos remembers when it was cancelled and the status it had, so a manager can restore
--      it (public.restore_crm_beo). Restoring is refused once the event date has passed;
--      restoring a confirmed BEO goes back through crm_beos_sync_reservation, which re-checks the
--      four-hour window and re-confirms the same reservation row.
--   2. Cancelling or restoring the hold reservation from the reservation book does the same to
--      its BEO (managers), and is refused for anyone else with a message to ask a manager —
--      before this, a supervisor could cancel the booking while the BEO stayed confirmed and kept
--      the whole night blocked. Moving or deleting a live hold is refused: the event's time is
--      owned by its BEO.
--   3. reservation_hold_conflict errors carry the conflicting bookings in DETAIL (JSON) so the app
--      can say "3 dinner reservations (Lee, 7:30 PM, ...)" instead of blaming "another confirmed
--      event" when ordinary reservations are what block the event.

-- -----------------------------------------------------------------------------
-- 1. Cancellation memory and restore
-- -----------------------------------------------------------------------------
alter table public.crm_beos
  add column cancelled_at timestamptz,
  add column status_before_cancel text check (
    status_before_cancel is null
    or status_before_cancel in ('draft', 'sent', 'reviewed', 'confirmed', 'amended')
  );

-- Server-maintained: whatever a client writes to these two columns is overwritten here.
create or replace function app_hidden.crm_beos_track_cancellation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    new.cancelled_at := case when new.status = 'cancelled' then now() end;
    new.status_before_cancel := null;
    return new;
  end if;

  if new.status = 'cancelled' and old.status is distinct from 'cancelled' then
    new.cancelled_at := now();
    new.status_before_cancel := old.status;
  elsif old.status = 'cancelled' and new.status is distinct from 'cancelled' then
    if new.event_date is not null and new.event_date <= now() then
      raise exception 'beo_restore_past: this event''s date has passed, so it cannot be restored'
        using errcode = '22023';
    end if;
    new.cancelled_at := null;
    new.status_before_cancel := null;
  else
    new.cancelled_at := old.cancelled_at;
    new.status_before_cancel := old.status_before_cancel;
  end if;
  return new;
end;
$$;

revoke all on function app_hidden.crm_beos_track_cancellation() from public, anon, authenticated;

drop trigger if exists trg_crm_beos_track_cancellation on public.crm_beos;
create trigger trg_crm_beos_track_cancellation
  before insert or update on public.crm_beos
  for each row execute function app_hidden.crm_beos_track_cancellation();

-- Restores a cancelled BEO to the status it had. SECURITY INVOKER: the crm_beos RLS policies
-- (manager tier) decide who may do it, exactly as for any other BEO status change.
create or replace function public.restore_crm_beo(p_beo_id uuid)
returns text
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_status text;
begin
  update public.crm_beos
     set status = coalesce(status_before_cancel, 'draft')
   where id = p_beo_id and status = 'cancelled'
  returning status into v_status;

  if v_status is null then
    if exists (select 1 from public.crm_beos where id = p_beo_id) then
      raise exception 'beo_not_cancelled: this event is not cancelled' using errcode = '22023';
    end if;
    raise exception 'beo_not_found: no event you can manage has this id' using errcode = '42501';
  end if;
  return v_status;
end;
$$;

revoke all on function public.restore_crm_beo(uuid) from public, anon;
grant execute on function public.restore_crm_beo(uuid) to authenticated;

-- -----------------------------------------------------------------------------
-- 3. Conflict details (helper shared by both hold checks)
-- -----------------------------------------------------------------------------
-- The live bookings overlapping [p_start, p_end) at the venue, as the DETAIL payload of a
-- reservation_hold_conflict error: {"total": n, "conflicts": [first five, by start time]}. Each
-- entry is {kind: "reservation" | "event", name, party_size, starts_at, ends_at}. An event's own
-- name (CRM data) is shown only to managers; others see its booking's guest name, which they can
-- already read in the reservation book.
create or replace function app_hidden.reservation_hold_conflicts(
  p_venue_id uuid,
  p_start timestamptz,
  p_end timestamptz,
  p_exclude_beo_id uuid
)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  with manager as (
    select app_hidden.has_venue_role(
      p_venue_id,
      array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
    ) as yes
  ),
  hits as (
    -- Live reservations (including other events' holds) in the window.
    select r.reservation_time as starts_at,
           r.reservation_time + make_interval(mins => r.duration_minutes) as ends_at,
           case when r.beo_id is null then 'reservation' else 'event' end as kind,
           case when r.beo_id is not null and (select yes from manager)
                then coalesce(b.event_name, r.guest_name) else r.guest_name end as name,
           r.party_size,
           r.id as sort_id
      from public.reservations r
      left join public.crm_beos b on b.id = r.beo_id
     where r.venue_id = p_venue_id
       and r.status not in ('cancelled', 'no_show')
       and r.beo_id is distinct from p_exclude_beo_id
       and r.reservation_time < p_end
       and r.reservation_time + make_interval(mins => r.duration_minutes) > p_start
    union all
    -- Confirmed events whose own hold row is missing or not live (they still hold the venue).
    select b.event_date,
           b.event_date + interval '240 minutes',
           'event',
           case when (select yes from manager) then b.event_name
                else coalesce(hold.guest_name, 'A private event') end,
           coalesce(b.guest_count, hold.party_size),
           b.id
      from public.crm_beos b
      left join public.reservations hold on hold.beo_id = b.id
     where b.venue_id = p_venue_id
       and b.status = 'confirmed'
       and b.event_date is not null
       and b.id is distinct from p_exclude_beo_id
       and b.event_date < p_end
       and b.event_date + interval '240 minutes' > p_start
       and (hold.id is null or hold.status in ('cancelled', 'no_show'))
  ),
  ranked as (
    select h.*, row_number() over (order by h.starts_at, h.sort_id) as rn from hits h
  )
  select jsonb_build_object(
    'total', (select count(*) from ranked),
    'conflicts', coalesce(
      (select jsonb_agg(jsonb_build_object(
                'kind', kind,
                'name', name,
                'party_size', party_size,
                'starts_at', starts_at,
                'ends_at', ends_at
              ) order by rn)
         from ranked where rn <= 5),
      '[]'::jsonb
    )
  );
$$;

revoke all on function app_hidden.reservation_hold_conflicts(uuid, timestamptz, timestamptz, uuid)
  from public, anon, authenticated;

-- A one-line summary for the error message itself (the app builds a fuller one from DETAIL).
create or replace function app_hidden.reservation_hold_conflict_summary(p_details jsonb)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when exists (
      select 1 from jsonb_array_elements(p_details -> 'conflicts') c where c ->> 'kind' = 'event'
    ) then 'the requested time overlaps a confirmed event'
    when (p_details ->> 'total')::int = 1 then '1 reservation overlaps the requested event window'
    else (p_details ->> 'total') || ' reservations overlap the requested event window'
  end;
$$;

revoke all on function app_hidden.reservation_hold_conflict_summary(jsonb) from public, anon, authenticated;

-- Same body as 20261007202000 except for the richer conflict error.
create or replace function app_hidden.crm_beos_sync_reservation()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_existing uuid;
  v_guest_name text;
  v_guest_phone text;
  v_guest_email text;
  v_sync boolean := false;
  v_conflicts jsonb;
begin
  if new.status = 'confirmed' then
    if new.event_date is null then
      raise exception 'choose an event start time before confirming the BEO'
        using errcode = '22023';
    end if;
    if tg_op = 'INSERT' then
      v_sync := true;
    else
      v_sync := old.status is distinct from 'confirmed'
        or new.event_date is distinct from old.event_date
        or new.guest_count is distinct from old.guest_count
        or new.venue_space is distinct from old.venue_space
        or new.lead_id is distinct from old.lead_id;
    end if;
  end if;
  if v_sync then
    perform pg_advisory_xact_lock(hashtextextended('beo:' || new.venue_id::text, 0));
    select id into v_existing from public.reservations where beo_id = new.id;
    if exists (
      select 1 from public.reservations r
      where r.venue_id = new.venue_id
        and r.status not in ('cancelled', 'no_show')
        and r.beo_id is distinct from new.id
        and r.reservation_time < new.event_date + interval '240 minutes'
        and r.reservation_time + make_interval(mins => r.duration_minutes)
          > new.event_date
    ) then
      v_conflicts := app_hidden.reservation_hold_conflicts(
        new.venue_id, new.event_date, new.event_date + interval '240 minutes', new.id
      );
      raise exception 'reservation_hold_conflict: %',
          app_hidden.reservation_hold_conflict_summary(v_conflicts)
        using errcode = '23505', detail = v_conflicts::text;
    end if;
    if new.lead_id is not null then
      select full_name, phone, email
        into v_guest_name, v_guest_phone, v_guest_email
        from public.crm_leads where id = new.lead_id and venue_id = new.venue_id;
    end if;
    if v_existing is null then
      insert into public.reservations (
        venue_id, beo_id, guest_name, guest_phone, guest_email, party_size,
        reservation_time, duration_minutes, source, status, notes
      ) values (
        new.venue_id, new.id, coalesce(v_guest_name, new.event_name),
        v_guest_phone, v_guest_email, coalesce(new.guest_count, 1),
        new.event_date, 240, 'private_event', 'confirmed',
        nullif(concat_ws(' / ', new.menu_appetizers, new.menu_entrees), '')
      );
    else
      update public.reservations set
        reservation_time = new.event_date, duration_minutes = 240,
        party_size = coalesce(new.guest_count, party_size),
        guest_name = coalesce(v_guest_name, guest_name),
        guest_phone = coalesce(v_guest_phone, guest_phone),
        guest_email = coalesce(v_guest_email, guest_email),
        status = 'confirmed',
        cancelled_at = null,
        notes = nullif(concat_ws(' / ', new.menu_appetizers, new.menu_entrees), ''),
        updated_at = now()
      where id = v_existing;
    end if;
  end if;
  if tg_op = 'UPDATE' then
    if new.status = 'cancelled' and old.status is distinct from 'cancelled' then
      update public.reservations set status = 'cancelled', cancelled_at = now(), updated_at = now()
        where beo_id = new.id and status is distinct from 'cancelled';
    end if;
    if new.status is distinct from old.status then
      insert into public.crm_activity_log (venue_id, lead_id, actor_id, kind, detail)
        values (new.venue_id, new.lead_id, auth.uid(), 'beo_status_changed',
          old.status || ' -> ' || new.status);
    end if;
  end if;
  return new;
end;
$$;

-- Same check as 20261010155000, now naming the event in DETAIL.
create or replace function app_hidden.guard_reservation_against_confirmed_beos()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_conflicts jsonb;
begin
  perform pg_advisory_xact_lock(
    hashtextextended('beo-reservation:' || new.venue_id::text, 0)
  );

  if new.status not in ('cancelled', 'no_show') and exists (
    select 1
    from public.crm_beos b
    where b.venue_id = new.venue_id
      and b.status = 'confirmed'
      and b.event_date is not null
      and new.beo_id is distinct from b.id
      and new.reservation_time < b.event_date + interval '240 minutes'
      and new.reservation_time + make_interval(mins => new.duration_minutes) > b.event_date
  ) then
    select jsonb_build_object(
             'total', count(*),
             'conflicts', coalesce(jsonb_agg(jsonb_build_object(
               'kind', 'event',
               'name', case
                 when app_hidden.has_venue_role(
                   new.venue_id,
                   array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
                 ) then b.event_name
                 else coalesce(hold.guest_name, 'A private event') end,
               'party_size', coalesce(b.guest_count, hold.party_size),
               'starts_at', b.event_date,
               'ends_at', b.event_date + interval '240 minutes'
             ) order by b.event_date), '[]'::jsonb)
           )
      into v_conflicts
      from public.crm_beos b
      left join public.reservations hold on hold.beo_id = b.id
     where b.venue_id = new.venue_id
       and b.status = 'confirmed'
       and b.event_date is not null
       and new.beo_id is distinct from b.id
       and new.reservation_time < b.event_date + interval '240 minutes'
       and new.reservation_time + make_interval(mins => new.duration_minutes) > b.event_date;
    raise exception 'reservation_hold_conflict: the requested time overlaps a confirmed event'
      using errcode = '23505', detail = v_conflicts::text;
  end if;
  return new;
end;
$$;

-- -----------------------------------------------------------------------------
-- 2. The reservation side of a private event follows its BEO
-- -----------------------------------------------------------------------------
-- Acts only for app users (the request's role is `authenticated`) on a direct write
-- (pg_trigger_depth() = 1). Server paths (service role, migrations) are left alone, and so are
-- the writes crm_beos_sync_reservation makes from inside a BEO update, which is also what stops
-- the BEO -> reservation -> BEO update from looping.
create or replace function app_hidden.reservations_follow_beo()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_is_manager boolean;
  v_beo_status text;
begin
  if old.beo_id is null
     or pg_trigger_depth() > 1
     or current_setting('role', true) is distinct from 'authenticated' then
    return null;
  end if;

  v_is_manager := app_hidden.has_venue_role(
    old.venue_id,
    array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
  );
  select status into v_beo_status from public.crm_beos where id = old.beo_id;

  if tg_op = 'DELETE' then
    if v_beo_status is distinct from 'cancelled' then
      raise exception 'beo_hold_managed_in_crm: this booking holds a private event; cancel the event instead of deleting its booking'
        using errcode = '42501';
    end if;
    return null;
  end if;

  if new.reservation_time is distinct from old.reservation_time
     or new.duration_minutes is distinct from old.duration_minutes
     or new.beo_id is distinct from old.beo_id then
    raise exception 'beo_hold_managed_in_crm: this booking holds a private event; change its date in the event order'
      using errcode = '42501';
  end if;

  if new.status = 'cancelled' and old.status is distinct from 'cancelled' then
    if not v_is_manager then
      raise exception 'beo_hold_managed_in_crm: this booking holds a private event; ask a manager to cancel the event'
        using errcode = '42501';
    end if;
    update public.crm_beos set status = 'cancelled'
     where id = old.beo_id and status is distinct from 'cancelled';
  elsif old.status = 'cancelled' and new.status is distinct from 'cancelled' then
    if not v_is_manager then
      raise exception 'beo_hold_managed_in_crm: this booking holds a private event; ask a manager to restore the event'
        using errcode = '42501';
    end if;
    if v_beo_status = 'cancelled' then
      -- Re-checks the date and the four-hour window; a conflict rolls back this whole update.
      perform public.restore_crm_beo(old.beo_id);
    end if;
  end if;
  return null;
end;
$$;

revoke all on function app_hidden.reservations_follow_beo() from public, anon, authenticated;

drop trigger if exists zz_reservations_follow_beo on public.reservations;
create trigger zz_reservations_follow_beo
  after update or delete on public.reservations
  for each row execute function app_hidden.reservations_follow_beo();

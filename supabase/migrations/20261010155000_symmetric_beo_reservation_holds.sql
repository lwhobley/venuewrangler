-- Serialize BEO and reservation writes on a venue-scoped lock and enforce the same
-- confirmed-BEO window from either write direction. The established policy is a venue-wide
-- four-hour hold; this intentionally does not invent room-level concurrency semantics.
create or replace function app_hidden.lock_beo_reservation_venue()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform pg_advisory_xact_lock(
    hashtextextended('beo-reservation:' || new.venue_id::text, 0)
  );
  return new;
end;
$$;

drop trigger if exists aa_lock_beo_reservation_venue on public.crm_beos;
create trigger aa_lock_beo_reservation_venue
before insert or update of venue_id, event_date, status on public.crm_beos
for each row execute function app_hidden.lock_beo_reservation_venue();

create or replace function app_hidden.guard_reservation_against_confirmed_beos()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
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
    raise exception 'reservation_hold_conflict: the requested time overlaps a confirmed event'
      using errcode = '23505';
  end if;
  return new;
end;
$$;

drop trigger if exists zz_reservations_beo_hold on public.reservations;
create trigger zz_reservations_beo_hold
before insert or update of venue_id, reservation_time, duration_minutes, status, beo_id
on public.reservations
for each row execute function app_hidden.guard_reservation_against_confirmed_beos();

revoke all on function app_hidden.lock_beo_reservation_venue() from public, anon, authenticated;
revoke all on function app_hidden.guard_reservation_against_confirmed_beos() from public, anon, authenticated;

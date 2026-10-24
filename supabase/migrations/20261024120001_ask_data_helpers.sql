-- "Ask about your data" (AI) - shared helpers for the fixed metric catalogue.
--
-- Design (fixed): the AI never writes SQL. It can only choose from the catalogue of read-only
-- `public.ask_data_<metric>` functions defined in 20261024120002_ask_data_metrics.sql. Every one
-- of them
--   * is SECURITY DEFINER with `set search_path = ''` and begins with an explicit manager check
--     (venue_manager of that venue, or organization owner/admin) through the helpers below, so
--     being able to read a table through RLS is never what authorises a call;
--   * filters every query by `p_venue_id`, so one venue's figures can never include another's;
--   * returns aggregates only. Never: pay rates or wages, HR fields, guest names or contact
--     details, allergy/dietary/VIP notes, free-text notes/chat/incident narratives, deposit or
--     payment identifiers, auth data. Staff names appear only where the answer is "by person"
--     (hours, shifts, overtime, missed clock-outs) and only for rows of this venue;
--   * validates its parameters: date range of at most 93 venue-local days, group-by from a fixed
--     enum, row cap of at most 50.
-- Dates are venue-local calendar dates; day boundaries use the venue's IANA timezone.

-- Manager gate + date window. Returns the venue timezone and the half-open instant range
-- [from_ts, to_ts) covering venue-local dates p_from..p_to inclusive.
create or replace function app_hidden.ask_data_window(p_venue_id uuid, p_from date, p_to date)
returns table (tz text, from_ts timestamptz, to_ts timestamptz)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_tz text;
begin
  if auth.uid() is null or p_venue_id is null or not app_hidden.has_venue_role(
    p_venue_id,
    array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
  ) then
    raise exception 'Not allowed to query this venue''s figures' using errcode = '42501';
  end if;

  if p_from is null or p_to is null or p_to < p_from or p_to - p_from >= 93 then
    raise exception 'choose a date range of up to 93 days' using errcode = '22023';
  end if;

  select v.timezone into v_tz from public.venues v where v.id = p_venue_id;
  if v_tz is null then
    raise exception 'venue not found' using errcode = 'P0002';
  end if;
  if not exists (select 1 from pg_catalog.pg_timezone_names n where n.name = v_tz) then
    raise exception 'venue timezone is not recognised' using errcode = '22023';
  end if;

  return query
    select v_tz,
           (p_from::timestamp at time zone v_tz),
           ((p_to + 1)::timestamp at time zone v_tz);
end;
$$;

-- Manager gate for metrics that take no date range.
create or replace function app_hidden.ask_data_require_manager(p_venue_id uuid)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null or p_venue_id is null or not app_hidden.has_venue_role(
    p_venue_id,
    array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
  ) then
    raise exception 'Not allowed to query this venue''s figures' using errcode = '42501';
  end if;
end;
$$;

-- Row cap: default 50, never above 50, never below 1.
create or replace function app_hidden.ask_data_limit(p_limit integer)
returns integer
language sql
immutable
set search_path = ''
as $$
  select least(greatest(coalesce(p_limit, 50), 1), 50);
$$;

-- Minutes worked on one closed punch: clock-in to clock-out less unpaid breaks (a break with no
-- type counts as unpaid; an unfinished break ends at clock-out). Mirrors
-- TimeEntry.workedDuration in apps/mobile/lib/features/time_clock/domain/time_entry.dart, which the manager hours review and CSV export use (whole minutes per interval; main computes hours client-side, so this is the SQL twin of that rule).
create or replace function app_hidden.ask_data_worked_minutes(
  p_clock_in timestamptz,
  p_clock_out timestamptz,
  p_breaks jsonb
)
returns integer
language sql
stable
set search_path = ''
as $$
  select greatest(
    0,
    floor(extract(epoch from (p_clock_out - p_clock_in)) / 60)::integer - coalesce((
      select sum(greatest(0, floor(extract(epoch from (
               coalesce(nullif(b ->> 'end_at', '')::timestamptz, p_clock_out)
               - (b ->> 'start_at')::timestamptz)) / 60)::integer))
        from jsonb_array_elements(
               case when jsonb_typeof(p_breaks) = 'array' then p_breaks else '[]'::jsonb end
             ) b
       where coalesce(b ->> 'type', 'unpaid') = 'unpaid'
         and (b ->> 'start_at') is not null
    ), 0)
  );
$$;

revoke all on function app_hidden.ask_data_window(uuid, date, date) from public, anon, authenticated;
revoke all on function app_hidden.ask_data_require_manager(uuid) from public, anon, authenticated;
revoke all on function app_hidden.ask_data_limit(integer) from public, anon, authenticated;
revoke all on function app_hidden.ask_data_worked_minutes(timestamptz, timestamptz, jsonb) from public, anon, authenticated;

-- "Ask about your data" (AI) - the fixed metric catalogue. See 20261024120001_ask_data_helpers.sql
-- for the rules every function here follows (manager-only, venue-scoped, aggregates only,
-- venue-local dates, <= 93 day range, <= 50 rows). The Dart catalogue that describes these to the
-- AI lives in apps/mobile/lib/features/ai/domain/data_catalogue.dart and must be kept in step.
--
-- Every function returns `total_buckets`: how many rows the full answer had before the row cap,
-- so a truncated list is visible to the person and to the AI.

-- -----------------------------------------------------------------------------
-- 1. Reservations: counts and covers by total / day / status, no-show and cancel rate.
-- -----------------------------------------------------------------------------
-- covers = party size of every booking; served_covers = seated or completed bookings only.
-- no_show_rate_pct = no-shows / (no-shows + seated + completed); cancel_rate_pct = cancelled /
-- all bookings. Bookings are placed on the venue-local day of reservation_time.
create or replace function public.ask_data_reservation_summary(
  p_venue_id uuid,
  p_from date,
  p_to date,
  p_group_by text default 'total',
  p_limit integer default 50
)
returns table (
  bucket text,
  reservation_count bigint,
  covers bigint,
  served_covers bigint,
  no_show_count bigint,
  cancelled_count bigint,
  no_show_rate_pct numeric,
  cancel_rate_pct numeric,
  total_buckets bigint
)
language plpgsql
stable
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  w record;
  v_limit integer := app_hidden.ask_data_limit(p_limit);
begin
  if p_group_by is null or p_group_by not in ('total', 'day', 'status') then
    raise exception 'unsupported group_by' using errcode = '22023';
  end if;
  select * into w from app_hidden.ask_data_window(p_venue_id, p_from, p_to);

  return query
    with r as (
      select case p_group_by
               when 'day' then to_char((x.reservation_time at time zone w.tz)::date, 'YYYY-MM-DD')
               when 'status' then x.status
               else 'total'
             end as k,
             x.party_size as party_size,
             x.status as st
        from public.reservations x
       where x.venue_id = p_venue_id
         and x.reservation_time >= w.from_ts and x.reservation_time < w.to_ts
    ), agg as (
      select r.k as k,
             count(*) as c,
             coalesce(sum(r.party_size), 0) as cov,
             coalesce(sum(r.party_size) filter (where r.st in ('seated', 'completed')), 0) as served,
             count(*) filter (where r.st = 'no_show') as ns,
             count(*) filter (where r.st in ('seated', 'completed')) as sv,
             count(*) filter (where r.st = 'cancelled') as cx
        from r group by r.k
    ), padded as (
      select * from agg
      union all
      select 'total', 0::bigint, 0::bigint, 0::bigint, 0::bigint, 0::bigint, 0::bigint
       where p_group_by = 'total' and not exists (select 1 from agg)
    )
    select p.k, p.c, p.cov, p.served, p.ns, p.cx,
           round(100.0 * p.ns / nullif(p.ns + p.sv, 0), 1),
           round(100.0 * p.cx / nullif(p.c, 0), 1),
           (count(*) over ())::bigint
      from padded p
     order by case when p_group_by = 'day' then p.k end desc, p.c desc, p.k
     limit v_limit;
end;
$$;

-- -----------------------------------------------------------------------------
-- 2. Private events / BEOs: count, guests and itemised charges by status or month.
-- -----------------------------------------------------------------------------
-- charges_cents = itemised BEO charges (food, beverage, room, service, tax, other) less
-- discounts, in cents. Events are placed on the venue-local month of event_date. Without
-- p_status, month grouping leaves out cancelled events; status grouping lists every status.
-- Deposit or payment identifiers are never read.
create or replace function public.ask_data_private_event_summary(
  p_venue_id uuid,
  p_from date,
  p_to date,
  p_group_by text default 'status',
  p_status text default null,
  p_limit integer default 50
)
returns table (
  bucket text,
  event_count bigint,
  guest_count bigint,
  charges_cents bigint,
  total_buckets bigint
)
language plpgsql
stable
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  w record;
  v_limit integer := app_hidden.ask_data_limit(p_limit);
begin
  if p_group_by is null or p_group_by not in ('status', 'month') then
    raise exception 'unsupported group_by' using errcode = '22023';
  end if;
  if p_status is not null
     and p_status not in ('draft', 'sent', 'reviewed', 'confirmed', 'amended', 'cancelled') then
    raise exception 'unsupported status' using errcode = '22023';
  end if;
  select * into w from app_hidden.ask_data_window(p_venue_id, p_from, p_to);

  return query
    with e as (
      select case p_group_by
               when 'month' then to_char(b.event_date at time zone w.tz, 'YYYY-MM')
               else b.status
             end as k,
             coalesce(b.guest_count, 0) as guests,
             coalesce((
               select sum(case when c.category = 'discount' then -c.amount_cents else c.amount_cents end)
                 from public.crm_beo_charges c
                where c.beo_id = b.id and c.venue_id = p_venue_id
             ), 0)::bigint as ch
        from public.crm_beos b
       where b.venue_id = p_venue_id
         and b.event_date >= w.from_ts and b.event_date < w.to_ts
         and (p_status is null or b.status = p_status)
         and (p_status is not null or p_group_by = 'status' or b.status <> 'cancelled')
    ), agg as (
      select e.k as k, count(*) as c, sum(e.guests)::bigint as g, sum(e.ch)::bigint as ch
        from e group by e.k
    )
    select a.k, a.c, a.g, a.ch, (count(*) over ())::bigint
      from agg a
     order by case when p_group_by = 'month' then a.k end desc, a.ch desc, a.k
     limit v_limit;
end;
$$;

-- -----------------------------------------------------------------------------
-- 3. Labour: hours worked per person, per day or in total.
-- -----------------------------------------------------------------------------
-- Closed punches whose clock-in falls on a venue-local date in range, less unpaid breaks (same
-- rule as the manager hours review). Open punches are counted but add no hours. Pay rates and
-- wages are never read.
create or replace function public.ask_data_labour_hours(
  p_venue_id uuid,
  p_from date,
  p_to date,
  p_group_by text default 'person',
  p_limit integer default 50
)
returns table (
  bucket text,
  worked_hours numeric,
  punch_count bigint,
  open_punch_count bigint,
  total_buckets bigint
)
language plpgsql
stable
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  w record;
  v_limit integer := app_hidden.ask_data_limit(p_limit);
begin
  if p_group_by is null or p_group_by not in ('person', 'day', 'total') then
    raise exception 'unsupported group_by' using errcode = '22023';
  end if;
  select * into w from app_hidden.ask_data_window(p_venue_id, p_from, p_to);

  return query
    with t as (
      select case p_group_by
               when 'person' then e.user_id::text
               when 'day' then to_char((e.clock_in_at at time zone w.tz)::date, 'YYYY-MM-DD')
               else 'total'
             end as k,
             e.is_open as is_open,
             case when e.is_open then 0
                  else app_hidden.ask_data_worked_minutes(e.clock_in_at, e.clock_out_at, e.breaks)
             end as mins
        from public.time_entries e
       where e.venue_id = p_venue_id
         and e.clock_in_at >= w.from_ts and e.clock_in_at < w.to_ts
    ), agg as (
      select t.k as k, sum(t.mins)::bigint as mins, count(*) as c,
             count(*) filter (where t.is_open) as o
        from t group by t.k
    ), padded as (
      select * from agg
      union all
      select 'total', 0::bigint, 0::bigint, 0::bigint
       where p_group_by = 'total' and not exists (select 1 from agg)
    )
    select case when p_group_by = 'person'
                then coalesce(app_hidden.staff_display_name(p_venue_id, p.k::uuid), 'Unnamed team member')
                else p.k
           end,
           round(p.mins / 60.0, 2), p.c, p.o,
           (count(*) over ())::bigint
      from padded p
     order by case when p_group_by = 'person' then p.mins end desc nulls last,
              case when p_group_by = 'day' then p.k end desc,
              p.k
     limit v_limit;
end;
$$;

-- -----------------------------------------------------------------------------
-- 4. Labour: overtime hours over 40 per person per Monday-Sunday venue week.
-- -----------------------------------------------------------------------------
-- Closed punches of every whole venue-local week that overlaps the range, so a week is never
-- judged on half its punches. Only person-weeks with overtime are listed.
create or replace function public.ask_data_labour_overtime(
  p_venue_id uuid,
  p_from date,
  p_to date,
  p_limit integer default 50
)
returns table (
  bucket text,
  week_start text,
  worked_hours numeric,
  overtime_hours numeric,
  total_buckets bigint
)
language plpgsql
stable
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  w record;
  v_limit integer := app_hidden.ask_data_limit(p_limit);
  v_from_ts timestamptz;
  v_to_ts timestamptz;
begin
  select * into w from app_hidden.ask_data_window(p_venue_id, p_from, p_to);
  v_from_ts := date_trunc('week', p_from::timestamp) at time zone w.tz;
  v_to_ts := (date_trunc('week', p_to::timestamp) + interval '7 days') at time zone w.tz;

  return query
    with t as (
      select e.user_id as uid,
             date_trunc('week', e.clock_in_at at time zone w.tz)::date as wk,
             app_hidden.ask_data_worked_minutes(e.clock_in_at, e.clock_out_at, e.breaks) as mins
        from public.time_entries e
       where e.venue_id = p_venue_id and not e.is_open
         and e.clock_in_at >= v_from_ts and e.clock_in_at < v_to_ts
    ), agg as (
      select t.uid as uid, t.wk as wk, sum(t.mins)::bigint as mins
        from t group by t.uid, t.wk
       having sum(t.mins) > 40 * 60
    )
    select coalesce(app_hidden.staff_display_name(p_venue_id, a.uid), 'Unnamed team member'),
           to_char(a.wk, 'YYYY-MM-DD'),
           round(a.mins / 60.0, 2),
           round((a.mins - 40 * 60) / 60.0, 2),
           (count(*) over ())::bigint
      from agg a
     order by (a.mins - 40 * 60) desc, a.wk desc, a.uid
     limit v_limit;
end;
$$;

-- -----------------------------------------------------------------------------
-- 5. Labour: missed clock-outs (punches still open more than 16 hours after clock-in).
-- -----------------------------------------------------------------------------
create or replace function public.ask_data_missed_clock_outs(
  p_venue_id uuid,
  p_from date,
  p_to date,
  p_limit integer default 50
)
returns table (
  bucket text,
  clock_in_date text,
  hours_open numeric,
  total_buckets bigint
)
language plpgsql
stable
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  w record;
  v_limit integer := app_hidden.ask_data_limit(p_limit);
begin
  select * into w from app_hidden.ask_data_window(p_venue_id, p_from, p_to);

  return query
    with m as (
      select e.user_id as uid, e.clock_in_at as cin
        from public.time_entries e
       where e.venue_id = p_venue_id and e.is_open
         and e.clock_in_at >= w.from_ts and e.clock_in_at < w.to_ts
         and e.clock_in_at < now() - interval '16 hours'
    )
    select coalesce(app_hidden.staff_display_name(p_venue_id, m.uid), 'Unnamed team member'),
           to_char((m.cin at time zone w.tz)::date, 'YYYY-MM-DD'),
           round(extract(epoch from (now() - m.cin)) / 3600.0, 1),
           (count(*) over ())::bigint
      from m
     order by m.cin
     limit v_limit;
end;
$$;

-- -----------------------------------------------------------------------------
-- 6. Shifts: scheduled hours and open (unassigned) shifts per person, per day or in total.
-- -----------------------------------------------------------------------------
-- Cancelled shifts are left out. Shifts are placed on the venue-local date they start.
create or replace function public.ask_data_shift_hours(
  p_venue_id uuid,
  p_from date,
  p_to date,
  p_group_by text default 'person',
  p_limit integer default 50
)
returns table (
  bucket text,
  scheduled_hours numeric,
  shift_count bigint,
  open_shift_count bigint,
  total_buckets bigint
)
language plpgsql
stable
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  w record;
  v_limit integer := app_hidden.ask_data_limit(p_limit);
begin
  if p_group_by is null or p_group_by not in ('person', 'day', 'total') then
    raise exception 'unsupported group_by' using errcode = '22023';
  end if;
  select * into w from app_hidden.ask_data_window(p_venue_id, p_from, p_to);

  return query
    with s as (
      select case p_group_by
               when 'person' then coalesce(x.staff_id::text, 'open')
               when 'day' then to_char((x.start_time at time zone w.tz)::date, 'YYYY-MM-DD')
               else 'total'
             end as k,
             (x.staff_id is null) as is_open,
             extract(epoch from (x.end_time - x.start_time)) as secs
        from public.shifts x
       where x.venue_id = p_venue_id and x.status <> 'cancelled'
         and x.start_time >= w.from_ts and x.start_time < w.to_ts
    ), agg as (
      select s.k as k, sum(s.secs) as secs, count(*) as c,
             count(*) filter (where s.is_open) as o
        from s group by s.k
    ), padded as (
      select * from agg
      union all
      select 'total', 0::numeric, 0::bigint, 0::bigint
       where p_group_by = 'total' and not exists (select 1 from agg)
    )
    select case when p_group_by = 'person' and p.k = 'open' then 'Open (unassigned)'
                when p_group_by = 'person'
                  then coalesce(app_hidden.staff_display_name(p_venue_id, p.k::uuid), 'Unnamed team member')
                else p.k
           end,
           round(p.secs / 3600.0, 2), p.c, p.o,
           (count(*) over ())::bigint
      from padded p
     order by case when p_group_by = 'person' then p.secs end desc nulls last,
              case when p_group_by = 'day' then p.k end desc,
              p.k
     limit v_limit;
end;
$$;

-- -----------------------------------------------------------------------------
-- 7. Incidents: counts by severity, status or day. Titles and descriptions are never read.
-- -----------------------------------------------------------------------------
create or replace function public.ask_data_incident_summary(
  p_venue_id uuid,
  p_from date,
  p_to date,
  p_group_by text default 'severity',
  p_limit integer default 50
)
returns table (
  bucket text,
  incident_count bigint,
  unresolved_count bigint,
  total_buckets bigint
)
language plpgsql
stable
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  w record;
  v_limit integer := app_hidden.ask_data_limit(p_limit);
begin
  if p_group_by is null or p_group_by not in ('severity', 'status', 'day') then
    raise exception 'unsupported group_by' using errcode = '22023';
  end if;
  select * into w from app_hidden.ask_data_window(p_venue_id, p_from, p_to);

  return query
    with i as (
      select case p_group_by
               when 'severity' then x.severity
               when 'status' then x.status
               else to_char((x.created_at at time zone w.tz)::date, 'YYYY-MM-DD')
             end as k,
             x.status as st
        from public.incidents x
       where x.venue_id = p_venue_id
         and x.created_at >= w.from_ts and x.created_at < w.to_ts
    ), agg as (
      select i.k as k, count(*) as c,
             count(*) filter (where i.st in ('open', 'investigating')) as u
        from i group by i.k
    )
    select a.k, a.c, a.u, (count(*) over ())::bigint
      from agg a
     order by case when p_group_by = 'day' then a.k end desc, a.c desc, a.k
     limit v_limit;
end;
$$;

-- -----------------------------------------------------------------------------
-- 8. Inventory: active items whose counted stock is below par (no costs, suppliers or notes).
-- -----------------------------------------------------------------------------
create or replace function public.ask_data_low_stock(
  p_venue_id uuid,
  p_limit integer default 25
)
returns table (
  bucket text,
  unit text,
  quantity numeric,
  par_level numeric,
  shortfall numeric,
  total_buckets bigint
)
language plpgsql
stable
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_limit integer := app_hidden.ask_data_limit(p_limit);
begin
  perform app_hidden.ask_data_require_manager(p_venue_id);

  return query
    with s as (
      select i.name as nm, i.count_unit as cu,
             sum(st.quantity) as q, sum(st.par_level) as p
        from public.inventory_stock st
        join public.inventory_items i on i.id = st.inventory_item_id and i.venue_id = p_venue_id
       where st.venue_id = p_venue_id and i.is_active and st.par_level is not null
       group by i.id, i.name, i.count_unit
      having sum(st.par_level) > 0 and sum(st.quantity) < sum(st.par_level)
    )
    select s.nm, s.cu, s.q, s.p, s.p - s.q, (count(*) over ())::bigint
      from s
     order by (s.p - s.q) desc, s.nm
     limit v_limit;
end;
$$;

-- -----------------------------------------------------------------------------
-- 9. Inventory: count variance from completed counts, in total or by day.
-- -----------------------------------------------------------------------------
-- net_variance_value is counted minus expected, valued at the unit cost recorded at the time
-- (negative = shrinkage); shortfall_value adds up only the negative variances.
create or replace function public.ask_data_inventory_variance(
  p_venue_id uuid,
  p_from date,
  p_to date,
  p_group_by text default 'total',
  p_limit integer default 50
)
returns table (
  bucket text,
  count_sessions bigint,
  items_counted bigint,
  items_with_variance bigint,
  net_variance_value numeric,
  shortfall_value numeric,
  total_buckets bigint
)
language plpgsql
stable
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  w record;
  v_limit integer := app_hidden.ask_data_limit(p_limit);
begin
  if p_group_by is null or p_group_by not in ('total', 'day') then
    raise exception 'unsupported group_by' using errcode = '22023';
  end if;
  select * into w from app_hidden.ask_data_window(p_venue_id, p_from, p_to);

  return query
    with c as (
      select case p_group_by
               when 'day' then to_char((x.completed_at at time zone w.tz)::date, 'YYYY-MM-DD')
               else 'total'
             end as k,
             x.id as cid
        from public.inventory_counts x
       where x.venue_id = p_venue_id and x.status = 'completed'
         and x.completed_at >= w.from_ts and x.completed_at < w.to_ts
    ), agg as (
      select c.k as k,
             count(distinct c.cid) as sessions,
             count(ci.id) as items,
             count(ci.id) filter (where coalesce(ci.variance_quantity, 0) <> 0) as varied,
             coalesce(sum(ci.variance_value), 0) as net,
             coalesce(-sum(least(ci.variance_value, 0)), 0) as short
        from c
        left join public.inventory_count_items ci
          on ci.count_id = c.cid and ci.venue_id = p_venue_id
       group by c.k
    ), padded as (
      select * from agg
      union all
      select 'total', 0::bigint, 0::bigint, 0::bigint, 0::numeric, 0::numeric
       where p_group_by = 'total' and not exists (select 1 from agg)
    )
    select p.k, p.sessions, p.items, p.varied, round(p.net, 2), round(p.short, 2),
           (count(*) over ())::bigint
      from padded p
     order by case when p_group_by = 'day' then p.k end desc, p.k
     limit v_limit;
end;
$$;

-- -----------------------------------------------------------------------------
-- 10. Tasks: due, completed and overdue counts (titles, descriptions and assignees never read).
-- -----------------------------------------------------------------------------
-- tasks_due = non-cancelled tasks with a due date in range; overdue_count = of those, not done
-- and already past due; completed_in_range = tasks completed in range whatever their due date.
create or replace function public.ask_data_task_summary(
  p_venue_id uuid,
  p_from date,
  p_to date
)
returns table (
  tasks_due bigint,
  completed_count bigint,
  overdue_count bigint,
  still_open_count bigint,
  completed_in_range bigint
)
language plpgsql
stable
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  w record;
begin
  select * into w from app_hidden.ask_data_window(p_venue_id, p_from, p_to);

  return query
    select
      (select count(*) from public.operational_tasks t
        where t.venue_id = p_venue_id and t.status <> 'cancelled'
          and t.due_at >= w.from_ts and t.due_at < w.to_ts),
      (select count(*) from public.operational_tasks t
        where t.venue_id = p_venue_id and t.status = 'completed'
          and t.due_at >= w.from_ts and t.due_at < w.to_ts),
      (select count(*) from public.operational_tasks t
        where t.venue_id = p_venue_id and t.status in ('open', 'in_progress')
          and t.due_at >= w.from_ts and t.due_at < w.to_ts and t.due_at < now()),
      (select count(*) from public.operational_tasks t
        where t.venue_id = p_venue_id and t.status in ('open', 'in_progress')
          and t.due_at >= w.from_ts and t.due_at < w.to_ts and t.due_at >= now()),
      (select count(*) from public.operational_tasks t
        where t.venue_id = p_venue_id and t.status = 'completed'
          and t.completed_at >= w.from_ts and t.completed_at < w.to_ts);
end;
$$;

-- -----------------------------------------------------------------------------
-- 11. POS: closed-check sales totals, in total or by day (no guest or server names, no items).
-- -----------------------------------------------------------------------------
create or replace function public.ask_data_pos_sales_summary(
  p_venue_id uuid,
  p_from date,
  p_to date,
  p_group_by text default 'total',
  p_limit integer default 50
)
returns table (
  bucket text,
  check_count bigint,
  covers bigint,
  subtotal_cents bigint,
  tax_cents bigint,
  tip_cents bigint,
  total_cents bigint,
  total_buckets bigint
)
language plpgsql
stable
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  w record;
  v_limit integer := app_hidden.ask_data_limit(p_limit);
begin
  if p_group_by is null or p_group_by not in ('total', 'day') then
    raise exception 'unsupported group_by' using errcode = '22023';
  end if;
  select * into w from app_hidden.ask_data_window(p_venue_id, p_from, p_to);

  return query
    with ck as (
      select case p_group_by
               when 'day' then to_char((x.closed_at at time zone w.tz)::date, 'YYYY-MM-DD')
               else 'total'
             end as k,
             coalesce(x.guest_count, 0) as g, x.subtotal_cents as sub, x.tax_cents as tax,
             x.tip_cents as tip, x.total_cents as tot
        from public.pos_checks x
       where x.venue_id = p_venue_id and x.status = 'closed'
         and x.closed_at >= w.from_ts and x.closed_at < w.to_ts
    ), agg as (
      select ck.k as k, count(*) as c, sum(ck.g)::bigint as g, sum(ck.sub)::bigint as sub,
             sum(ck.tax)::bigint as tax, sum(ck.tip)::bigint as tip, sum(ck.tot)::bigint as tot
        from ck group by ck.k
    ), padded as (
      select * from agg
      union all
      select 'total', 0::bigint, 0::bigint, 0::bigint, 0::bigint, 0::bigint, 0::bigint
       where p_group_by = 'total' and not exists (select 1 from agg)
    )
    select p.k, p.c, p.g, p.sub, p.tax, p.tip, p.tot, (count(*) over ())::bigint
      from padded p
     order by case when p_group_by = 'day' then p.k end desc, p.k
     limit v_limit;
end;
$$;

-- -----------------------------------------------------------------------------
-- Grants: signed-in users only; each function authorises the caller itself.
-- -----------------------------------------------------------------------------
revoke all on function public.ask_data_reservation_summary(uuid, date, date, text, integer) from public, anon;
revoke all on function public.ask_data_private_event_summary(uuid, date, date, text, text, integer) from public, anon;
revoke all on function public.ask_data_labour_hours(uuid, date, date, text, integer) from public, anon;
revoke all on function public.ask_data_labour_overtime(uuid, date, date, integer) from public, anon;
revoke all on function public.ask_data_missed_clock_outs(uuid, date, date, integer) from public, anon;
revoke all on function public.ask_data_shift_hours(uuid, date, date, text, integer) from public, anon;
revoke all on function public.ask_data_incident_summary(uuid, date, date, text, integer) from public, anon;
revoke all on function public.ask_data_low_stock(uuid, integer) from public, anon;
revoke all on function public.ask_data_inventory_variance(uuid, date, date, text, integer) from public, anon;
revoke all on function public.ask_data_task_summary(uuid, date, date) from public, anon;
revoke all on function public.ask_data_pos_sales_summary(uuid, date, date, text, integer) from public, anon;

grant execute on function public.ask_data_reservation_summary(uuid, date, date, text, integer) to authenticated;
grant execute on function public.ask_data_private_event_summary(uuid, date, date, text, text, integer) to authenticated;
grant execute on function public.ask_data_labour_hours(uuid, date, date, text, integer) to authenticated;
grant execute on function public.ask_data_labour_overtime(uuid, date, date, integer) to authenticated;
grant execute on function public.ask_data_missed_clock_outs(uuid, date, date, integer) to authenticated;
grant execute on function public.ask_data_shift_hours(uuid, date, date, text, integer) to authenticated;
grant execute on function public.ask_data_incident_summary(uuid, date, date, text, integer) to authenticated;
grant execute on function public.ask_data_low_stock(uuid, integer) to authenticated;
grant execute on function public.ask_data_inventory_variance(uuid, date, date, text, integer) to authenticated;
grant execute on function public.ask_data_task_summary(uuid, date, date) to authenticated;
grant execute on function public.ask_data_pos_sales_summary(uuid, date, date, text, integer) to authenticated;

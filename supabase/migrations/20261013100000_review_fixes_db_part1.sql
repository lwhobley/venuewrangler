-- Review fixes, part 1: floor assignments, walk-in seating, stale staff/guest scope triggers,
-- and checkout single-flight. Each redefinition below is written out in full and keeps the
-- signature, language, SECURITY DEFINER and `set search_path = ''` of the last definition it
-- replaces (see the migration named in each section).

-- -----------------------------------------------------------------------------
-- 1. Floor assignments can be released.
-- 20261010150000 revoked direct writes on floor_table_assignments and nothing set released_at,
-- so a table could never be freed for the next party. release_table_assignments is the only
-- way to release, and it uses the same role set and per-table advisory lock as the assign RPC.
-- The overlap guard (guard_floor_assignment_overlap) runs on this UPDATE too; a release sets
-- released_at, so it never rejects the row being released.
-- -----------------------------------------------------------------------------
create or replace function public.release_table_assignments(
  p_venue_id uuid,
  p_table_ids uuid[],
  p_reservation_id uuid default null
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_table_id uuid;
  v_released integer;
begin
  if not app_hidden.has_venue_role(
    p_venue_id,
    array['staff', 'supervisor', 'venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
  ) then
    raise exception 'forbidden: insufficient venue permissions' using errcode = '42501';
  end if;
  if p_table_ids is null or cardinality(p_table_ids) = 0 then
    raise exception 'select one or more tables' using errcode = '22023';
  end if;

  for v_table_id in select distinct unnest(p_table_ids) order by 1 loop
    perform pg_advisory_xact_lock(hashtext('floor-table:' || p_venue_id::text || ':' || v_table_id::text));
  end loop;

  update public.floor_table_assignments as a
  set released_at = now(),
      released_reason = 'released'
  where a.venue_id = p_venue_id
    and a.table_id = any(p_table_ids)
    and a.released_at is null
    and (p_reservation_id is null or a.reservation_id = p_reservation_id);
  get diagnostics v_released = row_count;

  return v_released;
end;
$$;

revoke all on function public.release_table_assignments(uuid, uuid[], uuid) from public, anon;
grant execute on function public.release_table_assignments(uuid, uuid[], uuid) to authenticated;

-- update_floor_table_status (20261002235927): moving a table to 'available' or 'dirty' also
-- releases its unreleased assignments whose reservation is already completed, cancelled or
-- no-show, so the table is not still held by a party that has left. Other statuses are unchanged.
create or replace function public.update_floor_table_status(
  p_venue_id uuid,
  p_table_id uuid,
  p_status text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not app_hidden.has_venue_role(
    p_venue_id,
    array['staff', 'supervisor', 'venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
  ) then
    raise exception 'forbidden: insufficient venue permissions' using errcode = '42501';
  end if;

  if p_status not in ('available', 'seated', 'dirty', 'reserved', 'held', 'out_of_service') then
    raise exception 'invalid_table_status' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(hashtext('floor-table:' || p_venue_id::text || ':' || p_table_id::text));

  if p_status in ('available', 'dirty') then
    update public.floor_table_assignments as a
    set released_at = now(),
        released_reason = 'table_status'
    where a.venue_id = p_venue_id
      and a.table_id = p_table_id
      and a.released_at is null
      and a.reservation_id in (
        select r.id from public.reservations r
        where r.venue_id = p_venue_id
          and r.status in ('completed', 'cancelled', 'no_show')
      );
  end if;

  update public.floor_tables
  set
    status = p_status,
    seated_at = case when p_status = 'seated' then coalesce(seated_at, now()) else null end,
    last_activity_at = now(),
    updated_at = now()
  where venue_id = p_venue_id and id = p_table_id;
end;
$$;

-- -----------------------------------------------------------------------------
-- 14. Walk-in seating on non-reservable tables.
-- assign_tables_to_reservation (20261010150000) rejected is_reservable = false even for
-- hold_type 'seated', which is how a walk-in party is seated. Non-reservable tables are now
-- accepted for 'seated' only; out_of_service and dirty tables are still rejected for every hold.
-- -----------------------------------------------------------------------------
create or replace function public.assign_tables_to_reservation(
  p_venue_id uuid,
  p_table_ids uuid[],
  p_reservation_id uuid,
  p_hold_type text default 'reserved',
  p_starts_at timestamptz default now(),
  p_ends_at timestamptz default now() + interval '90 minutes'
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_table_id uuid;
  v_new_status text;
  v_party_size integer;
  v_table_count integer;
  v_total_capacity integer;
begin
  if not app_hidden.has_venue_role(
    p_venue_id,
    array['staff', 'supervisor', 'venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
  ) then
    raise exception 'forbidden: insufficient venue permissions' using errcode = '42501';
  end if;
  if p_table_ids is null or cardinality(p_table_ids) = 0
     or cardinality(p_table_ids) <> (select count(distinct t.id) from unnest(p_table_ids) as t(id)) then
    raise exception 'select one or more distinct tables' using errcode = '22023';
  end if;
  if p_hold_type is null or p_hold_type not in ('reserved', 'held', 'seated')
     or p_starts_at is null or p_ends_at is null or p_ends_at <= p_starts_at then
    raise exception 'invalid assignment type or time range' using errcode = '22023';
  end if;

  select r.party_size into v_party_size
  from public.reservations r
  where r.id = p_reservation_id and r.venue_id = p_venue_id;
  if v_party_size is null then
    raise exception 'reservation does not belong to this venue' using errcode = '23503';
  end if;

  select count(*)::integer, coalesce(sum(t.capacity), 0)::integer
    into v_table_count, v_total_capacity
  from public.floor_tables t
  where t.venue_id = p_venue_id and t.id = any(p_table_ids)
    and (t.is_reservable or p_hold_type = 'seated')
    and t.status not in ('out_of_service', 'dirty');
  if v_table_count <> cardinality(p_table_ids) then
    raise exception 'one or more selected tables are unavailable at this venue'
      using errcode = '22023';
  end if;
  if v_total_capacity < v_party_size then
    raise exception 'selected table capacity is below the reservation party size'
      using errcode = '23514';
  end if;

  for v_table_id in select unnest(p_table_ids) order by 1 loop
    perform pg_advisory_xact_lock(hashtext('floor-table:' || p_venue_id::text || ':' || v_table_id::text));
  end loop;

  v_new_status := case when p_hold_type = 'seated' then 'seated' else 'reserved' end;
  for v_table_id in select unnest(p_table_ids) loop
    insert into public.floor_table_assignments (
      table_id, reservation_id, hold_type, starts_at, ends_at
    ) values (
      v_table_id, p_reservation_id, p_hold_type, p_starts_at, p_ends_at
    );
  end loop;

  update public.floor_tables
  set status = v_new_status,
      seated_at = case when p_hold_type = 'seated' then p_starts_at else seated_at end,
      last_activity_at = now(),
      updated_at = now()
  where venue_id = p_venue_id and id = any(p_table_ids);
end;
$$;

revoke all on function public.assign_tables_to_reservation(uuid, uuid[], uuid, text, timestamptz, timestamptz)
  from public, anon;
grant execute on function public.assign_tables_to_reservation(uuid, uuid[], uuid, text, timestamptz, timestamptz)
  to authenticated;

-- -----------------------------------------------------------------------------
-- 15. Stale venue-scope references no longer block unrelated updates.
-- The zz_*_scope triggers (20261010153000) fire on UPDATE OF <ref>, <venue_id>, <organization_id>
-- even when the value is unchanged, so an assignment whose staff member or guest has since left
-- could not be updated at all (e.g. a status change naming the same column). These functions now
-- validate on INSERT always, and on UPDATE only when the referenced value or its venue/org scope
-- actually changed. The triggers themselves are unchanged.
-- -----------------------------------------------------------------------------
create or replace function app_hidden.enforce_venue_guest_reference()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_guest_venue_id uuid;
begin
  if new.guest_id is null then
    return new;
  end if;

  if tg_op = 'UPDATE'
     and new.guest_id is not distinct from old.guest_id
     and new.venue_id is not distinct from old.venue_id then
    return new;
  end if;

  select g.venue_id into v_guest_venue_id
  from public.guests g
  where g.id = new.guest_id;

  if v_guest_venue_id is null or v_guest_venue_id <> new.venue_id then
    raise exception 'guest reference must belong to the same venue'
      using errcode = '23503';
  end if;
  return new;
end;
$$;

create or replace function app_hidden.enforce_venue_staff_assignment()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_assigned_user_id uuid;
  v_org_id uuid;
  v_venue_id uuid;
begin
  v_assigned_user_id := nullif(to_jsonb(new)->>case
    when tg_table_name = 'shifts' then 'staff_id'
    else 'assigned_to'
  end, '')::uuid;
  if v_assigned_user_id is null then
    return new;
  end if;

  if tg_op = 'UPDATE' then
    if (to_jsonb(new)->>case when tg_table_name = 'shifts' then 'staff_id' else 'assigned_to' end)
         is not distinct from
       (to_jsonb(old)->>case when tg_table_name = 'shifts' then 'staff_id' else 'assigned_to' end)
       and (to_jsonb(new)->>'venue_id') is not distinct from (to_jsonb(old)->>'venue_id')
       and (to_jsonb(new)->>'organization_id') is not distinct from (to_jsonb(old)->>'organization_id') then
      return new;
    end if;
  end if;

  v_venue_id := (to_jsonb(new)->>'venue_id')::uuid;
  v_org_id := (to_jsonb(new)->>'organization_id')::uuid;
  if v_venue_id is null or v_org_id is null or not exists (
    select 1
    from public.memberships m
    where m.user_id = v_assigned_user_id
      and m.organization_id = v_org_id
      and (m.venue_id = v_venue_id or m.venue_id is null)
  ) then
    raise exception 'assigned staff member must belong to the same venue'
      using errcode = '23503';
  end if;
  return new;
end;
$$;

-- -----------------------------------------------------------------------------
-- 13. Checkout single-flight: a forced new attempt within 10 seconds of a recorded session
-- returns the existing key instead of rotating it, so a double-click or retry cannot create a
-- second Stripe session. Redefines 20261010161000 in full; the rotation rules are otherwise
-- unchanged (rotate when expired, or when forced and no session was recorded in the last 10s).
-- -----------------------------------------------------------------------------
create or replace function public.claim_subscription_checkout_attempt(
  p_organization_id uuid,
  p_force_new boolean default false
) returns table (idempotency_key uuid, stripe_session_id text, expires_at timestamptz)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_attempt public.subscription_checkout_attempts%rowtype;
  v_created_recently boolean;
begin
  if not exists (select 1 from public.organizations where id = p_organization_id) then
    raise exception 'organization does not exist' using errcode = '23503';
  end if;
  perform pg_advisory_xact_lock(
    hashtextextended('stripe-checkout:' || p_organization_id::text, 0)
  );
  insert into public.subscription_checkout_attempts (organization_id)
  values (p_organization_id) on conflict (organization_id) do nothing;

  select * into v_attempt
  from public.subscription_checkout_attempts
  where organization_id = p_organization_id
  for update;

  v_created_recently := v_attempt.stripe_session_id is not null
    and v_attempt.expires_at > now()
    and v_attempt.updated_at > now() - interval '10 seconds';

  if (p_force_new and not v_created_recently) or v_attempt.expires_at <= now() then
    update public.subscription_checkout_attempts
    set idempotency_key = gen_random_uuid(), stripe_session_id = null,
        expires_at = now() + interval '30 minutes', updated_at = now()
    where organization_id = p_organization_id
    returning * into v_attempt;
  end if;
  return query select v_attempt.idempotency_key, v_attempt.stripe_session_id, v_attempt.expires_at;
end;
$$;

revoke all on function public.claim_subscription_checkout_attempt(uuid, boolean) from public, anon, authenticated;
grant execute on function public.claim_subscription_checkout_attempt(uuid, boolean) to service_role;

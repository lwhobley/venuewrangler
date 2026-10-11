-- Serialize every assignment writer and reject overlapping unreleased holds.
-- This trigger also covers service-role/direct SQL writers; the RPC uses the same lock key.
create or replace function app_hidden.guard_floor_assignment_overlap()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_venue_id uuid;
begin
  select venue_id into v_venue_id
  from public.floor_tables where id = new.table_id;
  if v_venue_id is null then
    raise exception 'invalid floor table' using errcode = '23503';
  end if;

  if tg_op = 'UPDATE' then
    if old.table_id is distinct from new.table_id then
      raise exception 'an assignment cannot be moved to a different table'
        using errcode = '42501';
    end if;
  end if;
  perform pg_advisory_xact_lock(hashtext('floor-table:' || v_venue_id::text || ':' || new.table_id::text));

  if new.released_at is null and exists (
    select 1
    from public.floor_table_assignments a
    where a.table_id = new.table_id
      and a.released_at is null
      and a.id is distinct from new.id
      and tstzrange(a.starts_at, a.ends_at, '[)') &&
          tstzrange(new.starts_at, new.ends_at, '[)')
  ) then
    raise exception 'table is already assigned during this time window'
      using errcode = '23P01';
  end if;
  return new;
end;
$$;

drop trigger if exists guard_floor_assignment_overlap on public.floor_table_assignments;
create trigger guard_floor_assignment_overlap
  before insert or update of table_id, starts_at, ends_at, released_at
  on public.floor_table_assignments
  for each row execute function app_hidden.guard_floor_assignment_overlap();

-- Assignment creation must be atomic through this RPC so selected-table capacity can be
-- checked as a set. Readers retain access; authenticated clients cannot bypass the checks.
revoke insert, update, delete on public.floor_table_assignments from authenticated;
grant select on public.floor_table_assignments to authenticated;

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
    and t.is_reservable and t.status not in ('out_of_service', 'dirty');
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

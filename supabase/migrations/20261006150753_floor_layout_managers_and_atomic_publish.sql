-- Floor layout editing is a manager-tier action, and publishing a layout is all-or-nothing.
--
-- 1. Direct writes to floor_tables are limited to venue_manager / organization_owner /
--    organization_admin. Staff and supervisors keep every operational action (seat, clear,
--    merge, split, assign) because those all go through SECURITY DEFINER RPCs that do their
--    own role checks — none of them rely on the table's write policy.
-- 2. public.save_floor_layout applies a whole edit session (new, changed and removed tables)
--    in one transaction: either every change goes live or none do. It takes the same per-table
--    advisory locks as the operational RPCs, so a layout publish and a live status change on
--    the same table serialise instead of interleaving.

drop policy if exists floor_tables_write_members on public.floor_tables;

create policy floor_tables_write_managers on public.floor_tables
  for all to authenticated
  using (
    app_hidden.has_venue_role(
      venue_id,
      array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
    )
  )
  with check (
    app_hidden.has_venue_role(
      venue_id,
      array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
    )
  );

create or replace function public.save_floor_layout(
  p_venue_id uuid,
  p_floor_plan_id uuid,
  p_created jsonb default '[]'::jsonb,
  p_updated jsonb default '[]'::jsonb,
  p_removed uuid[] default '{}'::uuid[]
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_table_id uuid;
  v_row jsonb;
  v_rows integer;
  v_in_use text;
  v_duplicate text;
begin
  if not app_hidden.has_venue_role(
    p_venue_id,
    array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
  ) then
    raise exception 'forbidden: only managers can edit the floor layout' using errcode = '42501';
  end if;

  perform 1 from public.floor_plans where id = p_floor_plan_id and venue_id = p_venue_id;
  if not found then
    raise exception 'invalid_floor_plan: floor plan does not belong to this venue' using errcode = '42501';
  end if;

  -- One layout publish per plan at a time.
  perform pg_advisory_xact_lock(hashtext('floor-layout:' || p_floor_plan_id::text));

  -- Lock every existing table this publish touches, sorted to avoid deadlocks, using the same
  -- key as merge/split/assign/update_status.
  for v_table_id in
    select distinct t.id
    from (
      select unnest(coalesce(p_removed, '{}'::uuid[])) as id
      union all
      select (e ->> 'id')::uuid from jsonb_array_elements(coalesce(p_updated, '[]'::jsonb)) e
    ) t
    order by 1
  loop
    perform pg_advisory_xact_lock(hashtext('floor-table:' || p_venue_id::text || ':' || v_table_id::text));
  end loop;

  -- Removals: only tables that are free and not part of a merged group.
  if coalesce(array_length(p_removed, 1), 0) > 0 then
    select string_agg(label, ', ' order by label) into v_in_use
    from public.floor_tables
    where venue_id = p_venue_id
      and floor_plan_id = p_floor_plan_id
      and id = any(p_removed)
      and (status <> 'available' or merge_group_id is not null);
    if v_in_use is not null then
      raise exception 'tables_in_use: % cannot be removed while in use', v_in_use using errcode = '55006';
    end if;

    delete from public.floor_tables
    where venue_id = p_venue_id and floor_plan_id = p_floor_plan_id and id = any(p_removed);
  end if;

  -- Updates: layout columns only. Live status/seating is never touched here.
  for v_row in select * from jsonb_array_elements(coalesce(p_updated, '[]'::jsonb))
  loop
    update public.floor_tables
    set
      label = v_row ->> 'label',
      shape = v_row ->> 'shape',
      capacity = (v_row ->> 'capacity')::integer,
      x = (v_row ->> 'x')::double precision,
      y = (v_row ->> 'y')::double precision,
      width = (v_row ->> 'width')::double precision,
      height = (v_row ->> 'height')::double precision,
      rotation = coalesce((v_row ->> 'rotation')::double precision, 0),
      section = coalesce(nullif(v_row ->> 'section', ''), 'main'),
      updated_at = now()
    where id = (v_row ->> 'id')::uuid
      and venue_id = p_venue_id
      and floor_plan_id = p_floor_plan_id;
    get diagnostics v_rows = row_count;
    if v_rows = 0 then
      raise exception 'stale_layout: a table was removed by someone else; reload and try again'
        using errcode = '40001';
    end if;
  end loop;

  -- New tables. organization_id is filled in by trg_floor_tables_derive_org.
  insert into public.floor_tables (
    venue_id, floor_plan_id, label, shape, capacity, x, y, width, height, rotation, section
  )
  select
    p_venue_id,
    p_floor_plan_id,
    e ->> 'label',
    e ->> 'shape',
    (e ->> 'capacity')::integer,
    (e ->> 'x')::double precision,
    (e ->> 'y')::double precision,
    (e ->> 'width')::double precision,
    (e ->> 'height')::double precision,
    coalesce((e ->> 'rotation')::double precision, 0),
    coalesce(nullif(e ->> 'section', ''), 'main')
  from jsonb_array_elements(coalesce(p_created, '[]'::jsonb)) e;

  -- Labels must stay unique within the plan once everything is applied.
  select min(lower(trim(label))) into v_duplicate
  from public.floor_tables
  where floor_plan_id = p_floor_plan_id
  group by lower(trim(label))
  having count(*) > 1
  limit 1;
  if v_duplicate is not null then
    raise exception 'duplicate_label: more than one table is labelled "%"', v_duplicate
      using errcode = '23505';
  end if;
end;
$$;

revoke execute on function public.save_floor_layout(uuid, uuid, jsonb, jsonb, uuid[]) from public, anon;
grant execute on function public.save_floor_layout(uuid, uuid, jsonb, jsonb, uuid[]) to authenticated;

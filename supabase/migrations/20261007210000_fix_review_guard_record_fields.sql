-- Fixes a bug in 20261007202000_review_tenant_guards.sql: guard_review_row_update and
-- guard_crm_links are each one trigger function shared across several tables with different
-- columns. PL/pgSQL resolves a NEW/OLD field reference against the row's *actual* tuple
-- descriptor as soon as it needs that datum's value to build the underlying query for the
-- surrounding boolean expression -- this happens whether or not a preceding `tg_table_name =
-- '...' and` guard would make the overall condition false, because that value is fetched to
-- become a bound parameter, not evaluated lazily by the executor's AND short-circuiting. So
-- `tg_table_name = 'shift_swaps' and new.shift_id is distinct from old.shift_id` still throws
-- "record \"new\" has no field \"shift_id\"" on an UPDATE of operational_tasks or incidents,
-- neither of which has a shift_id column; the same function also references new.status (absent
-- from time_entries) and new.location_anomaly (absent from operational_tasks/incidents/
-- shift_swaps). guard_crm_links has the same problem with new.beo_id, which crm_beos lacks.
--
-- This was breaking every update to operational_tasks, incidents and time_entries (completing a
-- task, resolving an incident, clocking in/out, editing a break) and every insert/update to
-- crm_beos, with 42703. Confirmed by running the full pgTAP suite against a local replay: those
-- tables' RLS/trigger tests fail on current main with exactly these errors, and pass clean after
-- this fix (supabase/tests/database/operational_tasks_rls.test.sql, incidents_rls.test.sql,
-- time_clock_rls.test.sql, shift_swaps_rls.test.sql, account_deletion.test.sql,
-- crm_beo_charges.test.sql, crm_rls.test.sql).
--
-- Fix: read NEW/OLD through to_jsonb(), whose ->> operator returns SQL NULL for a key the row
-- type doesn't have instead of raising -- safe to use in a condition regardless of which table
-- fired the trigger. Business logic is unchanged from the version this replaces.

create or replace function app_hidden.guard_review_row_update()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_new jsonb := to_jsonb(new);
  v_old jsonb := to_jsonb(old);
begin
  if v_new->>'organization_id' is distinct from v_old->>'organization_id'
     or v_new->>'venue_id' is distinct from v_old->>'venue_id' then
    raise exception 'row ownership cannot be changed' using errcode = '42501';
  end if;

  if tg_table_name = 'shift_swaps' then
    if v_new->>'shift_id' is distinct from v_old->>'shift_id' then
      raise exception 'swap shift cannot be changed' using errcode = '42501';
    end if;
    if v_new->>'status' = 'accepted' and v_old->>'status' is distinct from 'accepted' then
      if v_new->>'accepted_by' is null or not exists (
        select 1 from public.memberships m
        where m.user_id = (v_new->>'accepted_by')::uuid
          and m.organization_id = (v_old->>'organization_id')::uuid
          and (m.venue_id = (v_old->>'venue_id')::uuid or m.venue_id is null)
      ) then
        raise exception 'swap accepter must belong to the shift venue'
          using errcode = '42501';
      end if;
    end if;
  end if;

  if tg_table_name = 'time_entries'
     and (v_new->>'location_anomaly' is distinct from v_old->>'location_anomaly'
          or v_new->>'shift_id' is distinct from v_old->>'shift_id')
     and coalesce(current_setting('app.time_entry_correction', true), '') <> 'on' then
    raise exception 'punch integrity fields require a manager correction' using errcode = '42501';
  end if;

  return new;
end;
$$;

create or replace function app_hidden.guard_crm_links()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_new jsonb := to_jsonb(new);
begin
  if v_new->>'lead_id' is not null and not exists (
    select 1 from public.crm_leads
    where id = (v_new->>'lead_id')::uuid and venue_id = (v_new->>'venue_id')::uuid
  ) then
    raise exception 'lead belongs to another venue' using errcode = '23503';
  end if;
  if tg_table_name = 'crm_contracts' and v_new->>'beo_id' is not null and not exists (
    select 1 from public.crm_beos
    where id = (v_new->>'beo_id')::uuid and venue_id = (v_new->>'venue_id')::uuid
  ) then
    raise exception 'BEO belongs to another venue' using errcode = '23503';
  end if;
  return new;
end;
$$;

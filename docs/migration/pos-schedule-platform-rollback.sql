-- Emergency reverse migration for pos_schedule_platform.
-- Apply through Supabase migration tooling as a NEW migration only before any
-- POS connection or platform table has data. It intentionally refuses to erase
-- integration records. If the guard fails, restore from a verified backup or
-- write a data-preserving forward fix instead.
begin;

do $$
declare
  t text;
  row_count bigint;
begin
  if exists (select 1 from public.pos_connections) then
    raise exception 'rollback_refused_pos_connections_exist';
  end if;
  foreach t in array array[
    'pos_connection_capabilities', 'pos_location_mappings',
    'pos_employee_mappings', 'pos_job_mappings', 'pos_external_shift_mappings',
    'pos_schedule_versions', 'pos_outbound_jobs', 'pos_sync_conflicts',
    'pos_sales', 'pos_time_entries', 'pos_sync_runs', 'pos_audit_events'
  ] loop
    execute format('select count(*) from public.%I', t) into row_count;
    if row_count <> 0 then
      raise exception 'rollback_refused_nonempty_table: %', t;
    end if;
  end loop;
end $$;

drop trigger protect_pos_shift_delete on public.shifts;
drop function app_hidden.protect_pos_shift_delete();
drop function public.remove_or_cancel_shift(uuid);
drop function public.fail_pos_outbound_job(uuid, text, boolean, boolean);
drop function public.ack_pos_outbound_job(uuid, text, text);
drop function public.claim_pos_outbound_jobs(integer);
drop function public.publish_pos_schedule(uuid);
drop function public.request_pos_connection(uuid, text);

drop table public.pos_audit_events;
drop table public.pos_sync_runs;
drop table public.pos_time_entries;
drop table public.pos_sales;
drop table public.pos_sync_conflicts;
drop table public.pos_outbound_jobs;
drop table public.pos_schedule_versions;
drop table public.pos_external_shift_mappings;
drop table public.pos_job_mappings;
drop table public.pos_employee_mappings;
drop table public.pos_location_mappings;
drop table public.pos_connection_capabilities;

alter table public.pos_connections drop constraint pos_connection_readiness_check;
alter table public.pos_connections
  drop column product,
  drop column readiness,
  drop column credential_ref,
  drop column last_inbound_at,
  drop column last_outbound_at;

revoke all on public.pos_connections from authenticated;
grant select (id, organization_id, venue_id, provider, external_location_id,
  status, last_sync_at, created_at, updated_at)
  on public.pos_connections to authenticated;
grant insert on public.pos_outbound_commands to authenticated;

commit;

-- Cover foreign keys introduced by pos_schedule_platform so deletes and joins
-- remain efficient as integration history grows.
create index pos_audit_events_actor_id_idx
  on public.pos_audit_events (actor_id);
create index pos_audit_events_connection_id_idx
  on public.pos_audit_events (connection_id);
create index pos_employee_mappings_staff_id_idx
  on public.pos_employee_mappings (staff_id);
create index pos_external_shift_mappings_shift_id_idx
  on public.pos_external_shift_mappings (shift_id);
create index pos_location_mappings_venue_id_idx
  on public.pos_location_mappings (venue_id);
create index pos_outbound_jobs_shift_id_idx
  on public.pos_outbound_jobs (shift_id);
create index pos_schedule_versions_published_by_idx
  on public.pos_schedule_versions (published_by);
create index pos_sync_conflicts_connection_id_idx
  on public.pos_sync_conflicts (connection_id);
create index pos_sync_conflicts_shift_id_idx
  on public.pos_sync_conflicts (shift_id);
create index pos_sync_runs_connection_id_idx
  on public.pos_sync_runs (connection_id);

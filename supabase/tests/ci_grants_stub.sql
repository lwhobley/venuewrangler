-- CI-only fixture, applied AFTER supabase/migrations/*.sql: grants the broad table-level
-- privileges a real Supabase project gives anon/authenticated by default. Real Supabase
-- relies on RLS (not GRANT) to do row-level filtering, so this makes the CI stub match
-- production behavior for the authorization tests under supabase/tests/database. See
-- ci_auth_stub.sql for why this exists.

grant select, insert, update, delete on all tables in schema public to authenticated;
grant select on all tables in schema public to anon;
grant usage on all sequences in schema public to authenticated;

-- payroll_connections' own migration (20261002140000) narrows `authenticated` to a
-- column-level grant excluding its encrypted token columns, immediately after creating the
-- table — on a real Supabase project that narrowing is the last word, since the broad
-- default-privilege grant this stub simulates would already have been in effect BEFORE the
-- migration ran (Supabase applies it via `ALTER DEFAULT PRIVILEGES` at table-creation time,
-- not as a one-off step after every migration like this CI stub has to). Re-apply the same
-- narrowing here, after this stub's blanket grant, so the authorization tests see the same
-- end state a real project would.
revoke all on public.payroll_connections from authenticated;
grant select (
  id, organization_id, venue_id, provider, status, external_account_id,
  token_expires_at, last_error, connected_by, created_at, updated_at
) on public.payroll_connections to authenticated;

-- storage_deletion_jobs is internal/service-role only
revoke all on public.storage_deletion_jobs from authenticated, anon;

-- pos_connections' own migration (20261002270000) narrows `authenticated` to a column-level
-- grant excluding webhook_secret_hash/credentials_encrypted, for the same reason
-- payroll_connections does above. Re-apply it here so local tests see the real end state.
revoke all on public.pos_connections from authenticated;
grant select (
  id, organization_id, venue_id, provider, product, external_location_id, status,
  readiness, last_sync_at, last_inbound_at, last_outbound_at, created_at, updated_at
) on public.pos_connections to authenticated;

-- The POS schedule migration revokes client writes to its state and the unsupported
-- legacy menu queue. Reapply after this stub's broad compatibility grant.
revoke insert on public.pos_outbound_commands from authenticated;
do $$ declare t text; begin
  foreach t in array array['pos_connection_capabilities','pos_location_mappings',
    'pos_employee_mappings','pos_job_mappings','pos_external_shift_mappings',
    'pos_schedule_versions','pos_outbound_jobs','pos_sync_conflicts',
    'pos_sales','pos_time_entries','pos_sync_runs','pos_audit_events'] loop
    execute format('revoke all on public.%I from anon, authenticated', t);
    execute format('grant select on public.%I to authenticated', t);
  end loop;
end $$;

-- reservation_connections' own migration (20261002250000) does the same narrowing for its
-- webhook_secret_hash column; webhook_replay_log is revoked entirely (service-role only).
revoke all on public.reservation_connections from authenticated;
grant select (
  id, organization_id, venue_id, provider, status, created_at, updated_at
) on public.reservation_connections to authenticated;
revoke all on public.webhook_replay_log from authenticated, anon;

-- notification_events' hardening migration (20261003005000) narrows `authenticated` to
-- update only read_at (clients may mark a notification read, never rewrite its contents).
-- Re-apply the same narrowing here for the same reason as the tables above.
revoke update on public.notification_events from authenticated;
grant update (read_at) on public.notification_events to authenticated;

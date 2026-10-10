-- Data retention runs inside the database on pg_cron instead of an external Google Cloud Run
-- job (.github/workflows/retention-cleanup.yml, removed). That job belonged to the legacy API
-- and needed a GCP project and service account; this needs nothing outside Supabase.
--
-- Windows follow docs/soc2/data-retention-disposal-policy.md:
--   * audit_log: 365 days.
--   * attestation_challenges: single-use and valid for minutes; expired rows are removed once
--     they are an hour past expiry (verification already rejects them on expires_at).
--   * retained_time_entries: FLSA three-year payroll history, counted from when the shift ended
--     (or started, for a punch that was never closed).

create or replace function app_hidden.run_retention_cleanup()
returns table (audit_log_deleted bigint, attestation_challenges_deleted bigint,
  retained_time_entries_deleted bigint)
language plpgsql security definer set search_path = '' as $$
declare
  v_audit bigint;
  v_challenges bigint;
  v_wage bigint;
begin
  delete from public.audit_log where created_at < now() - interval '365 days';
  get diagnostics v_audit = row_count;

  delete from public.attestation_challenges where expires_at < now() - interval '1 hour';
  get diagnostics v_challenges = row_count;

  delete from public.retained_time_entries
    where coalesce(clock_out_at, clock_in_at) < now() - interval '3 years';
  get diagnostics v_wage = row_count;

  return query select v_audit, v_challenges, v_wage;
end;
$$;

revoke all on function app_hidden.run_retention_cleanup() from public, anon, authenticated;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    if exists (select 1 from cron.job where jobname = 'retention-cleanup') then
      perform cron.unschedule('retention-cleanup');
    end if;
    -- 06:17 UTC daily, the same time the external job ran.
    perform cron.schedule(
      'retention-cleanup',
      '17 6 * * *',
      'select app_hidden.run_retention_cleanup();'
    );
  end if;
exception when others then
  null;
end;
$$;

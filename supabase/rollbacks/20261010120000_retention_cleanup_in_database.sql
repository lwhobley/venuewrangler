-- Removes the in-database retention job. Nothing purges these tables afterwards.

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron')
     and exists (select 1 from cron.job where jobname = 'retention-cleanup') then
    perform cron.unschedule('retention-cleanup');
  end if;
exception when others then
  null;
end;
$$;

drop function if exists app_hidden.run_retention_cleanup();

-- The batch worker function for storage_deletion_jobs (media-cleanup), plus its pg_cron
-- schedule. Split out from 20261002230000_storage_deletion_jobs_schema.sql because the live
-- Supabase SQL execution tool repeatedly timed out on this specific function body during the
-- batch-2 review (a dozen+ attempts across both apply_migration and execute_sql, including a
-- shortened reproduction, while every other statement in that batch succeeded normally) — this
-- was applied manually via the Supabase SQL editor instead. Everything else in that migration
-- (the table, RLS, the path safety-guard function, the insert trigger) was applied normally.
--
-- pg_cron was not yet installed on the live project when this was first attempted; enabled it
-- here, per the original migration's own documented fallback for that case. pg_cron is not
-- available at all in a vanilla local Postgres (no contrib package), so both the extension
-- creation and the schedule call are guarded the same way the Realtime publication fix in
-- floor_schema.sql is — local CI verification must not depend on a platform-managed extension.
do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    create extension if not exists pg_cron with schema extensions;
  end if;
exception when others then
  null;
end;
$$;

create or replace function app_hidden.process_storage_deletion_batch(
  p_batch_size integer default 10
) returns table (
  processed_count integer,
  completed_count integer,
  failed_count integer,
  dead_count integer
)
language plpgsql
security definer
set search_path = public, storage
as $$
declare
  r record;
  v_processed integer := 0;
  v_completed integer := 0;
  v_failed integer := 0;
  v_dead integer := 0;
begin
  perform set_config('storage.allow_delete_query', 'true', true);

  for r in
    select id, bucket_id, object_path, attempts
    from public.storage_deletion_jobs
    where status in ('pending', 'failed')
      and attempts < 10
    order by created_at asc
    limit p_batch_size
    for update skip locked
  loop
    v_processed := v_processed + 1;

    if not app_hidden.is_safe_storage_deletion_path(r.bucket_id, r.object_path) then
      update public.storage_deletion_jobs
      set status = 'dead',
          attempts = attempts + 1,
          last_error = 'Refusing to delete key not matching the expected storage-path format',
          updated_at = now()
      where id = r.id;
      v_dead := v_dead + 1;
      continue;
    end if;

    begin
      update public.storage_deletion_jobs
      set status = 'processing',
          attempts = attempts + 1,
          updated_at = now()
      where id = r.id;

      delete from storage.objects
      where bucket_id = r.bucket_id
        and name = r.object_path;

      update public.storage_deletion_jobs
      set status = 'completed',
          completed_at = now(),
          last_error = null,
          updated_at = now()
      where id = r.id;
      v_completed := v_completed + 1;

    exception when others then
      if r.attempts + 1 >= 10 then
        update public.storage_deletion_jobs
        set status = 'dead',
            last_error = substring(sqlerrm from 1 for 1000),
            updated_at = now()
        where id = r.id;
        v_dead := v_dead + 1;
      else
        update public.storage_deletion_jobs
        set status = 'failed',
            last_error = substring(sqlerrm from 1 for 1000),
            updated_at = now()
        where id = r.id;
        v_failed := v_failed + 1;
      end if;
    end;
  end loop;

  return query select v_processed, v_completed, v_failed, v_dead;
end;
$$;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    if exists (select 1 from cron.job where jobname = 'storage-deletion-worker') then
      perform cron.unschedule('storage-deletion-worker');
    end if;

    perform cron.schedule(
      'storage-deletion-worker',
      '*/10 * * * *',
      'select * from app_hidden.process_storage_deletion_batch(25);'
    );
  end if;
exception when others then
  null;
end;
$$;

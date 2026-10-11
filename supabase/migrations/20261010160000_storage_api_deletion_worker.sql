-- Use Supabase Storage's API to remove object bytes. Deleting storage.objects rows with SQL
-- does not invoke the Storage object deletion protocol and may leave inaccessible bytes.
create or replace function public.claim_storage_deletion_jobs(p_limit integer default 25)
returns table (id uuid, bucket_id text, object_path text, attempts integer)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_job record;
begin
  for v_job in
    select j.id, j.bucket_id, j.object_path, j.attempts
    from public.storage_deletion_jobs j
    where j.attempts < 10
      and (
        j.status in ('pending', 'failed')
        or (j.status = 'processing' and j.updated_at < now() - interval '15 minutes')
      )
    order by j.created_at
    limit greatest(1, least(coalesce(p_limit, 25), 100))
    for update skip locked
  loop
    if not app_hidden.is_safe_storage_deletion_path(v_job.bucket_id, v_job.object_path) then
      update public.storage_deletion_jobs as j
      set status = 'dead', attempts = j.attempts + 1,
          last_error = 'Refusing to delete key not matching the expected storage-path format',
          updated_at = now()
      where j.id = v_job.id;
      continue;
    end if;

    return query
    update public.storage_deletion_jobs as j
    set status = 'processing', attempts = j.attempts + 1, updated_at = now()
    where j.id = v_job.id
    returning j.id, j.bucket_id, j.object_path, j.attempts;
  end loop;
end;
$$;

revoke all on function public.claim_storage_deletion_jobs(integer) from public, anon, authenticated;
grant execute on function public.claim_storage_deletion_jobs(integer) to service_role;

create or replace function app_hidden.dispatch_storage_deletion_batch(p_batch_size integer default 25)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_url text;
  v_secret text;
  v_request_id bigint;
begin
  select decrypted_secret into v_url
  from vault.decrypted_secrets where name = 'storage_deletion_dispatch_url';
  select decrypted_secret into v_secret
  from vault.decrypted_secrets where name = 'storage_deletion_dispatch_secret';
  if coalesce(v_url, '') = '' or coalesce(v_secret, '') = '' then
    raise exception 'storage deletion worker dispatch secrets are not configured';
  end if;

  select net.http_post(
    url := v_url,
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-dispatch-secret', v_secret
    ),
    body := jsonb_build_object('batch_size', greatest(1, least(coalesce(p_batch_size, 25), 100))),
    timeout_milliseconds := 10000
  ) into v_request_id;
  return v_request_id;
end;
$$;

revoke all on function app_hidden.dispatch_storage_deletion_batch(integer) from public, anon, authenticated;

-- Preserve the old cron entry point but make it dispatch to the API worker instead of
-- claiming jobs and deleting Storage metadata rows inside Postgres.
create or replace function app_hidden.process_storage_deletion_batch(p_batch_size integer default 10)
returns table (processed_count integer, completed_count integer, failed_count integer, dead_count integer)
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform app_hidden.dispatch_storage_deletion_batch(p_batch_size);
  return query select 0, 0, 0, 0;
end;
$$;

revoke all on function app_hidden.process_storage_deletion_batch(integer) from public, anon, authenticated;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    if exists (select 1 from cron.job where jobname = 'storage-deletion-worker') then
      perform cron.unschedule('storage-deletion-worker');
    end if;
    if exists (select 1 from pg_extension where extname = 'pg_net')
       and exists (select 1 from vault.decrypted_secrets where name = 'storage_deletion_dispatch_url')
       and exists (select 1 from vault.decrypted_secrets where name = 'storage_deletion_dispatch_secret') then
      perform cron.schedule(
        'storage-deletion-worker', '*/10 * * * *',
        'select * from app_hidden.process_storage_deletion_batch(25);'
      );
    end if;
  end if;
end;
$$;

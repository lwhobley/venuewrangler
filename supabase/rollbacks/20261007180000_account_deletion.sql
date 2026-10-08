-- Manual reverse migration. Refuses to discard retained wage records or in-flight deletion
-- jobs; export and reconcile them before rollback.
begin;
do $$
begin
  if exists (select 1 from public.retained_time_entries limit 1) then
    raise exception 'retained_time_entries contains data; export and reconcile it before rollback';
  end if;
  if exists (select 1 from public.account_deletion_jobs where status not in ('completed', 'dead') limit 1) then
    raise exception 'account_deletion_jobs has unresolved jobs; let them finish or fail before rollback';
  end if;
end;
$$;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    if exists (select 1 from cron.job where jobname = 'account-deletion-sweep') then
      perform cron.unschedule('account-deletion-sweep');
    end if;
  end if;
exception when others then
  null;
end;
$$;

revoke all on function public.request_account_deletion(text) from authenticated;
drop function if exists public.request_account_deletion(text);
drop function if exists app_hidden.sweep_account_deletion_jobs(integer);
drop function if exists app_hidden.dispatch_account_deletion_job(uuid);

alter table public.storage_deletion_jobs drop constraint storage_deletion_jobs_bucket_id_check;
alter table public.storage_deletion_jobs add constraint storage_deletion_jobs_bucket_id_check
  check (bucket_id in ('incident-evidence', 'checklist-evidence', 'staff-documents', 'exports', 'temp-imports', 'chat', 'profile-photos'));

-- Keep profile photos in the allowlist; queued photo deletions may already exist.
create or replace function app_hidden.is_safe_storage_deletion_path(
  p_bucket_id text,
  p_object_path text
) returns boolean
language plpgsql
immutable
set search_path = public
as $$
begin
  if p_bucket_id not in ('incident-evidence', 'checklist-evidence', 'staff-documents', 'exports', 'temp-imports', 'chat', 'profile-photos') then
    return false;
  end if;

  if p_object_path like '%..%' or p_object_path like '/%' or p_object_path like '%//%' then
    return false;
  end if;

  if p_bucket_id = 'chat' then
    if p_object_path ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[a-zA-Z0-9_\-\.]+$' then
      return true;
    end if;
    if p_object_path ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/)?[a-zA-Z0-9_\-\.]+$' then
      return true;
    end if;
    return false;
  end if;

  if not (p_object_path ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/)?[a-zA-Z0-9_\-\.]+$') then
    return false;
  end if;

  return true;
end;
$$;

drop table if exists public.account_deletion_jobs;
drop table if exists public.retained_time_entries;
commit;

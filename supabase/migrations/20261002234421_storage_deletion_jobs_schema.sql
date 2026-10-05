-- Phase 4 feature: media-cleanup deletion-queue worker (storage_deletion_jobs).
-- Internal worker queue table for durable object deletion.
-- RLS: service-role only; no policies for authenticated or anon.
-- Safety guard: strictly enforces server-generated Storage object path format.

create table if not exists public.storage_deletion_jobs (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  venue_id uuid references public.venues (id) on delete set null,
  bucket_id text not null check (bucket_id in ('incident-evidence', 'checklist-evidence', 'staff-documents', 'exports', 'temp-imports', 'chat')),
  object_path text not null check (char_length(trim(object_path)) > 0),
  status text not null default 'pending' check (status in ('pending', 'processing', 'completed', 'failed', 'dead')),
  attempts integer not null default 0 check (attempts >= 0 and attempts <= 10),
  last_error text,
  completed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists storage_deletion_jobs_queue_idx
  on public.storage_deletion_jobs (status, created_at)
  where status in ('pending', 'failed');

create index if not exists storage_deletion_jobs_org_venue_idx
  on public.storage_deletion_jobs (organization_id, venue_id);

-- ---------------------------------------------------------------------------
-- Safety path guard: prevents client-controlled or arbitrary path deletion
-- Pattern strictly expects:
--   {org_id}/{venue_id}/{filename} or {org_id}/{filename}
-- where org_id and venue_id are UUIDs, and filename is safe alphanumeric with dashes/underscores/dots.
-- Disallows any directory traversal (..) or leading/consecutive slashes.
-- ---------------------------------------------------------------------------

create or replace function app_hidden.is_safe_storage_deletion_path(
  p_bucket_id text,
  p_object_path text
) returns boolean
language plpgsql
immutable
as $$
begin
  if p_bucket_id not in ('incident-evidence', 'checklist-evidence', 'staff-documents', 'exports', 'temp-imports', 'chat') then
    return false;
  end if;

  if p_object_path like '%..%' or p_object_path like '/%' or p_object_path like '%//%' then
    return false;
  end if;

  -- Regex matches: uuid/uuid/filename OR uuid/filename
  if not (p_object_path ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/)?[a-zA-Z0-9_\-\.]+$') then
    return false;
  end if;

  return true;
end;
$$;

-- ---------------------------------------------------------------------------
-- Trigger: derive organization_id and validate safe path on insert/update
-- ---------------------------------------------------------------------------

create or replace function app_hidden.prepare_storage_deletion_job_insert()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  -- Validate safety path
  if not app_hidden.is_safe_storage_deletion_path(new.bucket_id, new.object_path) then
    raise exception 'Refusing to queue storage path not matching allowed format'
      using errcode = '42501';
  end if;

  -- Derive organization_id from venue_id if needed
  if new.organization_id is null and new.venue_id is not null then
    select organization_id into new.organization_id
    from public.venues
    where id = new.venue_id;
  end if;

  if new.organization_id is null then
    raise exception 'storage_deletion_jobs requires an organization_id'
      using errcode = '23502';
  end if;

  -- Cap attempts and mark dead if exceeded
  if new.attempts >= 10 then
    new.status := 'dead';
  end if;

  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists prepare_storage_deletion_job_insert on public.storage_deletion_jobs;
create trigger prepare_storage_deletion_job_insert
  before insert or update on public.storage_deletion_jobs
  for each row execute function app_hidden.prepare_storage_deletion_job_insert();

-- ---------------------------------------------------------------------------
-- RLS: Service-role only. No access for authenticated or anon.
-- ---------------------------------------------------------------------------

alter table public.storage_deletion_jobs enable row level security;
alter table public.storage_deletion_jobs force row level security;

revoke all on public.storage_deletion_jobs from authenticated, anon;

-- ---------------------------------------------------------------------------
-- Batch processing worker function
-- Claims pending/failed jobs with FOR UPDATE SKIP LOCKED and deletes objects.
-- ---------------------------------------------------------------------------

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
  -- Enable internal deletion query for storage.objects
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

    -- Safety check guard inside worker
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

      -- Remove row from storage.objects
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

-- ---------------------------------------------------------------------------
-- pg_cron schedule: run deletion worker batch every 10 minutes if pg_cron is enabled
-- ---------------------------------------------------------------------------

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

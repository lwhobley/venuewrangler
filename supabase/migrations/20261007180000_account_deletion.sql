-- Self-serve "delete my account" — App Store/Play Store require every app that supports
-- account creation to let a user delete their own account in-app (see
-- docs/soc2/data-retention-disposal-policy.md §4). This implements the *personal* deletion
-- path only ("Non-owner account deletion removes only that user's account and profile") —
-- full tenant/organization offboarding (the other half of §4: cascading an entire venue's
-- data and cancelling its Stripe subscription) is a separate, much larger and more
-- destructive feature and is deliberately out of scope here. A user who is the sole
-- organization_owner of any organization is blocked from self-deleting below, with a message
-- telling them to add another owner first, rather than silently orphaning that organization.
--
-- auth.users itself can only be deleted through Supabase's Auth Admin API (GoTrue), which has
-- no SQL-level equivalent — a plain `delete from auth.users` would bypass GoTrue's own
-- session/refresh-token bookkeeping. So this migration does the synchronous, transactional,
-- RLS-governed part here (preserve what must be retained, anonymize what must survive, clear
-- what mustn't, block the sole-owner case) and hands the final auth.users deletion to a
-- queued Edge Function call, mirroring storage_deletion_jobs' durable retry/escalation shape
-- and notification_triggers_and_dispatch's pg_net-to-Edge-Function dispatch.

-- ---------------------------------------------------------------------------
-- 1. Wage-record retention (FLSA §516.2): a departing user's time_entries would otherwise
--    cascade-delete the moment auth.users is removed (time_entries.user_id references
--    auth.users(id) on delete cascade). Copy them here first — no FK to auth.users, venues or
--    organizations, so this table survives both this deletion and any future venue/org
--    deletion, matching data-retention-disposal-policy.md §4.5's RetainedTimeEntry.
-- ---------------------------------------------------------------------------
create table public.retained_time_entries (
  id uuid primary key default gen_random_uuid(),
  original_time_entry_id uuid not null,
  organization_id uuid,
  venue_id uuid,
  anonymized_user_label text not null,
  shift_id uuid,
  clock_in_at timestamptz not null,
  clock_out_at timestamptz,
  breaks jsonb not null default '[]'::jsonb,
  location_anomaly text,
  retention_reason text not null default 'account_deletion',
  retained_at timestamptz not null default now()
);

create index retained_time_entries_org_venue_idx
  on public.retained_time_entries (organization_id, venue_id);

alter table public.retained_time_entries enable row level security;
alter table public.retained_time_entries force row level security;
-- Service-role/direct DB access only for now — no payroll-export UI reads this yet. Add an
-- organization_owner/organization_admin select policy when that feature exists.
revoke all on public.retained_time_entries from authenticated, anon;

-- ---------------------------------------------------------------------------
-- 2. Durable job queue for the one step that can't happen in this transaction: actually
--    deleting the auth.users row via the Auth Admin API. Same shape as storage_deletion_jobs.
-- ---------------------------------------------------------------------------
create table public.account_deletion_jobs (
  id uuid primary key default gen_random_uuid(),
  -- Not a foreign key: the whole point of this row is to outlive (and drive the deletion of)
  -- the auth.users row it names, not react to that row disappearing.
  user_id uuid not null,
  requested_reason text,
  status text not null default 'pending' check (status in ('pending', 'processing', 'completed', 'failed', 'dead')),
  attempts integer not null default 0 check (attempts >= 0 and attempts <= 10),
  last_error text,
  completed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index account_deletion_jobs_queue_idx
  on public.account_deletion_jobs (status, created_at)
  where status in ('pending', 'failed');

alter table public.account_deletion_jobs enable row level security;
alter table public.account_deletion_jobs force row level security;
revoke all on public.account_deletion_jobs from authenticated, anon;

-- ---------------------------------------------------------------------------
-- 3. Let the storage-deletion worker also purge profile photos (storage_path is always
--    {org}/{venue}/{user}.photo — already matches the worker's generic 2-segment safety
--    pattern, see app_hidden.is_safe_storage_deletion_path, so only the bucket allowlists
--    need extending, not the path regex itself).
-- ---------------------------------------------------------------------------
alter table public.storage_deletion_jobs drop constraint storage_deletion_jobs_bucket_id_check;
alter table public.storage_deletion_jobs add constraint storage_deletion_jobs_bucket_id_check
  check (bucket_id in ('incident-evidence', 'checklist-evidence', 'staff-documents', 'exports', 'temp-imports', 'chat', 'profile-photos'));

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
    -- Legacy 3-segment chat objects (pre-scoping) still deletable.
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

-- ---------------------------------------------------------------------------
-- 4. pg_net dispatch to the account-deletion-worker Edge Function, same shape as
--    app_hidden.dispatch_notification_push. A dispatch failure must never block the
--    deletion request itself — the pg_cron sweep below is the safety net for that.
-- ---------------------------------------------------------------------------
do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_net') then
    create extension if not exists pg_net with schema extensions;
  end if;
exception when others then
  null;
end;
$$;

create or replace function app_hidden.dispatch_account_deletion_job(p_job_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_url text;
  v_secret text;
begin
  select decrypted_secret into v_url from vault.decrypted_secrets where name = 'account_deletion_dispatch_url';
  select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'account_deletion_dispatch_secret';
  if v_url is null or v_secret is null then
    return;
  end if;

  perform net.http_post(
    url := v_url,
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-dispatch-secret', v_secret),
    body := jsonb_build_object('job_id', p_job_id),
    timeout_milliseconds := 5000
  );
exception when others then
  raise warning 'account deletion dispatch failed for job %: %', p_job_id, sqlerrm;
end;
$$;

-- Safety net: re-dispatch anything still pending/failed a while after the immediate call
-- above (dropped request, cold Edge Function, transient pg_net issue). Mirrors
-- process_storage_deletion_batch's claim/attempts/dead-letter shape, but only re-sends the
-- HTTP call — the worker Edge Function itself owns marking a job completed/failed/dead,
-- since net.http_post is fire-and-forget and this function never sees the response.
create or replace function app_hidden.sweep_account_deletion_jobs(
  p_batch_size integer default 25
) returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  r record;
  v_dispatched integer := 0;
begin
  for r in
    select id
    from public.account_deletion_jobs
    where status in ('pending', 'failed')
      and attempts < 10
      and updated_at < now() - interval '10 minutes'
    order by created_at asc
    limit p_batch_size
    for update skip locked
  loop
    perform app_hidden.dispatch_account_deletion_job(r.id);
    v_dispatched := v_dispatched + 1;
  end loop;

  return v_dispatched;
end;
$$;

do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    create extension if not exists pg_cron with schema extensions;
  end if;
exception when others then
  null;
end;
$$;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    if exists (select 1 from cron.job where jobname = 'account-deletion-sweep') then
      perform cron.unschedule('account-deletion-sweep');
    end if;

    perform cron.schedule(
      'account-deletion-sweep',
      '*/10 * * * *',
      'select app_hidden.sweep_account_deletion_jobs(25);'
    );
  end if;
exception when others then
  null;
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. public.request_account_deletion: the client-facing RPC.
-- ---------------------------------------------------------------------------
create or replace function public.request_account_deletion(p_reason text default null)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_label text;
  v_sole_owner_orgs integer;
  v_photo record;
  v_job_id uuid;
begin
  if v_uid is null then
    raise exception 'Must be signed in to delete your account' using errcode = '42501';
  end if;

  -- Block if this account is the only organization_owner of any organization: deleting it
  -- would leave that organization with no owner at all. They must add another
  -- organization_owner membership before they can self-delete.
  select count(*) into v_sole_owner_orgs
  from public.memberships m1
  where m1.user_id = v_uid
    and m1.role = 'organization_owner'
    and not exists (
      select 1 from public.memberships m2
      where m2.organization_id = m1.organization_id
        and m2.role = 'organization_owner'
        and m2.user_id <> v_uid
    );

  if v_sole_owner_orgs > 0 then
    raise exception 'You are the only owner of % organization(s). Add another organization owner before deleting your account.', v_sole_owner_orgs
      using errcode = '42501';
  end if;

  v_label := 'deleted_user_' || v_uid::text;

  -- Preserve wage history (FLSA §516.2) before it would otherwise cascade away.
  insert into public.retained_time_entries (
    original_time_entry_id, organization_id, venue_id, anonymized_user_label,
    shift_id, clock_in_at, clock_out_at, breaks, location_anomaly
  )
  select
    te.id, te.organization_id, te.venue_id, v_label,
    te.shift_id, te.clock_in_at, te.clock_out_at, te.breaks, te.location_anomaly
  from public.time_entries te
  where te.user_id = v_uid;

  -- Queue the actual profile photo file(s) for deletion from Storage before dropping the
  -- row that names them (storage_deletion_jobs.venue_id is nullable/set-null, so this
  -- survives a later venue deletion too).
  for v_photo in
    select organization_id, venue_id, storage_path
    from public.staff_photos sp
    join public.venues v on v.id = sp.venue_id
    where sp.user_id = v_uid
  loop
    insert into public.storage_deletion_jobs (organization_id, venue_id, bucket_id, object_path)
    values (v_photo.organization_id, v_photo.venue_id, 'profile-photos', v_photo.storage_path);
  end loop;

  -- Anonymize attribution on records that must survive this account's departure.
  -- audit_log is append-only and retained independently (see data-retention-disposal-
  -- policy.md §3) — the row itself stays, only who-did-it is forgotten.
  update public.audit_log set actor_user_id = null where actor_user_id = v_uid;
  update public.organizations set created_by = null where created_by = v_uid;
  update public.venues set created_by = null where created_by = v_uid;
  update public.memberships set created_by = null where created_by = v_uid;
  update public.operational_tasks set assigned_to = null where assigned_to = v_uid;
  update public.operational_tasks set created_by = null where created_by = v_uid;
  update public.checklist_templates set created_by = null where created_by = v_uid;
  update public.checklist_completions set completed_by = null where completed_by = v_uid;
  update public.incidents set reported_by = null where reported_by = v_uid;
  update public.incidents set resolved_by = null where resolved_by = v_uid;
  update public.incident_attachments set uploaded_by = null where uploaded_by = v_uid;
  update public.ai_usage_events set user_id = null where user_id = v_uid;
  update public.invites set invited_by = null where invited_by = v_uid;
  update public.inventory_items set updated_by = null where updated_by = v_uid;
  update public.shifts set staff_id = null where staff_id = v_uid;
  update public.shifts set created_by = null where created_by = v_uid;
  update public.payroll_connections set connected_by = null where connected_by = v_uid;
  update public.events set created_by = null where created_by = v_uid;
  update public.documents set uploaded_by = null where uploaded_by = v_uid;
  update public.pos_schedule_versions set published_by = null where published_by = v_uid;

  -- Workflow rows that are this user's own in-flight requests, not records anyone else needs
  -- attributable (unlike audit_log/time_entries above) — removed outright rather than
  -- anonymized. shift_swaps.requested_by and pos_employee_mappings.staff_id are both NOT
  -- NULL with no ON DELETE action, so they can't simply be set to null.
  delete from public.shift_swaps where requested_by = v_uid;
  update public.shift_swaps set offered_to = null where offered_to = v_uid;
  update public.shift_swaps set accepted_by = null where accepted_by = v_uid;
  delete from public.pos_employee_mappings where staff_id = v_uid;

  -- Drop this account's own memberships, time entries, HR profile, photos and profile now
  -- (would cascade from the eventual auth.users delete anyway; doing it here means the
  -- account is already functionally gone even before the async job runs).
  delete from public.time_entries where user_id = v_uid;
  delete from public.memberships where user_id = v_uid;
  delete from public.employee_hr_profiles where user_id = v_uid;
  delete from public.staff_photos where user_id = v_uid;
  delete from public.profiles where id = v_uid;

  insert into public.audit_log (actor_user_id, action, target_table, target_id, metadata)
  values (null, 'account.delete_requested', 'auth.users', v_uid, jsonb_build_object('reason', p_reason));

  insert into public.account_deletion_jobs (user_id, requested_reason)
  values (v_uid, p_reason)
  returning id into v_job_id;

  perform app_hidden.dispatch_account_deletion_job(v_job_id);

  return v_job_id;
end;
$$;

revoke all on function public.request_account_deletion(text) from public, anon;
grant execute on function public.request_account_deletion(text) to authenticated;

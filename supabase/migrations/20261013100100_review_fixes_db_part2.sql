-- Review fixes, part 2: storage deletion worker, audit retention, account-deletion guard on
-- workspace creation, and message attachment immutability. Redefinitions are written out in
-- full and keep the signature, language, SECURITY DEFINER and `set search_path = ''` of the last
-- definition they replace.

-- -----------------------------------------------------------------------------
-- 2. A dead-lettered unsafe row must not stall the whole deletion queue.
-- prepare_storage_deletion_job_insert (20261007202000) validates on every INSERT or UPDATE, so
-- the claim worker's own UPDATE that marks an unsafe row 'dead' raised 42501 and aborted the
-- whole claim. The trigger now fires on INSERT and on UPDATE of bucket_id/object_path only. Those
-- are the only columns that can make a path unsafe, and the worker's status/attempts updates no
-- longer re-run the check. Existing rows are not rewritten; the check still runs for every new
-- or re-pointed path.
-- -----------------------------------------------------------------------------
drop trigger if exists prepare_storage_deletion_job_insert on public.storage_deletion_jobs;
create trigger prepare_storage_deletion_job_insert
  before insert or update of bucket_id, object_path on public.storage_deletion_jobs
  for each row execute function app_hidden.prepare_storage_deletion_job_insert();

-- -----------------------------------------------------------------------------
-- 3. Stale 'processing' jobs that used all attempts are dead-lettered.
-- claim_storage_deletion_jobs (20261010160000) only claims attempts < 10, so a job whose worker
-- died at attempts = 10 stayed 'processing' forever. Such rows are now marked 'dead' before the
-- claim loop runs. Unsafe-path dead-lettering is unchanged.
-- -----------------------------------------------------------------------------
create or replace function public.claim_storage_deletion_jobs(p_limit integer default 25)
returns table (id uuid, bucket_id text, object_path text, attempts integer)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_job record;
begin
  update public.storage_deletion_jobs as j
  set status = 'dead',
      last_error = 'stale after max attempts',
      updated_at = now()
  where j.status = 'processing'
    and j.attempts >= 10
    and j.updated_at < now() - interval '15 minutes';

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

-- -----------------------------------------------------------------------------
-- 7. Audit retention: time_entry.correct rows are kept for three years, the same window as
-- retained_time_entries (FLSA payroll history); every other audit row keeps 365 days.
-- Redefines run_retention_cleanup (20261010120000); return columns are unchanged. The cron entry
-- scheduled by that migration calls this function by name and needs no change.
-- -----------------------------------------------------------------------------
create or replace function app_hidden.run_retention_cleanup()
returns table (audit_log_deleted bigint, attestation_challenges_deleted bigint,
  retained_time_entries_deleted bigint)
language plpgsql security definer set search_path = '' as $$
declare
  v_audit bigint;
  v_audit_corrections bigint;
  v_challenges bigint;
  v_wage bigint;
begin
  delete from public.audit_log
    where action <> 'time_entry.correct'
      and created_at < now() - interval '365 days';
  get diagnostics v_audit = row_count;

  delete from public.audit_log
    where action = 'time_entry.correct'
      and created_at < now() - interval '3 years';
  get diagnostics v_audit_corrections = row_count;
  v_audit := v_audit + v_audit_corrections;

  delete from public.attestation_challenges where expires_at < now() - interval '1 hour';
  get diagnostics v_challenges = row_count;

  delete from public.retained_time_entries
    where coalesce(clock_out_at, clock_in_at) < now() - interval '3 years';
  get diagnostics v_wage = row_count;

  return query select v_audit, v_challenges, v_wage;
end;
$$;

revoke all on function app_hidden.run_retention_cleanup() from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 8. A user whose account deletion is queued cannot create a new workspace.
-- request_account_deletion does not revoke access, and create_workspace (20261007191000) let the
-- user create an organization afterwards, which blocks the deletion job's FK-bound cleanup. The
-- guard checks account_deletion_jobs (user_id, status) for pending or processing rows.
-- Redefines create_workspace (20261007191000) in full; the only change is the guard.
-- -----------------------------------------------------------------------------
create or replace function public.create_workspace(
  p_organization_name text,
  p_venue_name text,
  p_timezone text default 'UTC'
)
returns table (
  organization_id uuid,
  organization_name text,
  organization_created_at timestamptz,
  venue_id uuid,
  venue_name text,
  venue_created_at timestamptz
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_org_name text := trim(p_organization_name);
  v_venue_name text := trim(p_venue_name);
  v_timezone text := coalesce(nullif(trim(p_timezone), ''), 'UTC');
  v_org_id uuid;
  v_venue_id uuid;
begin
  if v_uid is null then
    raise exception 'Must be signed in to create a workspace' using errcode = '42501';
  end if;

  if exists (
    select 1 from public.account_deletion_jobs j
    where j.user_id = v_uid
      and j.status in ('pending', 'processing')
  ) then
    raise exception 'This account is being deleted and cannot create a workspace'
      using errcode = '42501';
  end if;

  if char_length(v_org_name) = 0 or char_length(v_org_name) > 120 then
    raise exception 'Organization name must be 1-120 characters' using errcode = '22023';
  end if;
  if char_length(v_venue_name) = 0 or char_length(v_venue_name) > 120 then
    raise exception 'Venue name must be 1-120 characters' using errcode = '22023';
  end if;

  if v_timezone not in (select name from pg_catalog.pg_timezone_names) then
    raise exception 'Unknown time zone' using errcode = '22023';
  end if;

  insert into public.organizations (name, created_by)
  values (v_org_name, v_uid)
  returning id into v_org_id;

  insert into public.venues (organization_id, name, created_by, timezone)
  values (v_org_id, v_venue_name, v_uid, v_timezone)
  returning id into v_venue_id;

  -- venue_id is null here by design: memberships_org_level_roles_check requires it for an
  -- organization_owner row. The owner's access to this (and any future) venue in the org
  -- comes from the org-level role, not a per-venue grant — same shape as every other
  -- org-level owner/admin membership in this schema.
  insert into public.memberships (user_id, organization_id, venue_id, role, created_by)
  values (v_uid, v_org_id, null, 'organization_owner', v_uid);

  return query
    select o.id, o.name, o.created_at, v.id, v.name, v.created_at
    from public.organizations o
    join public.venues v on v.organization_id = o.id
    where o.id = v_org_id and v.id = v_venue_id;
end;
$$;

revoke all on function public.create_workspace(text, text, text) from public, anon;
grant execute on function public.create_workspace(text, text, text) to authenticated;

-- -----------------------------------------------------------------------------
-- 10. Message attachments are immutable after insert.
-- The attachment check (guard_message_attachment) runs on INSERT only. Supabase's default
-- privileges give authenticated UPDATE on new public tables, so a sender could repoint
-- attachment_path after the check. The app never updates messages (it selects, inserts and
-- deletes only), and the one messages UPDATE in the schema runs inside a SECURITY DEFINER
-- function, which does not depend on this grant. Revoke table-level UPDATE for authenticated.
-- Column-level revokes do not undo a table-level grant, so the table-level form is used.
-- -----------------------------------------------------------------------------
revoke update on public.messages from authenticated;

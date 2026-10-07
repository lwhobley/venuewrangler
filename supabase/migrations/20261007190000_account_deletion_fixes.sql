-- Fixes to public.request_account_deletion (20261007180000_account_deletion.sql), found by
-- populating one user in every table that references auth.users and running the real
-- request followed by the real `delete from auth.users` — which the first version's own pgTAP
-- fixture (no tasks, incidents, invites, swaps, reviews...) never exercised:
--
--  1. Existing client-facing guard triggers vetoed the anonymization UPDATEs: a non-manager
--     can't change operational_tasks.assigned_to (enforce_task_update_scope), incidents
--     reported_by (enforce_incident_update_scope), invites (enforce_invite_revoke_only),
--     shift_swaps (enforce_shift_swap_update), and sync_inventory_item_update re-stamped
--     updated_by with the departing user (auth.uid()) on every update. The whole request rolled
--     back with a 42501 for anyone with ordinary history. Those guards now stand down for the
--     one transaction that sets app.account_deletion (same one-transaction escape hatch as
--     public.correct_time_entry's app.time_entry_correction).
--  2. enforce_staff_request_update would have vetoed the reviewer_id ON DELETE SET NULL cascade
--     fired by the final auth.users delete itself (auth.uid() is null there), so a manager who
--     ever reviewed a staff request could never be deleted. The SET NULL columns are now
--     cleared up front, inside the flagged transaction, instead of left for the cascade.
--  3. Two NO ACTION references were missed: pos_audit_events.actor_id and
--     platform_admins.created_by — either one made the Auth Admin API delete fail forever.
--  4. A worker invocation killed mid-flight left its job 'processing', which the sweep never
--     picked up again. The sweep now reclaims stale 'processing' jobs and dead-letters them once
--     their attempts are spent.
--  5. Requesting deletion twice (e.g. a retry after a dropped response) no longer queues a
--     second job, and push tokens / device attestations are removed immediately rather than
--     whenever the async delete lands, so a deleted account stops receiving pushes at once.

create or replace function app_hidden.account_deletion_in_progress()
returns boolean
language sql
stable
as $$
  select coalesce(current_setting('app.account_deletion', true), '') = 'on'
$$;

CREATE OR REPLACE FUNCTION app_hidden.enforce_task_update_scope()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  -- Account deletion (public.request_account_deletion) clears this account from rows it
  -- touched; these guards exist to stop a *client* editing them, and would otherwise veto
  -- that cleanup (and, for staff_requests, the reviewer_id SET NULL on the final auth delete).
  if app_hidden.account_deletion_in_progress() then
    return new;
  end if;

  if app_hidden.has_venue_role(
    new.venue_id,
    array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
  ) then
    return new;
  end if;

  if old.assigned_to is distinct from auth.uid() then
    raise exception 'not authorized to update this task' using errcode = '42501';
  end if;

  if new.title is distinct from old.title
    or new.description is distinct from old.description
    or new.venue_id is distinct from old.venue_id
    or new.organization_id is distinct from old.organization_id
    or new.assigned_to is distinct from old.assigned_to
    or new.due_at is distinct from old.due_at
    or new.created_by is distinct from old.created_by
    or new.created_at is distinct from old.created_at
  then
    raise exception 'the assignee may only change a task''s status' using errcode = '42501';
  end if;

  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION app_hidden.enforce_incident_update_scope()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  -- Account deletion (public.request_account_deletion) clears this account from rows it
  -- touched; these guards exist to stop a *client* editing them, and would otherwise veto
  -- that cleanup (and, for staff_requests, the reviewer_id SET NULL on the final auth delete).
  if app_hidden.account_deletion_in_progress() then
    return new;
  end if;

  if app_hidden.has_venue_role(
    new.venue_id,
    array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
  ) then
    return new;
  end if;

  if old.reported_by is distinct from auth.uid() then
    raise exception 'not authorized to update this incident' using errcode = '42501';
  end if;

  if new.status is distinct from old.status
    or new.severity is distinct from old.severity
    or new.venue_id is distinct from old.venue_id
    or new.organization_id is distinct from old.organization_id
    or new.reported_by is distinct from old.reported_by
    or new.resolved_by is distinct from old.resolved_by
    or new.resolved_at is distinct from old.resolved_at
    or new.created_at is distinct from old.created_at
  then
    raise exception
      'the reporter may only edit title/description, and only while the incident is open'
      using errcode = '42501';
  end if;

  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION app_hidden.enforce_invite_revoke_only()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  -- Account deletion (public.request_account_deletion) clears this account from rows it
  -- touched; these guards exist to stop a *client* editing them, and would otherwise veto
  -- that cleanup (and, for staff_requests, the reviewer_id SET NULL on the final auth delete).
  if app_hidden.account_deletion_in_progress() then
    return new;
  end if;

  if old.status <> 'pending' or new.status not in ('revoked', 'accepted') then
    raise exception 'invites can only move from pending to revoked or accepted' using errcode = '42501';
  end if;
  if new.organization_id is distinct from old.organization_id
    or new.venue_id is distinct from old.venue_id
    or new.email is distinct from old.email
    or new.role is distinct from old.role
    or new.invited_by is distinct from old.invited_by
    or new.created_at is distinct from old.created_at
    or new.expires_at is distinct from old.expires_at
  then
    raise exception 'only an invite''s status may be changed' using errcode = '42501';
  end if;
  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION app_hidden.enforce_shift_swap_update()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  -- Account deletion (public.request_account_deletion) clears this account from rows it
  -- touched; these guards exist to stop a *client* editing them, and would otherwise veto
  -- that cleanup (and, for staff_requests, the reviewer_id SET NULL on the final auth delete).
  if app_hidden.account_deletion_in_progress() then
    return new;
  end if;

  if app_hidden.has_venue_role(
    new.venue_id,
    array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
  ) then
    return new;
  end if;

  if old.status <> 'pending' then
    raise exception 'this swap request is no longer pending' using errcode = '42501';
  end if;

  if auth.uid() = old.requested_by then
    if new.status <> 'cancelled' then
      raise exception 'the requester may only cancel their own swap request' using errcode = '42501';
    end if;
  else
    if new.status <> 'accepted' or new.accepted_by is distinct from auth.uid() then
      raise exception 'you may only accept this swap request as yourself' using errcode = '42501';
    end if;
    if old.offered_to is not null and old.offered_to <> auth.uid() then
      raise exception 'this swap request was offered to someone else' using errcode = '42501';
    end if;
  end if;

  if new.organization_id is distinct from old.organization_id
    or new.venue_id is distinct from old.venue_id
    or new.shift_id is distinct from old.shift_id
    or new.requested_by is distinct from old.requested_by
    or new.offered_to is distinct from old.offered_to
    or new.created_at is distinct from old.created_at
  then
    raise exception 'only a swap request''s status and accepted_by may change' using errcode = '42501';
  end if;

  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION app_hidden.enforce_staff_request_update()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  -- Account deletion (public.request_account_deletion) clears this account from rows it
  -- touched; these guards exist to stop a *client* editing them, and would otherwise veto
  -- that cleanup (and, for staff_requests, the reviewer_id SET NULL on the final auth delete).
  if app_hidden.account_deletion_in_progress() then
    return new;
  end if;

  if app_hidden.has_venue_role(
    new.venue_id,
    array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
  ) then
    if old.status <> 'pending' then
      raise exception 'only pending requests can be reviewed' using errcode = '42501';
    end if;

    if new.status not in ('approved', 'denied', 'cancelled') then
      raise exception 'manager must set status to approved, denied, or cancelled' using errcode = '42501';
    end if;

    new.reviewer_id := auth.uid();
    new.reviewed_at := now();

    if new.organization_id is distinct from old.organization_id
      or new.venue_id is distinct from old.venue_id
      or new.user_id is distinct from old.user_id
      or new.kind is distinct from old.kind
      or new.title is distinct from old.title
      or new.details is distinct from old.details
      or new.requested_for_date is distinct from old.requested_for_date
      or new.requested_range_start is distinct from old.requested_range_start
      or new.requested_range_end is distinct from old.requested_range_end
      or new.requested_shift_id is distinct from old.requested_shift_id
      or new.availability is distinct from old.availability
      or new.created_at is distinct from old.created_at
    then
      raise exception 'only status, reviewer fields, and response_notes may be updated by a manager' using errcode = '42501';
    end if;

    return new;
  end if;

  if auth.uid() = old.user_id then
    if old.status <> 'pending' then
      raise exception 'this request is no longer pending' using errcode = '42501';
    end if;

    if new.status <> 'cancelled' then
      raise exception 'the requester may only cancel their own request' using errcode = '42501';
    end if;

    if new.organization_id is distinct from old.organization_id
      or new.venue_id is distinct from old.venue_id
      or new.user_id is distinct from old.user_id
      or new.kind is distinct from old.kind
      or new.title is distinct from old.title
      or new.details is distinct from old.details
      or new.requested_for_date is distinct from old.requested_for_date
      or new.requested_range_start is distinct from old.requested_range_start
      or new.requested_range_end is distinct from old.requested_range_end
      or new.requested_shift_id is distinct from old.requested_shift_id
      or new.availability is distinct from old.availability
      or new.reviewer_id is distinct from old.reviewer_id
      or new.reviewed_at is distinct from old.reviewed_at
      or new.response_notes is distinct from old.response_notes
      or new.created_at is distinct from old.created_at
    then
      raise exception 'the requester may only cancel the request' using errcode = '42501';
    end if;

    return new;
  end if;

  raise exception 'not authorized to update this staff request' using errcode = '42501';
end;
$function$
;

CREATE OR REPLACE FUNCTION app_hidden.sync_inventory_item_update()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_org_id uuid;
begin
  select organization_id into v_org_id from public.venues where id = new.venue_id;
  if v_org_id is null then
    raise exception 'venue % does not exist', new.venue_id;
  end if;
  new.organization_id := v_org_id;
  -- Not re-stamped while an account deletion is clearing updated_by (it would put the
  -- departing user straight back, and block the final auth.users delete).
  if not app_hidden.account_deletion_in_progress() then
    new.updated_by := auth.uid();
  end if;
  new.updated_at := now();
  return new;
end;
$function$
;


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

  -- Lets the client-facing guard triggers stand down for the rest of this transaction only
  -- (see app_hidden.account_deletion_in_progress); reset explicitly before returning.
  perform set_config('app.account_deletion', 'on', true);

  -- Preserve wage history (FLSA 516.2) before it would otherwise cascade away.
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
  -- row that names them.
  for v_photo in
    select v.organization_id, sp.venue_id, sp.storage_path
    from public.staff_photos sp
    join public.venues v on v.id = sp.venue_id
    where sp.user_id = v_uid
  loop
    insert into public.storage_deletion_jobs (organization_id, venue_id, bucket_id, object_path)
    values (v_photo.organization_id, v_photo.venue_id, 'profile-photos', v_photo.storage_path);
  end loop;

  -- Anonymize attribution on records that must survive this account's departure.
  -- audit_log is append-only and retained independently (see data-retention-disposal-
  -- policy.md section 3) — the row itself stays, only who-did-it is forgotten.
  update public.audit_log set actor_user_id = null where actor_user_id = v_uid;
  update public.organizations set created_by = null where created_by = v_uid;
  update public.venues set created_by = null where created_by = v_uid;
  update public.memberships set created_by = null where created_by = v_uid;
  update public.platform_admins set created_by = null where created_by = v_uid;
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
  update public.pos_audit_events set actor_id = null where actor_id = v_uid;

  -- ON DELETE SET NULL columns: left to the final auth.users delete they'd run through the
  -- same guard triggers with auth.uid() null (and no flag), so clear them here instead.
  update public.staff_requests set reviewer_id = null where reviewer_id = v_uid;
  update public.shift_insights set created_by = null where created_by = v_uid;
  update public.crm_activity_log set actor_id = null where actor_id = v_uid;
  update public.crm_beos set assigned_rep_id = null where assigned_rep_id = v_uid;
  update public.crm_leads set assigned_to = null where assigned_to = v_uid;
  update public.crm_notes set author_id = null where author_id = v_uid;
  update public.messages set sender_id = null where sender_id = v_uid;
  update public.reservations set assigned_to = null where assigned_to = v_uid;

  -- Workflow rows that are this user's own in-flight requests, not records anyone else needs
  -- attributable (unlike audit_log/time_entries above) — removed outright rather than
  -- anonymized. shift_swaps.requested_by and pos_employee_mappings.staff_id are both NOT
  -- NULL with no ON DELETE action, so they can't simply be set to null.
  delete from public.shift_swaps where requested_by = v_uid;
  update public.shift_swaps set offered_to = null where offered_to = v_uid;
  update public.shift_swaps set accepted_by = null where accepted_by = v_uid;
  delete from public.pos_employee_mappings where staff_id = v_uid;
  delete from public.staff_requests where user_id = v_uid;

  -- Per-device/per-user delivery state: gone immediately, so a deleted account stops getting
  -- pushed to rather than waiting for the async auth.users delete.
  delete from public.push_tokens where user_id = v_uid;
  delete from public.device_attestations where user_id = v_uid;
  delete from public.attestation_challenges where user_id = v_uid;
  delete from public.notification_events where target_user_id = v_uid;
  delete from public.conversation_members where user_id = v_uid;
  delete from public.conversation_reads where user_id = v_uid;

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

  -- One live job per user: a retry after a dropped response reuses it.
  select id into v_job_id
  from public.account_deletion_jobs
  where user_id = v_uid and status not in ('completed', 'dead')
  order by created_at
  limit 1;

  if v_job_id is null then
    insert into public.account_deletion_jobs (user_id, requested_reason)
    values (v_uid, p_reason)
    returning id into v_job_id;
  end if;

  perform set_config('app.account_deletion', 'off', true);

  perform app_hidden.dispatch_account_deletion_job(v_job_id);

  return v_job_id;
end;
$$;

revoke all on function public.request_account_deletion(text) from public, anon;
grant execute on function public.request_account_deletion(text) to authenticated;

-- Retry sweep: now also reclaims jobs stranded 'processing' by a worker that died before it
-- could report a result, and dead-letters them once their attempts are spent.
drop index if exists public.account_deletion_jobs_queue_idx;
create index account_deletion_jobs_queue_idx
  on public.account_deletion_jobs (status, updated_at)
  where status in ('pending', 'failed', 'processing');

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
  update public.account_deletion_jobs
  set status = 'dead',
      last_error = coalesce(last_error, 'worker never reported a result'),
      updated_at = now()
  where status = 'processing'
    and attempts >= 10
    and updated_at < now() - interval '15 minutes';

  for r in
    select id
    from public.account_deletion_jobs
    where attempts < 10
      and (
        (status in ('pending', 'failed') and updated_at < now() - interval '10 minutes')
        or (status = 'processing' and updated_at < now() - interval '15 minutes')
      )
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

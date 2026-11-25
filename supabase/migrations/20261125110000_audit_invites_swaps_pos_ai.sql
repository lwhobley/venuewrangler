-- Audit fixes (2026-11-25).
--
-- 1. Invite hijack: prepare_staff_invite and revoke_invite only checked the role being requested.
--    A venue_manager without MFA could re-invite an email as staff, or revoke it, and so overwrite
--    or cancel an organization admin's pending venue_manager invite. The check now lives in the
--    invites update trigger, which every revoke/reconcile path passes through.

create or replace function app_hidden.enforce_invite_revoke_only()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if app_hidden.account_deletion_in_progress() then
    return new;
  end if;

  if old.status <> 'pending' then
    raise exception 'invites can only move from pending to revoked or accepted'
      using errcode = '42501';
  end if;

  -- Revoking or reconciling a live invite needs authority over the role it ALREADY grants, not
  -- just the role being requested. Otherwise a venue_manager could re-invite (or revoke) an email
  -- that an organization admin had invited as venue_manager. Every client and DEFINER path that
  -- revokes or reconciles (direct RLS update, revoke_invite, prepare_staff_invite) lands here.
  -- Accepting is the invitee's own action and is gated separately below; expired invites grant
  -- nothing, so any manager may clear them.
  if new.status in ('revoked', 'pending')
     and old.expires_at > now()
     and auth.uid() is not null then
    if not app_hidden.can_manage_member_role(old.organization_id, old.venue_id, old.role) then
      raise exception 'Only organization owners and admins may change a manager invite'
        using errcode = '42501';
    end if;
    if old.role = 'venue_manager' and not app_hidden.mfa_satisfied() then
      raise exception 'mfa_required' using errcode = '42501';
    end if;
  end if;

  -- DEFINER reconcile path: status stays pending; only role / display_name may change, and
  -- invited_by may only become the re-inviting caller.
  if new.status = 'pending'
     and app_hidden.privilege_gate_is_open('invite_reconcile') then
    if new.organization_id is distinct from old.organization_id
      or new.venue_id is distinct from old.venue_id
      or new.email is distinct from old.email
      or (new.invited_by is distinct from old.invited_by
          and new.invited_by is distinct from auth.uid())
      or new.created_at is distinct from old.created_at
      or new.expires_at is distinct from old.expires_at
    then
      raise exception 'only an invite''s role or display_name may be reconciled'
        using errcode = '42501';
    end if;
    return new;
  end if;

  if new.status = 'revoked' then
    null; -- managers (RLS) or revoke_invite
  elsif new.status = 'accepted' then
    if not app_hidden.privilege_gate_is_open('invite_accept') then
      raise exception 'invites are accepted through accept_invite' using errcode = '42501';
    end if;
  else
    raise exception 'invites can only move from pending to revoked or accepted'
      using errcode = '42501';
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
$$;

-- 2. Shift swaps.
--    a) A staff member a swap was offered to could not decline it: the trigger only let a
--       non-manager set `accepted`, so `declineSwap` failed with 42501. The person a swap is
--       offered to may now set `declined` (open offers have no one to decline them).
--    b) Managers skipped the pending check entirely, so they could move a cancelled or declined
--       swap to `accepted` and reassign the shift. Every transition, for managers too, now starts
--       from `pending`, and `accepted` always names who accepted it.
create or replace function app_hidden.enforce_shift_swap_update()
returns trigger
language plpgsql
security definer
set search_path = public
as $function$
begin
  if app_hidden.account_deletion_in_progress() then
    return new;
  end if;

  -- Immutable columns are frozen for everyone, including managers.
  if new.organization_id is distinct from old.organization_id
    or new.venue_id is distinct from old.venue_id
    or new.shift_id is distinct from old.shift_id
    or new.requested_by is distinct from old.requested_by
    or new.offered_to is distinct from old.offered_to
    or new.created_at is distinct from old.created_at
  then
    raise exception 'only a swap request''s status and accepted_by may change' using errcode = '42501';
  end if;

  -- accepted, declined and cancelled are final, whoever is asking.
  if old.status <> 'pending' then
    raise exception 'this swap request is no longer pending' using errcode = '42501';
  end if;

  if new.status = 'accepted' and new.accepted_by is null then
    raise exception 'an accepted swap must record who accepted it' using errcode = '23514';
  end if;
  if new.status in ('declined', 'cancelled', 'pending')
     and new.accepted_by is distinct from old.accepted_by then
    raise exception 'accepted_by is set only when a swap is accepted' using errcode = '42501';
  end if;

  if app_hidden.has_venue_role(
    new.venue_id,
    array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
  ) then
    return new;
  end if;

  if auth.uid() = old.requested_by then
    if new.status <> 'cancelled' then
      raise exception 'the requester may only cancel their own swap request' using errcode = '42501';
    end if;
  elsif new.status = 'declined' then
    if old.offered_to is null or old.offered_to <> auth.uid() then
      raise exception 'only the person this swap was offered to may decline it' using errcode = '42501';
    end if;
  else
    if new.status <> 'accepted' or new.accepted_by is distinct from auth.uid() then
      raise exception 'you may only accept this swap request as yourself' using errcode = '42501';
    end if;
    if old.offered_to is not null and old.offered_to <> auth.uid() then
      raise exception 'this swap request was offered to someone else' using errcode = '42501';
    end if;
  end if;

  return new;
end;
$function$;

-- 4. AI budget rounding. cost_usd and reserved_usd were numeric(10,4), so a short Groq call
--    (under about $0.00005) was stored as 0.0000 and never counted against the monthly caps.
--    Eight decimal places keep every realistic per-call cost; existing values are unchanged.
alter table public.ai_usage_events alter column cost_usd type numeric(16, 8);
alter table public.ai_budget_reservations alter column reserved_usd type numeric(16, 8);

-- 6. Deleting a guest failed for closed or voided POS checks. The FK's ON DELETE SET NULL is an
--    UPDATE of pos_checks.guest_id, which guard_pos_check_final_state turned into a no-op by
--    returning OLD, leaving the reference in place (23503). Clearing guest_id, and nothing else,
--    is now allowed on a finished check; every other change keeps the existing rules.
create or replace function app_hidden.guard_pos_check_final_state()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.venue_id is distinct from old.venue_id then
    raise exception 'venue_id cannot be modified once set' using errcode = '42501';
  end if;
  if new.organization_id is distinct from old.organization_id then
    raise exception 'organization_id cannot be modified once set' using errcode = '42501';
  end if;
  -- Guest deletion (FK ON DELETE SET NULL) or erasure unlinking the guest.
  if new.guest_id is null and old.guest_id is not null
     and (to_jsonb(new) - 'guest_id' - 'updated_at') = (to_jsonb(old) - 'guest_id' - 'updated_at') then
    return new;
  end if;
  -- Retention / erasure: only guest PII / raw payload / guest_id may change on a finished check.
  if app_hidden.privilege_gate_is_open('pos_retention')
     and (to_jsonb(new) - 'raw_payload' - 'guest_name' - 'guest_id' - 'updated_at')
         = (to_jsonb(old) - 'raw_payload' - 'guest_name' - 'guest_id' - 'updated_at') then
    return new;
  end if;
  if old.status = 'voided' or (old.status = 'closed' and new.status <> 'voided') then
    return old;
  end if;
  return new;
end;
$$;

-- Medium audit items.
--
-- a) push_tokens: clients could read revocation_secret_hash and delete rows directly. Every client
--    path goes through register_push_token_for_device / revoke_device_push_token, so the table is
--    now read-only for clients and the digest column is not selectable.
drop policy if exists push_tokens_delete on public.push_tokens;
revoke all on public.push_tokens from authenticated;
grant select (
  id, organization_id, venue_id, user_id, token, platform, enabled, last_seen_at, disabled_at,
  created_at, updated_at
) on public.push_tokens to authenticated;

-- b) Account deletion left oauth_pending_connections rows and inventory_operations.user_id behind
--    (and predates the BrightHR tables). Same function, with those rows handled.
CREATE OR REPLACE FUNCTION public.request_account_deletion_impl(p_reason text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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

  perform app_hidden.open_privilege_gate('account_deletion');

  insert into public.retained_time_entries (
    original_time_entry_id, organization_id, venue_id, anonymized_user_label,
    shift_id, clock_in_at, clock_out_at, breaks, location_anomaly
  )
  select
    te.id, te.organization_id, te.venue_id, v_label,
    te.shift_id, te.clock_in_at, te.clock_out_at, te.breaks, te.location_anomaly
  from public.time_entries te
  where te.user_id = v_uid;

  insert into public.retained_wage_profiles (
    organization_id, venue_id, anonymized_user_label, legal_name, employee_number, job_title,
    hire_date, hourly_rate_cents
  )
  select v.organization_id, hp.venue_id, v_label, hp.legal_name, hp.employee_number, hp.job_title,
         hp.hire_date, hp.hourly_rate_cents
  from public.employee_hr_profiles hp
  join public.venues v on v.id = hp.venue_id
  where hp.user_id = v_uid and hp.hourly_rate_cents is not null;

  for v_photo in
    select v.organization_id, sp.venue_id, sp.storage_path
    from public.staff_photos sp
    join public.venues v on v.id = sp.venue_id
    where sp.user_id = v_uid
  loop
    insert into public.storage_deletion_jobs (organization_id, venue_id, bucket_id, object_path)
    values (v_photo.organization_id, v_photo.venue_id, 'profile-photos', v_photo.storage_path);
  end loop;

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

  update public.staff_requests set reviewer_id = null where reviewer_id = v_uid;
  update public.shift_insights set created_by = null where created_by = v_uid;
  update public.crm_activity_log set actor_id = null where actor_id = v_uid;
  update public.crm_beos set assigned_rep_id = null where assigned_rep_id = v_uid;
  update public.crm_leads set assigned_to = null where assigned_to = v_uid;
  update public.crm_notes set author_id = null where author_id = v_uid;
  update public.messages set sender_id = null where sender_id = v_uid;
  update public.reservations set assigned_to = null where assigned_to = v_uid;

  delete from public.shift_swaps where requested_by = v_uid;
  update public.shift_swaps set offered_to = null where offered_to = v_uid;
  update public.shift_swaps set accepted_by = null where accepted_by = v_uid;
  delete from public.pos_employee_mappings where staff_id = v_uid;
  -- Added 2026-11-25 (audit): rows the earlier version missed.
  delete from public.oauth_pending_connections where user_id = v_uid;
  delete from app_hidden.inventory_operations where user_id = v_uid;
  delete from public.brighthr_employee_mappings where staff_id = v_uid;
  update public.brighthr_employee_mappings set linked_by = null where linked_by = v_uid;
  update public.brighthr_connections set connected_by = null where connected_by = v_uid;
  delete from public.staff_requests where user_id = v_uid;

  delete from public.push_tokens where user_id = v_uid;
  delete from public.device_attestations where user_id = v_uid;
  delete from public.attestation_challenges where user_id = v_uid;
  delete from public.notification_events where target_user_id = v_uid;
  delete from public.conversation_members where user_id = v_uid;
  delete from public.conversation_reads where user_id = v_uid;

  update public.audit_log
     set metadata = metadata
       || case when metadata ? 'before' then jsonb_build_object('before', (metadata -> 'before') - 'user_id') else '{}'::jsonb end
       || case when metadata ? 'after' then jsonb_build_object('after', (metadata -> 'after') - 'user_id') else '{}'::jsonb end
   where action in ('time_entry.correct', 'time_entry.void')
     and (
       metadata -> 'before' ->> 'user_id' = v_uid::text
       or target_id in (select te.id from public.time_entries te where te.user_id = v_uid)
     );
  update public.audit_log set metadata = metadata - 'user_id' - 'new_owner_user_id'
   where (metadata ->> 'user_id' = v_uid::text or metadata ->> 'new_owner_user_id' = v_uid::text);

  delete from public.time_entries where user_id = v_uid;
  delete from public.memberships where user_id = v_uid;
  delete from public.employee_hr_profiles where user_id = v_uid;
  delete from public.staff_photos where user_id = v_uid;
  delete from public.profiles where id = v_uid;

  insert into public.audit_log (actor_user_id, action, target_table, target_id, metadata)
  values (null, 'account.delete_requested', 'auth.users', v_uid, jsonb_build_object('reason', p_reason));

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

  perform app_hidden.close_privilege_gate('account_deletion');

  perform app_hidden.dispatch_account_deletion_job(v_job_id);

  return v_job_id;
end;
$function$;

-- c) Supervisors assign reservations and tasks but could not read venue_roster, so assignee names
--    were blank for them. They now see the same roster (preferred display names only, never HR
--    legal names) that managers see.
create or replace function public.venue_roster(p_venue_id uuid)
returns table (user_id uuid, role public.app_role, display_name text)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null
     or not app_hidden.has_venue_role(
       p_venue_id,
       array['supervisor', 'venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
     ) then
    raise exception 'Not allowed to view this venue roster' using errcode = '42501';
  end if;

  -- Venue-level members, plus the organization's owners/admins, who manage every venue in it
  -- through an org-level membership (venue_id null). One row per person, venue role first.
  return query
    select r.user_id, r.role, r.display_name
    from (
      select distinct on (m.user_id) m.user_id, m.role, app_hidden.staff_display_name(p_venue_id, m.user_id) as display_name
      from public.memberships m
      join public.venues v on v.id = p_venue_id
      left join public.profiles p on p.id = m.user_id
      where m.venue_id = p_venue_id
         or (m.venue_id is null and m.organization_id = v.organization_id
             and m.role in ('organization_owner', 'organization_admin'))
      order by m.user_id, (m.venue_id is null)
    ) r
    order by r.display_name nulls last, r.user_id;
end;
$$;

-- d) Private-event reservations. Any venue member may update reservations (RLS), and the only
--    guard ran AFTER a cancel and only while the BEO was still live. Staff and supervisors could
--    therefore detach a reservation from its BEO (beo_id -> null) and then cancel or rebook it.
--    Detaching or cancelling a reservation that belongs to a private event is now manager-only.
--    The FK's ON DELETE SET NULL (the BEO itself was deleted, which only managers can do) and
--    server-side paths with no user stay allowed.
create or replace function app_hidden.guard_private_event_reservation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if old.beo_id is null
     or auth.uid() is null
     or app_hidden.account_deletion_in_progress()
     or app_hidden.has_venue_role(
       old.venue_id,
       array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
     ) then
    return new;
  end if;

  if new.beo_id is distinct from old.beo_id
     and exists (select 1 from public.crm_beos b where b.id = old.beo_id) then
    raise exception 'Only managers may detach a private event from its reservation'
      using errcode = '42501';
  end if;
  if new.status = 'cancelled' and old.status is distinct from 'cancelled' then
    raise exception 'Only managers may cancel a private event' using errcode = '42501';
  end if;
  return new;
end;
$$;

revoke all on function app_hidden.guard_private_event_reservation() from public, anon, authenticated;

drop trigger if exists guard_private_event_reservation on public.reservations;
create trigger guard_private_event_reservation
  before update on public.reservations
  for each row execute function app_hidden.guard_private_event_reservation();

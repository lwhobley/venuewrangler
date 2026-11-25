-- Repo review follow-ups (2026-11-23):
--
--   1. Invite role escalation. prepare_staff_invite and the invites insert policy let a
--      venue_manager invite someone AS venue_manager, and accept_invite (M1) then upserts the
--      invited role onto an existing membership. Together that skipped can_manage_member_role
--      (venue_manager is owner/admin-only) and the MFA gate in change_member_role, and let a
--      manager silently demote a peer manager by re-inviting them as staff. The inviter's
--      authority was also never rechecked at accept time.
--      Fix: invites can only carry a role the inviter may grant (same rule as
--      change_member_role, including MFA for manager-level roles), and accept_invite only
--      changes an existing membership's role when the inviter, as of now, may manage both the
--      member's current role and the invited role. A re-invite that reconciles a pending
--      invite records the re-inviter as invited_by, so the check follows whoever set the role.
--
--   2. Guest erasure regression. 20261123150002 (M5) switched the pos_checks scrub in
--      erase_guest to `guest_id = v_g.id`, but nothing writes pos_checks.guest_id (no backfill,
--      toast-pos does not set it), so erasure left every POS check's guest_name/raw_payload
--      intact. Scrub linked checks by id, and checks that were never linked by the previous
--      display-name match.

-- =============================================================================
-- 1. Invite role gate
-- =============================================================================

-- can_manage_member_role evaluated for an arbitrary user (the inviter) rather than auth.uid().
create or replace function app_hidden.user_can_manage_member_role(
  p_user uuid, p_org uuid, p_venue uuid, p_target_role public.app_role
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select p_user is not null and (
    exists (select 1 from public.platform_admins pa where pa.user_id = p_user)
    or case
      when p_target_role in ('organization_owner', 'organization_admin') then
        exists (
          select 1 from public.memberships m
          where m.user_id = p_user and m.organization_id = p_org and m.venue_id is null
            and m.role = 'organization_owner'
        )
      when p_target_role = 'venue_manager' then
        exists (
          select 1 from public.memberships m
          where m.user_id = p_user and m.organization_id = p_org and m.venue_id is null
            and m.role in ('organization_owner', 'organization_admin')
        )
      when p_target_role in ('supervisor', 'staff') then
        p_venue is not null and exists (
          select 1 from public.memberships m
          where m.user_id = p_user and m.organization_id = p_org
            and (
              (m.venue_id is null and m.role in ('organization_owner', 'organization_admin'))
              or (m.venue_id = p_venue and m.role = 'venue_manager')
            )
        )
      else false
    end
  );
$$;

revoke all on function app_hidden.user_can_manage_member_role(uuid, uuid, uuid, public.app_role)
  from public, anon, authenticated;

-- Direct inserts (the client path) obey the same rule as prepare_staff_invite. Roles that can
-- never be invited are left to the invites_role_check constraint (it reports 23514, which
-- clients and tests rely on); the policy still requires venue-manager access for them, so
-- they cannot slip past either check.
drop policy if exists invites_insert_managers on public.invites;
create policy invites_insert_managers on public.invites
  for insert to authenticated
  with check (
    app_hidden.has_venue_role(
      venue_id,
      array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
    )
    and (
      role not in ('staff', 'supervisor', 'venue_manager')
      or (
        app_hidden.can_manage_member_role(
          (select v.organization_id from public.venues v where v.id = venue_id),
          venue_id,
          role
        )
        and (role <> 'venue_manager' or app_hidden.mfa_satisfied())
      )
    )
  );

-- A re-invite that reconciles a pending row's role is issued by whoever re-invited, so record
-- them as invited_by: accept_invite checks the inviter's authority, and keeping the original
-- sender would both block a legitimate upgrade (manager invited as staff, admin re-invites as
-- venue_manager) and let a manager borrow an admin's authority by editing the admin's invite.
-- Same body as 20261123170000, except the reconcile path may set invited_by to the caller.
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

create or replace function public.prepare_staff_invite(
  p_venue_id uuid,
  p_email text,
  p_role public.app_role,
  p_display_name text default null
)
returns public.invites
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_invite public.invites;
  v_display text := nullif(trim(p_display_name), '');
  v_org uuid;
begin
  if not app_hidden.has_venue_role(
    p_venue_id,
    array['venue_manager', 'organization_admin', 'organization_owner']::public.app_role[]
  ) then
    raise exception 'Only managers may invite staff' using errcode = '42501';
  end if;

  if p_role not in ('staff', 'supervisor', 'venue_manager')
    or p_role is null
    or p_email is null
    or length(p_email) > 254
    or p_email !~ '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$'
  then
    raise exception 'Invalid invite email or role' using errcode = '22023';
  end if;

  select v.organization_id into v_org from public.venues v where v.id = p_venue_id;
  if not app_hidden.can_manage_member_role(v_org, p_venue_id, p_role) then
    raise exception 'Only organization owners and admins may invite managers'
      using errcode = '42501';
  end if;
  if p_role = 'venue_manager' and not app_hidden.mfa_satisfied() then
    raise exception 'mfa_required' using errcode = '42501';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(p_venue_id::text || lower(trim(p_email)), 0)
  );

  -- Trusted replacement follows the same revoke transition clients may perform.
  update public.invites
  set status = 'revoked'
  where venue_id = p_venue_id
    and email = lower(trim(p_email))
    and status = 'pending'
    and expires_at <= now();

  select * into v_invite
  from public.invites
  where venue_id = p_venue_id
    and email = lower(trim(p_email))
    and status = 'pending';

  if found then
    -- Reconcile when the manager re-invites with a different role or name so the
    -- pending row matches what they just submitted (status stays pending).
    -- The re-inviter becomes invited_by (see enforce_invite_revoke_only above).
    if v_invite.role is distinct from p_role
      or v_invite.display_name is distinct from v_display
      or v_invite.invited_by is distinct from auth.uid()
    then
      perform app_hidden.open_privilege_gate('invite_reconcile');
      update public.invites
      set role = p_role,
          display_name = v_display,
          invited_by = auth.uid()
      where id = v_invite.id
      returning * into v_invite;
      perform app_hidden.close_privilege_gate('invite_reconcile');
    end if;
    return v_invite;
  end if;

  insert into public.invites (venue_id, email, role, display_name)
  values (p_venue_id, p_email, p_role, v_display)
  returning * into v_invite;

  return v_invite;
end;
$$;

revoke all on function public.prepare_staff_invite(uuid, text, public.app_role, text)
  from public, anon;
grant execute on function public.prepare_staff_invite(uuid, text, public.app_role, text)
  to authenticated;

create or replace function public.accept_invite(p_invite_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_email text;
  v_invite public.invites;
  v_existing public.app_role;
  v_role public.app_role;
begin
  if auth.uid() is null then
    raise exception 'Must be signed in' using errcode = '42501';
  end if;

  if exists (
    select 1 from public.account_deletion_jobs j
    where j.user_id = auth.uid() and j.status in ('pending', 'processing')
  ) then
    raise exception 'This account is being deleted' using errcode = '42501';
  end if;

  select lower(u.email) into v_email from auth.users u
  where u.id = auth.uid() and u.email_confirmed_at is not null;
  if v_email is null then
    raise exception 'email_not_verified' using errcode = '42501';
  end if;

  select * into v_invite from public.invites where id = p_invite_id for update;
  if not found or lower(v_invite.email) <> v_email then
    raise exception 'invite_not_found' using errcode = 'P0002';
  end if;
  if v_invite.status <> 'pending' or v_invite.expires_at <= now() then
    raise exception 'invite_not_pending' using errcode = 'P0001';
  end if;

  -- The inviter must still be allowed to grant this role. An invite from someone who has since
  -- been removed, demoted or deleted (invited_by nulled) no longer carries authority.
  if not app_hidden.user_can_manage_member_role(
    v_invite.invited_by, v_invite.organization_id, v_invite.venue_id, v_invite.role
  ) then
    raise exception 'invite_inviter_not_authorized' using errcode = '42501';
  end if;

  select m.role into v_existing
  from public.memberships m
  where m.user_id = auth.uid()
    and m.organization_id = v_invite.organization_id
    and m.venue_id is not distinct from v_invite.venue_id
  for update;

  if not found then
    insert into public.memberships (user_id, organization_id, venue_id, role, created_by)
    values (auth.uid(), v_invite.organization_id, v_invite.venue_id, v_invite.role, v_invite.invited_by)
    on conflict (user_id, organization_id, venue_id) do nothing;
  elsif v_existing is distinct from v_invite.role then
    -- A role change through an invite needs the same authority as change_member_role: the
    -- inviter must be able to manage the member's current role too (so a manager cannot
    -- demote a peer manager or an admin by re-inviting them).
    if not app_hidden.user_can_manage_member_role(
      v_invite.invited_by, v_invite.organization_id, v_invite.venue_id, v_existing
    ) then
      raise exception 'invite_inviter_not_authorized' using errcode = '42501';
    end if;
    update public.memberships m
       set role = v_invite.role
     where m.user_id = auth.uid()
       and m.organization_id = v_invite.organization_id
       and m.venue_id is not distinct from v_invite.venue_id;
  end if;

  select m.role into v_role
  from public.memberships m
  where m.user_id = auth.uid()
    and m.organization_id = v_invite.organization_id
    and m.venue_id is not distinct from v_invite.venue_id;

  if v_role is distinct from v_invite.role then
    raise exception 'membership_role_mismatch' using errcode = 'P0001';
  end if;

  perform app_hidden.open_privilege_gate('invite_accept');
  update public.invites set status = 'accepted' where id = v_invite.id;
  perform app_hidden.close_privilege_gate('invite_accept');

  perform app_hidden.audit_event(
    v_invite.organization_id, v_invite.venue_id, 'invite.accept', 'invites', v_invite.id,
    jsonb_build_object('role', v_invite.role, 'previous_role', v_existing)
  );
end;
$$;

revoke all on function public.accept_invite(uuid) from public, anon;
grant execute on function public.accept_invite(uuid) to authenticated;

-- =============================================================================
-- 2. erase_guest: scrub POS checks linked by id, and unlinked ones by name
-- =============================================================================
create or replace function public.erase_guest(p_guest_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_g public.guests;
  v_leads uuid[];
begin
  select * into v_g from public.guests where id = p_guest_id for update;
  if not found then
    raise exception 'guest not found' using errcode = 'P0002';
  end if;

  if auth.uid() is null or not app_hidden.has_venue_role(
    v_g.venue_id, array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
  ) then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  update public.reservations r
     set guest_name = 'Erased guest', guest_phone = null, guest_email = null
   where r.venue_id = v_g.venue_id
     and (
       r.guest_id = v_g.id
       or (v_g.phone is not null and r.guest_phone = v_g.phone)
       or (v_g.email is not null and lower(r.guest_email) = lower(v_g.email))
     );

  select coalesce(array_agg(l.id), '{}') into v_leads
  from public.crm_leads l
  where l.venue_id = v_g.venue_id
    and (
      l.guest_id = v_g.id
      or (v_g.phone is not null and l.phone = v_g.phone)
      or (v_g.email is not null and lower(l.email) = lower(v_g.email))
    );

  delete from public.crm_notes where lead_id = any (v_leads);
  delete from public.crm_activity_log where lead_id = any (v_leads);
  update public.crm_leads
     set full_name = 'Erased lead', email = null, phone = null, company = null,
         tags = '{}', marketing_opt_in = false, deleted_at = coalesce(deleted_at, now())
   where id = any (v_leads);

  delete from public.guest_household_links where from_guest_id = v_g.id or to_guest_id = v_g.id;

  -- POS integrations do not link checks to guests yet, so most checks only carry the name the
  -- POS sent. Linked checks are matched by id (never another guest's); unlinked ones fall back
  -- to the display-name match, erring toward scrubbing for an erasure request.
  perform app_hidden.open_privilege_gate('pos_retention');
  update public.pos_checks
     set guest_name = null, raw_payload = null, guest_id = null
   where venue_id = v_g.venue_id
     and (
       guest_id = v_g.id
       or (
         guest_id is null
         and nullif(trim(v_g.full_name), '') is not null
         and lower(trim(guest_name)) = lower(trim(v_g.full_name))
       )
     );
  perform app_hidden.close_privilege_gate('pos_retention');

  delete from public.guests where id = v_g.id;

  perform app_hidden.audit_event(
    v_g.organization_id, v_g.venue_id, 'guest.erase', 'guests', v_g.id,
    jsonb_build_object('leads_anonymized', coalesce(array_length(v_leads, 1), 0))
  );
end;
$$;

revoke all on function public.erase_guest(uuid) from public, anon;
grant execute on function public.erase_guest(uuid) to authenticated;

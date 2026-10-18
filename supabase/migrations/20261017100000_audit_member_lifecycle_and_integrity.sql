-- Security-audit remediation (SECURITY_AUDIT_2026-10-17): member lifecycle, payroll integrity,
-- segregation of duties, audit coverage, and abuse controls.
--
--   C-02  memberships had no write path: add audited remove / change-role / transfer RPCs and an
--         explicit invite-accept flow (sign-up no longer silently joins invited users, P-10).
--   D-01  managers could hard-delete time punches with no trace: drop the policy, add void_time_entry.
--   A-06  org admins could edit their own pay; managers could approve their own requests.
--   D-03  generic audit triggers for destructive / sensitive changes.
--   D-05  organization_id can no longer drift on two manager-writable tables.
--   B-02  server-side entitlement helper (behind a flag), workspace creation caps, rate limiter.
--   P-05  organizations.ai_enabled opt-in for AI features.
--   D-02  least-privilege grants: grants now match policies; no anon table or function access.
--
-- Everything is SECURITY DEFINER with a pinned search_path and explicit grants.

-- -----------------------------------------------------------------------------
-- 1. Platform settings (single row, service/owner only) and helper predicates.
-- -----------------------------------------------------------------------------
create table if not exists app_hidden.platform_settings (
  singleton boolean primary key default true check (singleton),
  -- When true, paid side effects (AI, email, document scanning) require an active/trialing
  -- subscription or a grace trial. Default off so turning the paywall on is a deliberate act.
  billing_enforcement boolean not null default false,
  trial_days integer not null default 14 check (trial_days between 0 and 365),
  -- When true, member/role/ownership mutations on manager-level roles require an aal2 session.
  require_mfa_for_admin_actions boolean not null default false,
  -- Raw punch GPS is nulled after this many days (null = keep forever).
  gps_retention_days integer check (gps_retention_days is null or gps_retention_days >= 30)
);
insert into app_hidden.platform_settings (singleton, gps_retention_days) values (true, 365)
on conflict (singleton) do nothing;

alter table app_hidden.platform_settings enable row level security;
alter table app_hidden.platform_settings force row level security;
revoke all on app_hidden.platform_settings from public, anon, authenticated;

create or replace function app_hidden.mfa_satisfied()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select not coalesce((select s.require_mfa_for_admin_actions from app_hidden.platform_settings s), false)
         or coalesce(auth.jwt() ->> 'aal', '') = 'aal2';
$$;

-- May the caller manage a member who holds p_target_role in this org/venue?
--   owner/admin rows  -> owners only
--   venue_manager     -> org owners/admins
--   supervisor/staff  -> that venue's managers, org owners/admins
create or replace function app_hidden.can_manage_member_role(
  p_org uuid, p_venue uuid, p_target_role public.app_role
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when p_target_role in ('organization_owner', 'organization_admin') then
      app_hidden.has_org_role(p_org, array['organization_owner']::public.app_role[])
    when p_target_role = 'venue_manager' then
      app_hidden.has_org_role(p_org, array['organization_owner', 'organization_admin']::public.app_role[])
    when p_target_role in ('supervisor', 'staff') then
      p_venue is not null and app_hidden.has_venue_role(
        p_venue, array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
      )
    else false
  end;
$$;

create or replace function app_hidden.audit_event(
  p_org uuid, p_venue uuid, p_action text, p_target_table text, p_target_id uuid, p_metadata jsonb
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.audit_log (organization_id, venue_id, actor_user_id, action, target_table, target_id, metadata)
  values (p_org, p_venue, auth.uid(), p_action, p_target_table, p_target_id, coalesce(p_metadata, '{}'::jsonb));
exception when foreign_key_violation then
  -- The org/venue is being deleted in this same statement (cascade); keep the event, drop the link.
  insert into public.audit_log (actor_user_id, action, target_table, target_id, metadata)
  values (auth.uid(), p_action, p_target_table, p_target_id, coalesce(p_metadata, '{}'::jsonb));
end;
$$;

revoke all on function app_hidden.audit_event(uuid, uuid, text, text, uuid, jsonb) from public;

-- -----------------------------------------------------------------------------
-- 2. Member lifecycle RPCs (C-02).
-- -----------------------------------------------------------------------------
create or replace function public.team_members(p_venue_id uuid)
returns table (
  membership_id uuid,
  user_id uuid,
  role public.app_role,
  display_name text,
  venue_id uuid,
  organization_id uuid
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_org uuid;
begin
  if auth.uid() is null
     or not app_hidden.has_venue_role(
       p_venue_id,
       array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
     ) then
    raise exception 'Not allowed to view this venue team' using errcode = '42501';
  end if;

  select v.organization_id into v_org from public.venues v where v.id = p_venue_id;

  return query
    select m.id, m.user_id, m.role, p.display_name, m.venue_id, m.organization_id
    from public.memberships m
    left join public.profiles p on p.id = m.user_id
    where m.organization_id = v_org
      and (m.venue_id = p_venue_id or m.venue_id is null)
    order by (m.venue_id is null) desc, p.display_name nulls last, m.user_id;
end;
$$;

create or replace function public.remove_member(p_membership_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_m public.memberships;
begin
  if auth.uid() is null then
    raise exception 'Must be signed in' using errcode = '42501';
  end if;

  select * into v_m from public.memberships where id = p_membership_id for update;
  if not found then
    raise exception 'membership not found' using errcode = 'P0002';
  end if;

  if v_m.user_id = auth.uid() then
    raise exception 'cannot_modify_self' using errcode = 'P0001';
  end if;

  if not app_hidden.can_manage_member_role(v_m.organization_id, v_m.venue_id, v_m.role) then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  if v_m.role in ('organization_owner', 'organization_admin', 'venue_manager')
     and not app_hidden.mfa_satisfied() then
    raise exception 'mfa_required' using errcode = '42501';
  end if;

  if v_m.role = 'organization_owner' and not exists (
    select 1 from public.memberships o
    where o.organization_id = v_m.organization_id and o.role = 'organization_owner' and o.id <> v_m.id
  ) then
    raise exception 'last_owner' using errcode = 'P0001';
  end if;

  delete from public.memberships where id = v_m.id;

  -- Stop pushes to every venue the user can no longer reach (a remaining org-level or
  -- venue-level membership keeps its own tokens working).
  update public.push_tokens pt
     set enabled = false, disabled_at = coalesce(pt.disabled_at, now())
   where pt.user_id = v_m.user_id
     and pt.organization_id = v_m.organization_id
     and pt.enabled
     and not exists (
       select 1 from public.memberships mm
       where mm.user_id = v_m.user_id
         and mm.organization_id = pt.organization_id
         and (mm.venue_id is null or mm.venue_id = pt.venue_id)
     );

  perform app_hidden.audit_event(
    v_m.organization_id, v_m.venue_id, 'member.remove', 'memberships', v_m.id,
    jsonb_build_object('user_id', v_m.user_id, 'role', v_m.role)
  );
end;
$$;

create or replace function public.change_member_role(p_membership_id uuid, p_new_role public.app_role)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_m public.memberships;
  v_org_level boolean;
begin
  if auth.uid() is null then
    raise exception 'Must be signed in' using errcode = '42501';
  end if;

  select * into v_m from public.memberships where id = p_membership_id for update;
  if not found then
    raise exception 'membership not found' using errcode = 'P0002';
  end if;

  v_org_level := v_m.venue_id is null;
  if v_org_level and p_new_role not in ('organization_owner', 'organization_admin') then
    raise exception 'role_not_allowed' using errcode = 'P0001';
  end if;
  if not v_org_level and p_new_role not in ('venue_manager', 'supervisor', 'staff') then
    raise exception 'role_not_allowed' using errcode = 'P0001';
  end if;

  if p_new_role = v_m.role then
    return;
  end if;

  if v_m.user_id = auth.uid() then
    -- The only self-service change: an owner stepping down to admin while another owner remains.
    if not (v_m.role = 'organization_owner' and p_new_role = 'organization_admin') then
      raise exception 'cannot_modify_self' using errcode = 'P0001';
    end if;
  elsif not (
    app_hidden.can_manage_member_role(v_m.organization_id, v_m.venue_id, v_m.role)
    and app_hidden.can_manage_member_role(v_m.organization_id, v_m.venue_id, p_new_role)
  ) then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  if (v_m.role in ('organization_owner', 'organization_admin', 'venue_manager')
      or p_new_role in ('organization_owner', 'organization_admin', 'venue_manager'))
     and not app_hidden.mfa_satisfied() then
    raise exception 'mfa_required' using errcode = '42501';
  end if;

  if v_m.role = 'organization_owner' and p_new_role <> 'organization_owner' and not exists (
    select 1 from public.memberships o
    where o.organization_id = v_m.organization_id and o.role = 'organization_owner' and o.id <> v_m.id
  ) then
    raise exception 'last_owner' using errcode = 'P0001';
  end if;

  update public.memberships set role = p_new_role where id = v_m.id;

  perform app_hidden.audit_event(
    v_m.organization_id, v_m.venue_id, 'member.change_role', 'memberships', v_m.id,
    jsonb_build_object('user_id', v_m.user_id, 'from', v_m.role, 'to', p_new_role)
  );
end;
$$;

-- Promotes an existing member of the organization to organization_owner. The caller stays an
-- owner, so a sole owner can hand the business to someone else and later step down with
-- change_member_role (or delete their own account, which requires another owner).
create or replace function public.transfer_ownership(p_organization_id uuid, p_new_owner_user_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_existing public.memberships;
begin
  if auth.uid() is null
     or not app_hidden.has_org_role(p_organization_id, array['organization_owner']::public.app_role[]) then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  if p_new_owner_user_id = auth.uid() then
    raise exception 'cannot_modify_self' using errcode = 'P0001';
  end if;

  if not app_hidden.mfa_satisfied() then
    raise exception 'mfa_required' using errcode = '42501';
  end if;

  if not exists (
    select 1 from public.memberships m
    where m.organization_id = p_organization_id and m.user_id = p_new_owner_user_id
  ) then
    raise exception 'target_not_a_member' using errcode = 'P0001';
  end if;

  select * into v_existing from public.memberships
  where organization_id = p_organization_id and user_id = p_new_owner_user_id and venue_id is null
  for update;

  if found then
    if v_existing.role <> 'organization_owner' then
      update public.memberships set role = 'organization_owner' where id = v_existing.id;
    end if;
  else
    insert into public.memberships (user_id, organization_id, venue_id, role, created_by)
    values (p_new_owner_user_id, p_organization_id, null, 'organization_owner', auth.uid());
  end if;

  perform app_hidden.audit_event(
    p_organization_id, null, 'member.transfer_ownership', 'memberships', null,
    jsonb_build_object('new_owner_user_id', p_new_owner_user_id)
  );
end;
$$;

-- Invites: sign-up used to redeem every pending invite for the address silently, so a rogue
-- tenant could pre-invite people into its venue. Redemption is now an explicit act.
create or replace function app_hidden.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = 'public'
as $$
begin
  insert into public.profiles (id) values (new.id)
  on conflict (id) do nothing;
  return new;
end;
$$;

create or replace function public.my_pending_invites()
returns table (
  invite_id uuid,
  organization_id uuid,
  organization_name text,
  venue_id uuid,
  venue_name text,
  role public.app_role,
  invited_at timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_email text;
begin
  if auth.uid() is null then
    raise exception 'Must be signed in' using errcode = '42501';
  end if;

  select lower(u.email) into v_email from auth.users u
  where u.id = auth.uid() and u.email_confirmed_at is not null;
  if v_email is null then
    return;
  end if;

  return query
    select i.id, i.organization_id, o.name, i.venue_id, v.name, i.role, i.created_at
    from public.invites i
    join public.organizations o on o.id = i.organization_id
    left join public.venues v on v.id = i.venue_id
    where lower(i.email) = v_email
      and i.status = 'pending'
      and i.expires_at > now()
    order by i.created_at desc;
end;
$$;

create or replace function public.accept_invite(p_invite_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_email text;
  v_invite public.invites;
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

  insert into public.memberships (user_id, organization_id, venue_id, role, created_by)
  values (auth.uid(), v_invite.organization_id, v_invite.venue_id, v_invite.role, v_invite.invited_by)
  on conflict (user_id, organization_id, venue_id) do nothing;

  update public.invites set status = 'accepted' where id = v_invite.id;

  perform app_hidden.audit_event(
    v_invite.organization_id, v_invite.venue_id, 'invite.accept', 'invites', v_invite.id,
    jsonb_build_object('role', v_invite.role)
  );
end;
$$;

revoke all on function public.team_members(uuid) from public, anon;
revoke all on function public.remove_member(uuid) from public, anon;
revoke all on function public.change_member_role(uuid, public.app_role) from public, anon;
revoke all on function public.transfer_ownership(uuid, uuid) from public, anon;
revoke all on function public.my_pending_invites() from public, anon;
revoke all on function public.accept_invite(uuid) from public, anon;
grant execute on function public.team_members(uuid) to authenticated;
grant execute on function public.remove_member(uuid) to authenticated;
grant execute on function public.change_member_role(uuid, public.app_role) to authenticated;
grant execute on function public.transfer_ownership(uuid, uuid) to authenticated;
grant execute on function public.my_pending_invites() to authenticated;
grant execute on function public.accept_invite(uuid) to authenticated;

-- -----------------------------------------------------------------------------
-- 3. Time punches: no hard deletes (D-01); raw GPS never copied into the audit log (P-04).
-- -----------------------------------------------------------------------------
drop policy if exists time_entries_delete on public.time_entries;
revoke delete on public.time_entries from authenticated;

create or replace function app_hidden.scrub_time_entry_json(j jsonb)
returns jsonb
language sql
immutable
as $$
  select coalesce(j, '{}'::jsonb)
    - 'clock_in_lat' - 'clock_in_lng' - 'clock_in_accuracy_m'
    - 'clock_out_lat' - 'clock_out_lng' - 'clock_out_accuracy_m';
$$;

create or replace function public.correct_time_entry(
  p_entry_id uuid,
  p_clock_out_at timestamptz default null,
  p_breaks jsonb default null,
  p_reason text default null
)
returns public.time_entries
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_entry public.time_entries;
  v_before jsonb;
begin
  select * into v_entry from public.time_entries where id = p_entry_id;
  if v_entry.id is null then
    raise exception 'time entry % does not exist', p_entry_id using errcode = 'P0002';
  end if;

  if not app_hidden.has_venue_role(
    v_entry.venue_id,
    array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
  ) then
    raise exception 'forbidden: only managers can correct time entries' using errcode = '42501';
  end if;

  if v_entry.user_id = auth.uid() then
    raise exception 'managers cannot correct their own time entries' using errcode = '42501';
  end if;

  if p_clock_out_at is not null then
    if p_clock_out_at <= v_entry.clock_in_at then
      raise exception 'clock-out must be after clock-in' using errcode = '22023';
    end if;
    if p_clock_out_at > now() + interval '1 minute' then
      raise exception 'clock-out cannot be in the future' using errcode = '22023';
    end if;
  end if;

  v_before := app_hidden.scrub_time_entry_json(to_jsonb(v_entry));

  -- Lets this one statement through the otherwise-blanket "closed entries are immutable"
  -- and breaks-validation rules in app_hidden.enforce_time_entry_update, for this
  -- transaction only.
  perform set_config('app.time_entry_correction', 'on', true);

  update public.time_entries
  set
    clock_out_at = coalesce(p_clock_out_at, clock_out_at),
    is_open = case when p_clock_out_at is not null then false else is_open end,
    breaks = coalesce(p_breaks, breaks)
  where id = p_entry_id
  returning * into v_entry;

  -- Reset immediately so the bypass cannot outlive this statement within the transaction.
  perform set_config('app.time_entry_correction', 'off', true);

  insert into public.audit_log (
    organization_id, venue_id, actor_user_id, action, target_table, target_id, metadata
  ) values (
    v_entry.organization_id, v_entry.venue_id, auth.uid(), 'time_entry.correct',
    'time_entries', v_entry.id,
    jsonb_build_object(
      'before', v_before,
      'after', app_hidden.scrub_time_entry_json(to_jsonb(v_entry)),
      'reason', p_reason
    )
  );

  return v_entry;
end;
$$;

revoke all on function public.correct_time_entry(uuid, timestamptz, jsonb, text) from public, anon;
grant execute on function public.correct_time_entry(uuid, timestamptz, jsonb, text) to authenticated;

-- Existing audit rows carried raw coordinates; strip them (3-year records stay, GPS goes).
update public.audit_log
   set metadata = (metadata - 'before' - 'after')
     || jsonb_build_object(
          'before', app_hidden.scrub_time_entry_json(metadata -> 'before'),
          'after', app_hidden.scrub_time_entry_json(metadata -> 'after')
        )
 where action = 'time_entry.correct' and metadata ? 'before';

-- Voiding replaces deletion: managers only, never their own punch, reason required, and the
-- full (GPS-free) record is kept in the audit log for the same 3-year wage-record period.
create or replace function public.void_time_entry(p_time_entry_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_entry public.time_entries;
  v_reason text := trim(coalesce(p_reason, ''));
begin
  select * into v_entry from public.time_entries where id = p_time_entry_id for update;
  if not found then
    raise exception 'time entry does not exist' using errcode = 'P0002';
  end if;

  if auth.uid() is null or not app_hidden.has_venue_role(
    v_entry.venue_id,
    array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
  ) then
    raise exception 'forbidden: only managers can void time entries' using errcode = '42501';
  end if;

  if v_entry.user_id = auth.uid() then
    raise exception 'managers cannot void their own time entries' using errcode = '42501';
  end if;

  if char_length(v_reason) < 5 or char_length(v_reason) > 500 then
    raise exception 'a reason of 5-500 characters is required' using errcode = '22023';
  end if;

  perform app_hidden.audit_event(
    v_entry.organization_id, v_entry.venue_id, 'time_entry.void', 'time_entries', v_entry.id,
    jsonb_build_object('before', app_hidden.scrub_time_entry_json(to_jsonb(v_entry)), 'reason', v_reason)
  );

  delete from public.time_entries where id = v_entry.id;
end;
$$;

revoke all on function public.void_time_entry(uuid, text) from public, anon;
grant execute on function public.void_time_entry(uuid, text) to authenticated;

-- -----------------------------------------------------------------------------
-- 4. Segregation of duties (A-06).
-- -----------------------------------------------------------------------------
-- Pay, PTO and employment fields:
--   owners          manage everyone, themselves included (they own the business)
--   org admins      manage venue-level staff, never themselves, other admins or owners
--   venue managers  manage non-managers (unchanged)
create or replace function app_hidden.can_manage_staff_profile(p_venue uuid, p_user uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.memberships m join public.venues v on v.id = p_venue
    where m.user_id = p_user and m.organization_id = v.organization_id
      and (m.venue_id = p_venue or m.venue_id is null)
  ) and (
    app_hidden.has_venue_role(p_venue, array['organization_owner']::public.app_role[])
    or (
      app_hidden.has_venue_role(p_venue, array['organization_admin']::public.app_role[])
      and p_user is distinct from auth.uid()
      and not exists (
        select 1 from public.memberships m join public.venues v on v.id = p_venue
        where m.user_id = p_user and m.organization_id = v.organization_id
          and m.venue_id is null and m.role in ('organization_owner', 'organization_admin')
      )
    )
    or (
      app_hidden.has_venue_role(p_venue, array['venue_manager']::public.app_role[])
      and not exists (
        select 1 from public.memberships m join public.venues v on v.id = p_venue
        where m.user_id = p_user and m.organization_id = v.organization_id
          and (m.venue_id = p_venue or m.venue_id is null)
          and m.role in ('venue_manager', 'organization_owner', 'organization_admin')
      )
    )
  );
$$;

-- Staff requests: a reviewer may not approve their own request (owners excepted).
create or replace function app_hidden.enforce_staff_request_update()
returns trigger
language plpgsql
security definer
set search_path = 'public'
as $$
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
     )
     and (
       auth.uid() is distinct from old.user_id
       or app_hidden.has_venue_role(new.venue_id, array['organization_owner']::public.app_role[])
     )
  then
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
$$;

-- -----------------------------------------------------------------------------
-- 5. organization_id is immutable on two manager-writable tables (D-05).
-- -----------------------------------------------------------------------------
create or replace function app_hidden.freeze_organization_id()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.organization_id is distinct from old.organization_id then
    raise exception 'organization_id cannot be changed' using errcode = '42501';
  end if;
  return new;
end;
$$;

drop trigger if exists freeze_organization_id on public.checklist_completions;
create trigger freeze_organization_id
  before update on public.checklist_completions
  for each row execute function app_hidden.freeze_organization_id();

drop trigger if exists freeze_organization_id on public.email_templates;
create trigger freeze_organization_id
  before update on public.email_templates
  for each row execute function app_hidden.freeze_organization_id();

-- -----------------------------------------------------------------------------
-- 6. Audit coverage (D-03): destructive and sensitive changes are recorded.
-- TG_ARGV[0] is the action prefix; the remaining args are the column names captured. Delete
-- and insert events capture only the listed (non-PII) columns.
-- -----------------------------------------------------------------------------
create or replace function app_hidden.audit_row_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row jsonb := to_jsonb(case when tg_op = 'DELETE' then old else new end);
  v_old jsonb := case when tg_op = 'INSERT' then null else to_jsonb(old) end;
  v_new jsonb := case when tg_op = 'DELETE' then null else to_jsonb(new) end;
  v_meta jsonb := '{}'::jsonb;
  v_key text;
  v_changed boolean := tg_op <> 'UPDATE';
  v_org uuid;
  v_venue uuid;
  i integer;
begin
  -- Account deletion cascades through these tables; the deletion itself is audited separately.
  if app_hidden.account_deletion_in_progress() then
    return case when tg_op = 'DELETE' then old else new end;
  end if;

  for i in 1 .. coalesce(tg_nargs, 0) - 1 loop
    v_key := tg_argv[i];
    if tg_op = 'UPDATE' then
      if (v_old -> v_key) is distinct from (v_new -> v_key) then
        v_changed := true;
        v_meta := v_meta || jsonb_build_object(v_key, jsonb_build_object('old', v_old -> v_key, 'new', v_new -> v_key));
      end if;
    else
      v_meta := v_meta || jsonb_build_object(v_key, v_row -> v_key);
    end if;
  end loop;

  if not v_changed then
    return case when tg_op = 'DELETE' then old else new end;
  end if;

  v_org := nullif(v_row ->> 'organization_id', '')::uuid;
  v_venue := case when tg_table_name = 'venues' then (v_row ->> 'id')::uuid
                  else nullif(v_row ->> 'venue_id', '')::uuid end;

  perform app_hidden.audit_event(
    v_org, v_venue, tg_argv[0] || '.' || lower(tg_op), tg_table_name, (v_row ->> 'id')::uuid, v_meta
  );
  return case when tg_op = 'DELETE' then old else new end;
end;
$$;

revoke all on function app_hidden.audit_row_change() from public;

drop trigger if exists audit_incident_delete on public.incidents;
create trigger audit_incident_delete after delete on public.incidents
  for each row execute function app_hidden.audit_row_change('incident', 'severity', 'status', 'reported_by');

drop trigger if exists audit_guest_delete on public.guests;
create trigger audit_guest_delete after delete on public.guests
  for each row execute function app_hidden.audit_row_change('guest');

drop trigger if exists audit_document_delete on public.documents;
create trigger audit_document_delete after delete on public.documents
  for each row execute function app_hidden.audit_row_change('document', 'storage_path');

drop trigger if exists audit_hr_pay_change on public.employee_hr_profiles;
create trigger audit_hr_pay_change after update on public.employee_hr_profiles
  for each row execute function app_hidden.audit_row_change(
    'hr_profile', 'user_id', 'hourly_rate_cents', 'pto_hours', 'sick_hours'
  );

drop trigger if exists audit_venue_location_change on public.venues;
create trigger audit_venue_location_change after update on public.venues
  for each row execute function app_hidden.audit_row_change(
    'venue', 'latitude', 'longitude', 'geofence_radius_m', 'timezone'
  );

drop trigger if exists audit_invite_create on public.invites;
create trigger audit_invite_create after insert on public.invites
  for each row execute function app_hidden.audit_row_change('invite', 'role', 'invited_by');

-- -----------------------------------------------------------------------------
-- 7. Abuse controls (B-02, B-03): rate limiter, entitlement, workspace caps, AI opt-in.
-- -----------------------------------------------------------------------------
create table if not exists app_hidden.rate_limit_counters (
  key text not null check (char_length(key) between 1 and 200),
  window_start timestamptz not null,
  hits integer not null default 0,
  primary key (key, window_start)
);
alter table app_hidden.rate_limit_counters enable row level security;
alter table app_hidden.rate_limit_counters force row level security;
revoke all on app_hidden.rate_limit_counters from public, anon, authenticated;

-- Fixed-window counter. Returns true while the caller is within p_max hits for the window.
create or replace function public.consume_rate_limit(p_key text, p_max integer, p_window_seconds integer)
returns boolean
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_window timestamptz;
  v_hits integer;
begin
  if p_key is null or char_length(p_key) not between 1 and 200
     or p_max is null or p_max < 1
     or p_window_seconds is null or p_window_seconds < 1 then
    raise exception 'invalid rate limit arguments' using errcode = '22023';
  end if;

  v_window := to_timestamp(floor(extract(epoch from now()) / p_window_seconds) * p_window_seconds);

  insert into app_hidden.rate_limit_counters as c (key, window_start, hits)
  values (p_key, v_window, 1)
  on conflict (key, window_start) do update set hits = c.hits + 1
  returning c.hits into v_hits;

  if v_hits = 1 and random() < 0.02 then
    delete from app_hidden.rate_limit_counters where window_start < now() - interval '2 days';
  end if;

  return v_hits <= p_max;
end;
$$;

create or replace function public.org_is_entitled(p_organization_id uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_enforce boolean;
  v_trial_days integer;
  v_status text;
  v_created timestamptz;
begin
  select s.billing_enforcement, s.trial_days into v_enforce, v_trial_days
  from app_hidden.platform_settings s;

  if not coalesce(v_enforce, false) then
    return true;
  end if;

  select sub.status into v_status from public.subscriptions sub where sub.organization_id = p_organization_id;
  if public.subscription_is_entitled(v_status) then
    return true;
  end if;

  select o.created_at into v_created from public.organizations o where o.id = p_organization_id;
  return v_created is not null and v_created + make_interval(days => v_trial_days) > now();
end;
$$;

revoke all on function public.consume_rate_limit(text, integer, integer) from public, anon, authenticated;
revoke all on function public.org_is_entitled(uuid) from public, anon, authenticated;
grant execute on function public.consume_rate_limit(text, integer, integer) to service_role;
grant execute on function public.org_is_entitled(uuid) to service_role;

-- AI features are opt-in per organization. Existing organizations keep working (true); new ones
-- start disabled until an owner/admin enables them after seeing the processor disclosure.
alter table public.organizations add column if not exists ai_enabled boolean not null default true;
alter table public.organizations alter column ai_enabled set default false;

create or replace function public.set_org_ai_enabled(p_organization_id uuid, p_enabled boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null or not app_hidden.has_org_role(
    p_organization_id, array['organization_owner', 'organization_admin']::public.app_role[]
  ) then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  update public.organizations set ai_enabled = coalesce(p_enabled, false) where id = p_organization_id;

  perform app_hidden.audit_event(
    p_organization_id, null, 'organization.ai_enabled', 'organizations', p_organization_id,
    jsonb_build_object('enabled', coalesce(p_enabled, false))
  );
end;
$$;

revoke all on function public.set_org_ai_enabled(uuid, boolean) from public, anon;
grant execute on function public.set_org_ai_enabled(uuid, boolean) to authenticated;

-- organizations has no client UPDATE policy, so ai_enabled changes only through the RPC above.

-- Workspace creation: bounded per user (cheap sock-puppet orgs were the cost-abuse vector).
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

  perform pg_advisory_xact_lock(hashtext('create_workspace:' || v_uid::text));

  if (select count(*) from public.organizations o
      where o.created_by = v_uid and o.created_at > now() - interval '1 day') >= 3 then
    raise exception 'workspace_rate_limited' using errcode = 'P0001';
  end if;
  if (select count(*) from public.memberships m
      where m.user_id = v_uid and m.role = 'organization_owner') >= 10 then
    raise exception 'workspace_limit_reached' using errcode = 'P0001';
  end if;

  insert into public.organizations (name, created_by)
  values (v_org_name, v_uid)
  returning id into v_org_id;

  insert into public.venues (organization_id, name, created_by, timezone)
  values (v_org_id, v_venue_name, v_uid, v_timezone)
  returning id into v_venue_id;

  -- venue_id is null here by design: memberships_org_level_roles_check requires it for an
  -- organization_owner row. The owner's access to this (and any future) venue in the org
  -- comes from the org-level role, not a per-venue grant.
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

-- AI rate limit (B-03): reservations now record the user, and the per-user window counts every
-- reservation (pending, committed or released) so failed/truncated calls are no longer free.
alter table public.ai_budget_reservations add column if not exists user_id uuid references auth.users (id) on delete set null;

create or replace function public.reserve_ai_budget(
  p_org_id uuid,
  p_user_id uuid,
  p_estimated_usd numeric,
  p_monthly_budget_usd numeric,
  p_rate_limit_max integer default 20,
  p_rate_limit_window_minutes integer default 10,
  p_ttl_seconds integer default 120
)
returns uuid
language plpgsql
security definer
set search_path = 'public'
as $$
declare
  v_reservation_id uuid;
  v_spend numeric;
  v_recent integer;
begin
  -- Serialize budget decisions per org.
  perform pg_advisory_xact_lock(hashtext('ai_budget:' || p_org_id::text));

  select public.ai_org_spend_this_month(p_org_id) into v_spend;
  if coalesce(v_spend, 0) + p_estimated_usd > p_monthly_budget_usd then
    raise exception 'monthly_budget_exceeded' using errcode = 'P0001';
  end if;

  -- Every reservation by this user in the window counts, whatever its outcome; usage events
  -- written before reservations carried a user (reservation_id is null) are added so the
  -- limit does not reset at deploy time.
  select (select count(*) from public.ai_budget_reservations r
          where r.user_id = p_user_id
            and r.created_at >= now() - (p_rate_limit_window_minutes || ' minutes')::interval)
       + (select count(*) from public.ai_usage_events e
          where e.user_id = p_user_id and e.reservation_id is null
            and e.created_at >= now() - (p_rate_limit_window_minutes || ' minutes')::interval)
    into v_recent;

  if v_recent >= p_rate_limit_max then
    raise exception 'rate_limited' using errcode = 'P0001';
  end if;

  insert into public.ai_budget_reservations (organization_id, user_id, reserved_usd, status, expires_at)
  values (p_org_id, p_user_id, p_estimated_usd, 'pending', now() + (p_ttl_seconds || ' seconds')::interval)
  returning id into v_reservation_id;

  return v_reservation_id;
end;
$$;

revoke all on function public.reserve_ai_budget(uuid, uuid, numeric, numeric, integer, integer, integer) from public, anon, authenticated;
grant execute on function public.reserve_ai_budget(uuid, uuid, numeric, numeric, integer, integer, integer) to service_role;

-- -----------------------------------------------------------------------------
-- 8. Least-privilege grants (D-02).
-- -----------------------------------------------------------------------------
-- Future tables/functions in public start with NO client access; migrations must grant
-- explicitly (see supabase/tests/database/security_invariants.test.sql).
alter default privileges for role postgres in schema public revoke all on tables from anon, authenticated;
alter default privileges for role postgres in schema public revoke all on sequences from anon, authenticated;
alter default privileges for role postgres in schema public revoke execute on functions from public, anon, authenticated;
-- The implicit PUBLIC execute grant is a role-wide default, not a schema one, so removing it needs the
-- global form. Consequence for authors: every new function a client or RLS policy must call (also
-- in app_hidden) needs an explicit grant, as the existing migrations already do.
alter default privileges for role postgres revoke execute on functions from public;

-- Tables with no client policies at all must still be forced (service_role and owners bypass).
alter table public.attestation_challenges force row level security;

-- anon has no policies anywhere; take away the table-level reads that RLS was the only guard for.
revoke all on all tables in schema public from anon;

-- Functions: keep exactly what authenticated/service_role could already call, drop anon and
-- the implicit PUBLIC grant. Extension-owned functions are left alone.
do $$
declare
  r record;
  v_auth boolean;
  v_service boolean;
begin
  for r in
    select p.oid, p.oid::regprocedure as sig
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.prokind in ('f', 'p')
      and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
  loop
    v_auth := has_function_privilege('authenticated', r.oid, 'execute');
    v_service := has_function_privilege('service_role', r.oid, 'execute');
    execute format('revoke execute on function %s from public, anon', r.sig);
    if v_auth then
      execute format('grant execute on function %s to authenticated', r.sig);
    end if;
    if v_service then
      execute format('grant execute on function %s to service_role', r.sig);
    end if;
  end loop;
end $$;

-- Table privileges for authenticated now match the policies: a command with no policy for
-- authenticated can never succeed under forced RLS, so the grant only widens the blast radius
-- if RLS were ever disabled on a table.
do $$
declare
  r record;
  c record;
begin
  for r in
    select cl.oid::regclass as tbl, cl.relname
    from pg_class cl join pg_namespace n on n.oid = cl.relnamespace
    where n.nspname = 'public' and cl.relkind in ('r', 'p')
  loop
    for c in select * from (values ('SELECT'), ('INSERT'), ('UPDATE'), ('DELETE')) as t(cmd) loop
      if not exists (
        select 1 from pg_policies p
        where p.schemaname = 'public' and p.tablename = r.relname
          and p.cmd in (c.cmd, 'ALL')
          and p.roles && array['authenticated', 'public']::name[]
      ) then
        execute format('revoke %s on %s from authenticated', c.cmd, r.tbl);
      end if;
    end loop;
  end loop;
end $$;

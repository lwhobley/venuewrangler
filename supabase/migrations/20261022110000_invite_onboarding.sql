-- Launch review A1: invited staff got no email, could not see their invite, and an expired
-- invite blocked a replacement. This migration covers the database half:
--
--   * invites carry the invitee's name (full_name); accepting copies it onto the new member's
--     profile when they have not set a display name themselves.
--   * public.create_invite / public.resend_invite are the manager-facing write path. An expired
--     invite for the same venue + email is marked 'expired' instead of blocking (the partial
--     unique index only covers status = 'pending'); a live one is replaced by the new invite.
--   * Owner decision on the review's open question: venue managers may NOT invite (or
--     promote) other managers. Inviting into a role now uses the same rule as changing a
--     member's role (app_hidden.can_manage_member_role): venue_manager invites need an
--     organization owner/admin. Enforced in the RPCs and in the direct-table policies.
--   * Each email delivery (supabase/functions/invite-send-email) is recorded through the
--     service-role-only public.record_invite_email_sent, so managers can see when it went out.
--   * my_pending_invites also returns who invited the person and when the invite expires.

alter table public.invites
  add column if not exists full_name text
    check (full_name is null or char_length(full_name) between 1 and 120),
  add column if not exists last_sent_at timestamptz,
  add column if not exists send_count integer not null default 0 check (send_count >= 0);

-- Clients may only ever change an invite's status (the trigger below decides which moves).
revoke update on public.invites from authenticated;
grant update (status) on public.invites to authenticated;

-- Same rules as before, plus: pending -> expired once the invite is past its expiry, and the
-- send bookkeeping columns change only inside record_invite_email_sent.
create or replace function app_hidden.enforce_invite_revoke_only()
returns trigger
language plpgsql
security definer
set search_path = 'public'
as $$
begin
  if app_hidden.account_deletion_in_progress() then
    return new;
  end if;

  if new.organization_id is distinct from old.organization_id
    or new.venue_id is distinct from old.venue_id
    or new.email is distinct from old.email
    or new.role is distinct from old.role
    or new.full_name is distinct from old.full_name
    or new.invited_by is distinct from old.invited_by
    or new.created_at is distinct from old.created_at
    or new.expires_at is distinct from old.expires_at
  then
    raise exception 'only an invite''s status may be changed' using errcode = '42501';
  end if;

  if coalesce(current_setting('app.invite_send_record', true), '') = 'on' then
    if new.status is distinct from old.status then
      raise exception 'recording a send cannot change an invite''s status' using errcode = '42501';
    end if;
    return new;
  end if;

  if new.last_sent_at is distinct from old.last_sent_at
    or new.send_count is distinct from old.send_count
  then
    raise exception 'invite send records are written by the email function only' using errcode = '42501';
  end if;

  if old.status <> 'pending' or new.status not in ('revoked', 'accepted', 'expired') then
    raise exception 'invites can only move from pending to revoked, accepted or expired' using errcode = '42501';
  end if;
  if new.status = 'expired' and old.expires_at > now() then
    raise exception 'only an invite past its expiry can be marked expired' using errcode = '42501';
  end if;
  return new;
end;
$$;

-- The policies decide who may touch invites at all; can_manage_member_role decides which
-- roles they may hand out (venue_manager: owners/admins only). organization_id is already
-- derived from venue_id by the BEFORE INSERT trigger when WITH CHECK runs.
grant execute on function app_hidden.can_manage_member_role(uuid, uuid, public.app_role) to authenticated;

drop policy if exists invites_insert_managers on public.invites;
create policy invites_insert_managers on public.invites
  for insert to authenticated
  with check (
    app_hidden.has_venue_role(
      venue_id,
      array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
    )
    and app_hidden.can_manage_member_role(organization_id, venue_id, role)
  );

drop policy if exists invites_update_managers on public.invites;
create policy invites_update_managers on public.invites
  for update to authenticated
  using (
    app_hidden.has_venue_role(
      venue_id,
      array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
    )
    and app_hidden.can_manage_member_role(organization_id, venue_id, role)
  )
  with check (
    app_hidden.has_venue_role(
      venue_id,
      array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
    )
    and app_hidden.can_manage_member_role(organization_id, venue_id, role)
  );

-- -----------------------------------------------------------------------------
-- Manager write path.
-- -----------------------------------------------------------------------------
create or replace function public.create_invite(
  p_venue_id uuid,
  p_email text,
  p_role public.app_role,
  p_full_name text default null
)
returns public.invites
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_email text := lower(trim(coalesce(p_email, '')));
  v_name text := nullif(regexp_replace(trim(coalesce(p_full_name, '')), '\s+', ' ', 'g'), '');
  v_org uuid;
  v_invite public.invites;
begin
  if auth.uid() is null then
    raise exception 'Must be signed in' using errcode = '42501';
  end if;

  select v.organization_id into v_org from public.venues v where v.id = p_venue_id;
  if v_org is null or not app_hidden.has_venue_role(
    p_venue_id, array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
  ) then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  if p_role is null or p_role not in ('venue_manager', 'supervisor', 'staff') then
    raise exception 'role_not_allowed' using errcode = 'P0001';
  end if;
  if not app_hidden.can_manage_member_role(v_org, p_venue_id, p_role) then
    raise exception 'forbidden_role' using errcode = '42501';
  end if;

  if char_length(v_email) > 254 or v_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then
    raise exception 'invalid_email' using errcode = '22023';
  end if;
  if v_name is not null and char_length(v_name) > 120 then
    raise exception 'invalid_name' using errcode = '22023';
  end if;

  if exists (
    select 1 from auth.users u
    join public.memberships m on m.user_id = u.id
    where lower(u.email) = v_email
      and m.organization_id = v_org
      and (m.venue_id = p_venue_id or m.venue_id is null)
  ) then
    raise exception 'already_member' using errcode = 'P0001';
  end if;

  perform pg_advisory_xact_lock(hashtext('invite:' || p_venue_id::text || ':' || v_email));

  -- A live invite for this person is replaced by the new one, but only by someone allowed to
  -- issue that invite's role (a manager cannot quietly downgrade an owner's manager invite).
  if exists (
    select 1 from public.invites i
    where i.venue_id = p_venue_id and i.email = v_email and i.status = 'pending'
      and i.expires_at > now()
      and not app_hidden.can_manage_member_role(v_org, p_venue_id, i.role)
  ) then
    raise exception 'forbidden_role' using errcode = '42501';
  end if;

  update public.invites i set status = 'expired'
   where i.venue_id = p_venue_id and i.email = v_email and i.status = 'pending'
     and i.expires_at <= now();
  update public.invites i set status = 'revoked'
   where i.venue_id = p_venue_id and i.email = v_email and i.status = 'pending';

  -- organization_id, invited_by and email normalisation come from prepare_invite_insert.
  insert into public.invites (venue_id, email, role, full_name)
  values (p_venue_id, v_email, p_role, v_name)
  returning * into v_invite;

  return v_invite;
end;
$$;

-- Resending a live invite keeps it (and the link already emailed); an expired one is replaced
-- by a fresh 14-day copy with the same role and name. Either way the caller then asks
-- invite-send-email to deliver the returned invite.
create or replace function public.resend_invite(p_invite_id uuid)
returns public.invites
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_invite public.invites;
begin
  if auth.uid() is null then
    raise exception 'Must be signed in' using errcode = '42501';
  end if;

  select * into v_invite from public.invites where id = p_invite_id;
  if not found or not app_hidden.has_venue_role(
    v_invite.venue_id, array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
  ) then
    raise exception 'invite_not_found' using errcode = 'P0002';
  end if;
  if not app_hidden.can_manage_member_role(v_invite.organization_id, v_invite.venue_id, v_invite.role) then
    raise exception 'forbidden_role' using errcode = '42501';
  end if;

  if v_invite.status = 'pending' and v_invite.expires_at > now() then
    return v_invite;
  end if;
  if v_invite.status not in ('pending', 'expired') then
    raise exception 'invite_not_pending' using errcode = 'P0001';
  end if;

  return public.create_invite(v_invite.venue_id, v_invite.email, v_invite.role, v_invite.full_name);
end;
$$;

-- Service role only (invite-send-email, after Resend accepted the message).
create or replace function public.record_invite_email_sent(p_invite_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform set_config('app.invite_send_record', 'on', true);
  update public.invites
     set last_sent_at = now(), send_count = send_count + 1
   where id = p_invite_id;
  perform set_config('app.invite_send_record', 'off', true);
end;
$$;

-- -----------------------------------------------------------------------------
-- Invitee side.
-- -----------------------------------------------------------------------------
drop function if exists public.my_pending_invites();
create function public.my_pending_invites()
returns table (
  invite_id uuid,
  organization_id uuid,
  organization_name text,
  venue_id uuid,
  venue_name text,
  role public.app_role,
  invited_at timestamptz,
  invited_by_name text,
  expires_at timestamptz
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
    select i.id, i.organization_id, o.name, i.venue_id, v.name, i.role, i.created_at,
           nullif(trim(p.display_name), ''), i.expires_at
    from public.invites i
    join public.organizations o on o.id = i.organization_id
    left join public.venues v on v.id = i.venue_id
    left join public.profiles p on p.id = i.invited_by
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

  -- The name the manager typed becomes the member's display name, unless they already chose
  -- one themselves.
  if v_invite.full_name is not null then
    update public.profiles
       set display_name = v_invite.full_name
     where id = auth.uid() and coalesce(trim(display_name), '') = '';
  end if;

  perform app_hidden.audit_event(
    v_invite.organization_id, v_invite.venue_id, 'invite.accept', 'invites', v_invite.id,
    jsonb_build_object('role', v_invite.role)
  );
end;
$$;

revoke all on function public.create_invite(uuid, text, public.app_role, text) from public, anon;
revoke all on function public.resend_invite(uuid) from public, anon;
revoke all on function public.record_invite_email_sent(uuid) from public, anon, authenticated;
revoke all on function public.my_pending_invites() from public, anon;
revoke all on function public.accept_invite(uuid) from public, anon;
grant execute on function public.create_invite(uuid, text, public.app_role, text) to authenticated;
grant execute on function public.resend_invite(uuid) to authenticated;
grant execute on function public.record_invite_email_sent(uuid) to service_role;
grant execute on function public.my_pending_invites() to authenticated;
grant execute on function public.accept_invite(uuid) to authenticated;

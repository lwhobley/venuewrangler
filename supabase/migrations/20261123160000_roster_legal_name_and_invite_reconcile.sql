-- Low-severity cleanup:
-- 1) staff_display_name must not fall back to HR legal_name (PII) for member-facing rosters.
-- 2) prepare_staff_invite must reconcile role/display_name when reusing a pending invite.

create or replace function app_hidden.staff_display_name(p_venue uuid, p_user uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  -- Preferred / profile display only. legal_name stays behind employee_hr_profiles RLS;
  -- managers read it via HR screens, not the schedule roster shared with all members.
  select coalesce(
    nullif(trim(h.preferred_name), ''),
    nullif(trim(p.display_name), '')
  )
  from public.profiles p
  left join public.employee_hr_profiles h
    on h.user_id = p.id and h.venue_id = p_venue
  where p.id = p_user;
$$;

revoke all on function app_hidden.staff_display_name(uuid, uuid) from public, anon, authenticated;

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
    -- pending row matches what they just submitted (not a stale staff invite).
    if v_invite.role is distinct from p_role
      or v_invite.display_name is distinct from v_display
    then
      update public.invites
      set role = p_role,
          display_name = v_display
      where id = v_invite.id
      returning * into v_invite;
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

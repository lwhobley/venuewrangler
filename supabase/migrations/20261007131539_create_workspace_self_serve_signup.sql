-- Self-serve workspace creation for a brand-new, already-authenticated user (the Flutter
-- app's sign-up screen, reached from the marketing site's "Launch Workspace" CTA). Until now
-- the only way to get a membership was the invite-redemption trigger
-- (app_hidden.handle_new_user) — there was no path for someone starting their own org from
-- scratch: organizations/memberships have no INSERT policy at all, and venues_insert_org_admins
-- requires already holding an org role for that org, which a fresh signup can never have. This
-- function is the deliberate, audited bypass: SECURITY DEFINER, callable by any authenticated
-- user, and it only ever creates a brand-new organization + venue + an organization_owner
-- membership for the caller — it can't be used to join or modify anything that already exists.
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
  v_org_id uuid;
  v_venue_id uuid;
begin
  if v_uid is null then
    raise exception 'Must be signed in to create a workspace' using errcode = '42501';
  end if;

  if char_length(v_org_name) = 0 or char_length(v_org_name) > 120 then
    raise exception 'Organization name must be 1-120 characters' using errcode = '22023';
  end if;
  if char_length(v_venue_name) = 0 or char_length(v_venue_name) > 120 then
    raise exception 'Venue name must be 1-120 characters' using errcode = '22023';
  end if;

  insert into public.organizations (name, created_by)
  values (v_org_name, v_uid)
  returning id into v_org_id;

  insert into public.venues (organization_id, name, created_by, timezone)
  values (v_org_id, v_venue_name, v_uid, coalesce(nullif(trim(p_timezone), ''), 'UTC'))
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

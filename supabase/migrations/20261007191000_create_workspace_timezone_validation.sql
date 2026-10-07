-- create_workspace accepted any text as the venue time zone, so a bad value (or a typo from a
-- direct RPC call) was stored and then broke the server-side time clock, which reads
-- venues.timezone. Reject anything pg_timezone_names doesn't know, with the same 22023 the
-- other argument checks use. Everything else is unchanged from the original definition.
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

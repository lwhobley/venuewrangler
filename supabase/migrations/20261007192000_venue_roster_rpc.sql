-- The Flutter roster read embedded profiles from memberships (`profiles(display_name)`), but
-- memberships has no foreign key to profiles (both reference auth.users), so PostgREST could not
-- resolve the embed; and the memberships SELECT policy only lets a user see their own row or,
-- for org owners/admins, every row in the org, so a venue manager saw at most themselves.
-- This SECURITY DEFINER read is the one deliberate path: it returns the venue-level members of
-- a venue (user id, role, display name) and nothing else, to people who manage that venue.
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
       array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
     ) then
    raise exception 'Not allowed to view this venue roster' using errcode = '42501';
  end if;

  return query
    select m.user_id, m.role, p.display_name
    from public.memberships m
    left join public.profiles p on p.id = m.user_id
    where m.venue_id = p_venue_id
    order by p.display_name nulls last, m.user_id;
end;
$$;

revoke all on function public.venue_roster(uuid) from public, anon;
grant execute on function public.venue_roster(uuid) to authenticated;

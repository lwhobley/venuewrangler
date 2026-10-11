-- Team Chat: one shared "All Staff" channel per venue, a contact list any venue member can
-- read to start a direct message, and a direct message only with someone in the venue.

-- -----------------------------------------------------------------------------
-- 1. One All Staff channel per venue, created with the venue and backfilled
-- -----------------------------------------------------------------------------
create unique index if not exists conversations_one_all_staff_per_venue_idx
  on public.conversations (venue_id)
  where type = 'all_staff';

-- Runs as the function owner, which bypasses RLS: create_workspace inserts the venue before
-- the owner's membership exists, so the caller could not pass conversations_insert yet.
create or replace function app_hidden.create_all_staff_conversation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.conversations (organization_id, venue_id, type, name, is_system)
  values (new.organization_id, new.id, 'all_staff', 'All Staff', true)
  on conflict (venue_id) where type = 'all_staff' do nothing;
  return new;
end;
$$;

revoke all on function app_hidden.create_all_staff_conversation() from public, anon, authenticated;

drop trigger if exists trg_venues_all_staff_conversation on public.venues;
create trigger trg_venues_all_staff_conversation
  after insert on public.venues
  for each row execute function app_hidden.create_all_staff_conversation();

insert into public.conversations (organization_id, venue_id, type, name, is_system)
select v.organization_id, v.id, 'all_staff', 'All Staff', true
from public.venues v
on conflict (venue_id) where type = 'all_staff' do nothing;

-- -----------------------------------------------------------------------------
-- 2. chat_contacts: everyone a venue member may message (names only, never roles).
-- venue_roster stays manager-only; this exposes just enough to pick a person.
-- -----------------------------------------------------------------------------
create or replace function public.chat_contacts(p_venue_id uuid)
returns table (user_id uuid, display_name text)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null
     or not app_hidden.has_venue_role(
       p_venue_id,
       array['staff', 'supervisor', 'venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
     ) then
    raise exception 'Not allowed to view this venue''s team' using errcode = '42501';
  end if;

  -- Venue-level members plus the organization's owners/admins, one row per person, minus
  -- the caller.
  return query
    select r.user_id, r.display_name
    from (
      select distinct on (m.user_id) m.user_id, p.display_name
      from public.memberships m
      join public.venues v on v.id = p_venue_id
      left join public.profiles p on p.id = m.user_id
      where (
          m.venue_id = p_venue_id
          or (m.venue_id is null and m.organization_id = v.organization_id
              and m.role in ('organization_owner', 'organization_admin'))
        )
        and m.user_id <> auth.uid()
      order by m.user_id
    ) r
    order by r.display_name nulls last, r.user_id;
end;
$$;

revoke all on function public.chat_contacts(uuid) from public, anon;
grant execute on function public.chat_contacts(uuid) to authenticated;

-- -----------------------------------------------------------------------------
-- 3. create_or_get_dm: the other person must belong to the venue (venue-level membership
-- or an org-level owner/admin of its organization), the same people chat_contacts lists.
-- -----------------------------------------------------------------------------
create or replace function public.create_or_get_dm(
  p_venue_id uuid,
  p_target_user_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_caller_id uuid := auth.uid();
  v_conv_id uuid;
  v_org_id uuid;
begin
  if v_caller_id is null then
    raise exception 'unauthorized' using errcode = '42501';
  end if;

  if not app_hidden.has_venue_role(
    p_venue_id,
    array['staff', 'supervisor', 'venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
  ) then
    raise exception 'forbidden: caller is not a member of this venue' using errcode = '42501';
  end if;

  if p_target_user_id is null or p_target_user_id = v_caller_id then
    raise exception 'a direct message needs a different user' using errcode = '22023';
  end if;

  select organization_id into v_org_id from public.venues where id = p_venue_id;

  if not exists (
    select 1
    from public.memberships m
    where m.user_id = p_target_user_id
      and (
        m.venue_id = p_venue_id
        or (m.venue_id is null and m.organization_id = v_org_id
            and m.role in ('organization_owner', 'organization_admin'))
      )
  ) then
    raise exception 'that person is not part of this venue' using errcode = '22023';
  end if;

  -- Serialize concurrent first-contact calls for the same pair so only one DM is created.
  perform pg_advisory_xact_lock(hashtextextended(
    'dm:' || least(v_caller_id, p_target_user_id)::text || ':' || greatest(v_caller_id, p_target_user_id)::text,
    0
  ));

  -- Look for existing 2-person DM conversation containing both users
  select c.id into v_conv_id
  from public.conversations c
  join public.conversation_members m1 on m1.conversation_id = c.id and m1.user_id = v_caller_id
  join public.conversation_members m2 on m2.conversation_id = c.id and m2.user_id = p_target_user_id
  where c.venue_id = p_venue_id
    and c.type = 'dm'
  limit 1;

  if v_conv_id is not null then
    return v_conv_id;
  end if;

  -- Create new DM conversation
  insert into public.conversations (venue_id, organization_id, type)
  values (p_venue_id, v_org_id, 'dm')
  returning id into v_conv_id;

  -- Add both members
  insert into public.conversation_members (conversation_id, user_id, venue_id, organization_id)
  values
    (v_conv_id, v_caller_id, p_venue_id, v_org_id),
    (v_conv_id, p_target_user_id, p_venue_id, v_org_id);

  return v_conv_id;
end;
$$;

revoke execute on function public.create_or_get_dm(uuid, uuid) from public, anon;
grant execute on function public.create_or_get_dm(uuid, uuid) to authenticated;

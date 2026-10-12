-- Review fixes, part 3: All Staff read state, schedule roster membership, push token takeover,
-- and legacy chat attachment reads. Redefinitions are written out in full and keep the signature,
-- language, SECURITY DEFINER and `set search_path = ''` of the last definition they replace.

-- -----------------------------------------------------------------------------
-- 4. Read state for the All Staff channel.
-- conversation_reads_write (20261012100000) required conversation_members, but All Staff has none
-- (every venue member reads it by role), so marking it read failed. The write check now also
-- accepts an all_staff conversation in a venue where the caller has a staff-or-above role.
-- The membership path is kept, and the derive trigger is unchanged.
-- -----------------------------------------------------------------------------
drop policy if exists conversation_reads_write on public.conversation_reads;
create policy conversation_reads_write on public.conversation_reads
  for all to authenticated
  using (user_id = auth.uid())
  with check (
    user_id = auth.uid()
    and (
      app_hidden.is_conversation_member(conversation_id, auth.uid())
      or exists (
        select 1
        from public.conversations c
        where c.id = conversation_id
          and c.type = 'all_staff'
          and app_hidden.has_venue_role(
            c.venue_id,
            array['staff', 'supervisor', 'venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
          )
      )
    )
  );

-- -----------------------------------------------------------------------------
-- 5. Schedule roster includes the organization's owners and admins.
-- venue_schedule_roster (20261007202000) selected only venue-level rows, so an org owner who
-- manages the venue through an org-level membership was missing from scheduling. It now uses
-- venue_roster's membership rule (venue-level rows plus org-level owner/admin rows for the
-- venue's organization), keeps its existing auth check, and returns the same columns.
-- -----------------------------------------------------------------------------
create or replace function public.venue_schedule_roster(p_venue_id uuid)
returns table (user_id uuid, role public.app_role, display_name text)
language plpgsql stable security definer set search_path = '' as $$
begin
  if auth.uid() is null or not app_hidden.is_venue_member(p_venue_id) then
    raise exception 'Not allowed to view this schedule roster' using errcode = '42501';
  end if;

  -- Same rule as venue_roster: venue-level members, plus org-level owners/admins of the
  -- venue's organization. One row per person, venue role first.
  return query
    select r.user_id, r.role, r.display_name
    from (
      select distinct on (m.user_id) m.user_id, m.role, p.display_name
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

revoke all on function public.venue_schedule_roster(uuid) from public, anon;
grant execute on function public.venue_schedule_roster(uuid) to authenticated;

-- -----------------------------------------------------------------------------
-- 6. Push token takeover is limited.
-- register_push_token (20261007202000) let any venue member who presented a token take over its
-- registration from another person, so a member could receive another's notifications. Now a
-- token may move to the caller only when:
--   * the existing row is disabled (its owner signed out or the token was unregistered), or
--   * the caller is a member of the venue (already required) and the current owner no longer
--     has any membership in the organization.
-- Otherwise the call raises 42501. Trade-off: a shared device whose previous user signed out
-- offline (so the row is still enabled) cannot be re-registered by the next user until the old
-- owner's membership ends. The reverted section 9 of 20261012100000 was the earlier option.
-- -----------------------------------------------------------------------------
create or replace function public.register_push_token(
  p_venue_id uuid, p_token text, p_platform text
) returns uuid language plpgsql security definer set search_path = '' as $$
declare
  v_org_id uuid;
  v_user_id uuid := auth.uid();
  v_id uuid;
  v_owner_id uuid;
  v_owner_enabled boolean;
begin
  if v_user_id is null or not app_hidden.is_venue_member(p_venue_id) then
    raise exception 'User is not a member of this venue' using errcode = '42501';
  end if;
  select organization_id into v_org_id from public.venues where id = p_venue_id;
  perform pg_advisory_xact_lock(hashtext('push-token:' || p_venue_id::text || ':' || p_token));

  select pt.user_id, pt.enabled into v_owner_id, v_owner_enabled
  from public.push_tokens pt
  where pt.venue_id = p_venue_id and pt.token = p_token;

  if found and v_owner_id <> v_user_id and v_owner_enabled
     and exists (
       select 1 from public.memberships m
       where m.user_id = v_owner_id and m.organization_id = v_org_id
     ) then
    raise exception 'this device token is registered to another active team member'
      using errcode = '42501';
  end if;

  -- Ownership moves to the caller only under the rules above.
  insert into public.push_tokens (
    organization_id, venue_id, user_id, token, platform, enabled, last_seen_at,
    disabled_at, updated_at
  ) values (
    v_org_id, p_venue_id, v_user_id, p_token, p_platform, true, now(), null, now()
  ) on conflict (venue_id, token) do update
    set user_id = excluded.user_id, enabled = true, disabled_at = null,
        platform = excluded.platform, last_seen_at = now(), updated_at = now()
  returning id into v_id;
  return v_id;
end;
$$;

-- -----------------------------------------------------------------------------
-- 9. Legacy 3-segment chat attachments are readable only by conversation members.
-- chat_select_conversation_members (20261005115202) let any venue staff member read a 3-segment
-- object (the pre-scoping layout), so a DM attachment was readable venue-wide. The app builds
-- only 4-segment paths ({org}/{venue}/{conversation_id}/{file}; see the insert policy), so the
-- 4-segment branch is unchanged. A 3-segment object is now readable only when its third segment
-- is a conversation id the caller is a member of. Anything without a conversation id is not
-- readable through this policy.
-- -----------------------------------------------------------------------------
-- The venue of a conversation is read by a definer helper, so the storage policy's venue check
-- does not depend on the caller's own RLS visibility of public.conversations.
create or replace function app_hidden.conversation_venue_id(p_conv_id uuid)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select c.venue_id from public.conversations c where c.id = p_conv_id;
$$;

drop policy if exists "chat_select_conversation_members" on storage.objects;
create policy "chat_select_conversation_members" on storage.objects
  for select to authenticated
  using (
    bucket_id = 'chat'
    and (
      (
        array_length(string_to_array(name, '/'), 1) = 4
        and (
          app_hidden.is_conversation_member(app_hidden.storage_path_conversation_id(name))
          or exists (
            select 1 from public.conversations c
            where c.id = app_hidden.storage_path_conversation_id(name)
              and c.type = 'all_staff'
              and app_hidden.has_venue_role(
                c.venue_id,
                array['staff', 'supervisor', 'venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
              )
          )
        )
        -- Path venue must match the conversation's actual venue (no cross-venue aliasing).
        and (
          app_hidden.storage_path_venue_id(name)
            = app_hidden.conversation_venue_id(app_hidden.storage_path_conversation_id(name))
        )
      )
      or (
        array_length(string_to_array(name, '/'), 1) = 3
        and app_hidden.is_conversation_member(app_hidden.storage_path_conversation_id(name))
      )
    )
  );

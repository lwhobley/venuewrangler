-- Fix HIGH: chat storage DM leak — scope objects by conversation, not venue.
-- Old path: {org}/{venue}/{file} with venue-role select policy (any venue member
-- could list/download DM attachments).
-- New path: {org}/{venue}/{conversation_id}/{file}. Select/insert require
-- conversation membership (or all_staff venue membership).
-- Legacy 3-segment objects remain readable via venue role so existing files don't
-- break; new inserts must use the 4-segment form. Migrate/delete legacy objects
-- separately.

create or replace function app_hidden.storage_path_conversation_id(object_name text)
returns uuid
language plpgsql
immutable
security definer
set search_path = public
as $$
begin
  return app_hidden.try_cast_uuid((string_to_array(object_name, '/'))[3]);
end;
$$;

-- Allow the 4-segment chat form in the deletion worker safety gate.
-- Other buckets keep the old 2-or-3-segment rule.
create or replace function app_hidden.is_safe_storage_deletion_path(
  p_bucket_id text,
  p_object_path text
) returns boolean
language plpgsql
immutable
set search_path = public
as $$
begin
  if p_bucket_id not in ('incident-evidence', 'checklist-evidence', 'staff-documents', 'exports', 'temp-imports', 'chat') then
    return false;
  end if;

  if p_object_path like '%..%' or p_object_path like '/%' or p_object_path like '%//%' then
    return false;
  end if;

  if p_bucket_id = 'chat' then
    if p_object_path ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[a-zA-Z0-9_\-\.]+$' then
      return true;
    end if;
    -- Legacy 3-segment chat objects (pre-scoping) still deletable.
    if p_object_path ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/)?[a-zA-Z0-9_\-\.]+$' then
      return true;
    end if;
    return false;
  end if;

  if not (p_object_path ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/)?[a-zA-Z0-9_\-\.]+$') then
    return false;
  end if;

  return true;
end;
$$;

-- Replace venue-wide chat policies with conversation-scoped ones.
drop policy if exists "chat_select_venue_members" on storage.objects;
drop policy if exists "chat_insert_venue_members" on storage.objects;

-- SELECT: 4-segment objects require conversation membership (or all_staff venue
-- membership). Legacy 3-segment objects fall back to venue membership.
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
          app_hidden.storage_path_venue_id(name) = (
            select c.venue_id from public.conversations c
            where c.id = app_hidden.storage_path_conversation_id(name)
          )
        )
      )
      or (
        array_length(string_to_array(name, '/'), 1) <= 3
        and app_hidden.has_venue_role(
          app_hidden.storage_path_venue_id(name),
          array['staff', 'supervisor', 'venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
        )
      )
    )
  );

-- INSERT: new uploads must use the 4-segment conversation form and the caller must
-- belong to that conversation (or the venue for all_staff).
create policy "chat_insert_conversation_members" on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'chat'
    and array_length(string_to_array(name, '/'), 1) = 4
    and name ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[a-zA-Z0-9_\-\.]+$'
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
    and (
      app_hidden.storage_path_venue_id(name) = (
        select c.venue_id from public.conversations c
        where c.id = app_hidden.storage_path_conversation_id(name)
      )
    )
  );

-- H1 / M3 / M4 (code-review 2026-11-23):
--   H1  incident_attachments + incident-evidence INSERT must require can_read_incident
--       (reporter or supervisor+), not bare is_venue_member.
--   M3  incident-evidence SELECT must authorize via incident identity (reporter), not
--       Storage owner alone.
--   M4  evidence / checklist storage paths must bind the org path segment to the venue
--       (same org↔venue check as profile-photos).
--
-- New incident-evidence path: {organization_id}/{venue_id}/{incident_id}/{filename}
-- Legacy 3-segment objects remain readable when linked from incident_attachments.

-- ---------------------------------------------------------------------------
-- Path helpers
-- ---------------------------------------------------------------------------

create or replace function app_hidden.storage_path_organization_id(object_name text)
returns uuid
language plpgsql
immutable
security definer
set search_path = ''
as $$
begin
  return app_hidden.try_cast_uuid((string_to_array(object_name, '/'))[1]);
end;
$$;

create or replace function app_hidden.storage_path_incident_id(object_name text)
returns uuid
language plpgsql
immutable
security definer
set search_path = ''
as $$
begin
  -- New convention only: segment [3] is the incident id when the path has 4+ parts.
  if coalesce(array_length(string_to_array(object_name, '/'), 1), 0) < 4 then
    return null;
  end if;
  return app_hidden.try_cast_uuid((string_to_array(object_name, '/'))[3]);
end;
$$;

-- True when path org/venue UUIDs parse and venues.organization_id matches the org segment.
create or replace function app_hidden.storage_path_org_matches_venue(object_name text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
      from public.venues v
     where v.id = app_hidden.storage_path_venue_id(object_name)
       and v.organization_id = app_hidden.storage_path_organization_id(object_name)
  );
$$;

revoke all on function app_hidden.storage_path_organization_id(text) from public, anon;
revoke all on function app_hidden.storage_path_incident_id(text) from public, anon;
revoke all on function app_hidden.storage_path_org_matches_venue(text) from public, anon;
grant execute on function app_hidden.storage_path_organization_id(text) to authenticated;
grant execute on function app_hidden.storage_path_incident_id(text) to authenticated;
grant execute on function app_hidden.storage_path_org_matches_venue(text) to authenticated;

-- ---------------------------------------------------------------------------
-- Incident-evidence access (SELECT / INSERT) keyed off incident identity
-- ---------------------------------------------------------------------------

-- SELECT: org↔venue bound; new paths join incidents by path incident_id; legacy
-- 3-segment paths join via incident_attachments.storage_path (never Storage owner).
create or replace function app_hidden.can_access_incident_evidence(p_path text)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  parts text[];
  v_org uuid;
  v_venue uuid;
  v_incident uuid;
  v_reporter uuid;
  v_incident_venue uuid;
  v_incident_org uuid;
begin
  parts := string_to_array(p_path, '/');
  v_org := app_hidden.try_cast_uuid(parts[1]);
  v_venue := app_hidden.try_cast_uuid(parts[2]);
  if v_org is null or v_venue is null then
    return false;
  end if;
  if not exists (
    select 1 from public.venues v
     where v.id = v_venue and v.organization_id = v_org
  ) then
    return false;
  end if;

  if coalesce(array_length(parts, 1), 0) >= 4 then
    v_incident := app_hidden.try_cast_uuid(parts[3]);
    if v_incident is null then
      return false;
    end if;
    select i.reported_by, i.venue_id, i.organization_id
      into v_reporter, v_incident_venue, v_incident_org
      from public.incidents i
     where i.id = v_incident;
    if not found then
      return false;
    end if;
    if v_incident_venue is distinct from v_venue
       or v_incident_org is distinct from v_org then
      return false;
    end if;
    return app_hidden.can_read_incident(v_incident_venue, v_reporter);
  end if;

  -- Legacy {org}/{venue}/{filename}: only if an attachment row links the object to an
  -- incident the caller can read.
  return exists (
    select 1
      from public.incident_attachments a
      join public.incidents i on i.id = a.incident_id
     where a.storage_path = p_path
       and app_hidden.can_read_incident(i.venue_id, i.reported_by)
  );
end;
$$;

-- INSERT: new uploads must use the 4-segment form and can_read_incident on that incident.
create or replace function app_hidden.can_upload_incident_evidence(p_path text)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  parts text[];
  v_org uuid;
  v_venue uuid;
  v_incident uuid;
  v_reporter uuid;
  v_incident_venue uuid;
  v_incident_org uuid;
begin
  parts := string_to_array(p_path, '/');
  if coalesce(array_length(parts, 1), 0) <> 4 then
    return false;
  end if;

  v_org := app_hidden.try_cast_uuid(parts[1]);
  v_venue := app_hidden.try_cast_uuid(parts[2]);
  v_incident := app_hidden.try_cast_uuid(parts[3]);
  if v_org is null or v_venue is null or v_incident is null then
    return false;
  end if;
  if not exists (
    select 1 from public.venues v
     where v.id = v_venue and v.organization_id = v_org
  ) then
    return false;
  end if;

  select i.reported_by, i.venue_id, i.organization_id
    into v_reporter, v_incident_venue, v_incident_org
    from public.incidents i
   where i.id = v_incident;
  if not found then
    return false;
  end if;
  if v_incident_venue is distinct from v_venue
     or v_incident_org is distinct from v_org then
    return false;
  end if;

  return app_hidden.can_read_incident(v_incident_venue, v_reporter);
end;
$$;

revoke all on function app_hidden.can_access_incident_evidence(text) from public, anon;
revoke all on function app_hidden.can_upload_incident_evidence(text) from public, anon;
grant execute on function app_hidden.can_access_incident_evidence(text) to authenticated;
grant execute on function app_hidden.can_upload_incident_evidence(text) to authenticated;

-- ---------------------------------------------------------------------------
-- Deletion-worker path allowlist: 4-segment incident-evidence objects
-- ---------------------------------------------------------------------------

create or replace function app_hidden.is_safe_storage_deletion_path(
  p_bucket_id text,
  p_object_path text
) returns boolean
language plpgsql
immutable
set search_path = public
as $$
begin
  if p_bucket_id not in (
    'incident-evidence', 'checklist-evidence', 'staff-documents',
    'exports', 'temp-imports', 'chat', 'profile-photos'
  ) then
    return false;
  end if;

  if p_object_path ~ '(^|/)[.][.](/|$)' or p_object_path like '/%' or p_object_path like '%//%' then
    return false;
  end if;

  if p_bucket_id = 'chat' then
    if p_object_path ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[a-zA-Z0-9_\-\.]+$' then
      return true;
    end if;
    if p_object_path ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/)?[a-zA-Z0-9_\-\.]+$' then
      return true;
    end if;
    return false;
  end if;

  -- Incident evidence: prefer {org}/{venue}/{incident}/{file}; keep legacy 2/3-segment.
  if p_bucket_id = 'incident-evidence' then
    if p_object_path ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[a-zA-Z0-9_\-\.]+$' then
      return true;
    end if;
  end if;

  if not (p_object_path ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/)?[a-zA-Z0-9_\-\.]+$') then
    return false;
  end if;

  return true;
end;
$$;

-- ---------------------------------------------------------------------------
-- Attachment insert trigger: require incident id in the storage path
-- ---------------------------------------------------------------------------

create or replace function app_hidden.prepare_incident_attachment_insert()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org_id uuid;
  v_venue_id uuid;
  v_expected_prefix text;
begin
  select organization_id, venue_id into v_org_id, v_venue_id
    from public.incidents
   where id = new.incident_id;

  if v_org_id is null then
    raise exception 'incident % does not exist', new.incident_id;
  end if;

  -- {organization_id}/{venue_id}/{incident_id}/...
  v_expected_prefix :=
    v_org_id::text || '/' || v_venue_id::text || '/' || new.incident_id::text || '/';
  if left(new.storage_path, length(v_expected_prefix)) <> v_expected_prefix then
    raise exception 'storage_path must be under %', v_expected_prefix;
  end if;

  new.organization_id := v_org_id;
  new.venue_id := v_venue_id;
  new.uploaded_by := auth.uid();
  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- Table RLS: incident_attachments INSERT aligned with can_read_incident (H1)
-- ---------------------------------------------------------------------------

drop policy if exists incident_attachments_insert_venue_members on public.incident_attachments;
create policy incident_attachments_insert_readable_incidents on public.incident_attachments
  for insert to authenticated
  with check (
    exists (
      select 1
        from public.incidents i
       where i.id = incident_id
         and app_hidden.can_read_incident(i.venue_id, i.reported_by)
    )
  );

-- ---------------------------------------------------------------------------
-- Storage RLS: incident-evidence (H1 insert, M3 select, M4 org bind)
-- ---------------------------------------------------------------------------

drop policy if exists "incident-evidence_select_uploader_or_supervisors" on storage.objects;
drop policy if exists "incident-evidence_select_venue_members" on storage.objects;
create policy "incident-evidence_select_readable_incidents" on storage.objects
  for select to authenticated
  using (
    bucket_id = 'incident-evidence'
    and app_hidden.can_access_incident_evidence(name)
  );

drop policy if exists "incident-evidence_insert_venue_members" on storage.objects;
create policy "incident-evidence_insert_readable_incidents" on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'incident-evidence'
    and app_hidden.can_upload_incident_evidence(name)
  );

drop policy if exists "incident-evidence_delete_managers" on storage.objects;
create policy "incident-evidence_delete_managers" on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'incident-evidence'
    and app_hidden.storage_path_org_matches_venue(name)
    and app_hidden.has_venue_role(
      app_hidden.storage_path_venue_id(name),
      array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
    )
  );

-- ---------------------------------------------------------------------------
-- Storage RLS: checklist-evidence org↔venue binding (M4)
-- ---------------------------------------------------------------------------

drop policy if exists "checklist-evidence_select_venue_members" on storage.objects;
create policy "checklist-evidence_select_venue_members" on storage.objects
  for select to authenticated
  using (
    bucket_id = 'checklist-evidence'
    and app_hidden.storage_path_org_matches_venue(name)
    and app_hidden.is_venue_member(app_hidden.storage_path_venue_id(name))
  );

drop policy if exists "checklist-evidence_insert_venue_members" on storage.objects;
create policy "checklist-evidence_insert_venue_members" on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'checklist-evidence'
    and app_hidden.storage_path_org_matches_venue(name)
    and app_hidden.is_venue_member(app_hidden.storage_path_venue_id(name))
  );

drop policy if exists "checklist-evidence_delete_managers" on storage.objects;
create policy "checklist-evidence_delete_managers" on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'checklist-evidence'
    and app_hidden.storage_path_org_matches_venue(name)
    and app_hidden.has_venue_role(
      app_hidden.storage_path_venue_id(name),
      array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
    )
  );

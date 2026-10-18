-- Least-privilege reads (audit P-06). Every venue member could read every incident report
-- (injuries, harassment, accident narratives), every evidence photo and every POS check.
--
--   incidents / attachments / evidence photos  readable by the reporter (or uploader) and by
--                                              supervisors, venue managers and org owners/admins
--   pos_checks                                 supervisors and above (staff have no screen that
--                                              needs revenue, tips or guest names per check)
--
-- Guests, reservations and CRM stay readable by venue staff on purpose: hosts and servers need
-- guest names, allergies and contact details to run service. Splitting those fields by job
-- (host vs server) needs finer-grained roles than the five that exist today.
create or replace function app_hidden.can_read_incident(p_venue uuid, p_reporter uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select p_reporter is not distinct from (select auth.uid())
     or app_hidden.has_venue_role(
          p_venue,
          array['supervisor', 'venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
        );
$$;

-- Used inside RLS policies: authenticated needs EXECUTE explicitly (see default-privilege note in
-- 20261017100000_audit_member_lifecycle_and_integrity.sql).
revoke all on function app_hidden.can_read_incident(uuid, uuid) from public, anon;
grant execute on function app_hidden.can_read_incident(uuid, uuid) to authenticated;

drop policy if exists incidents_select_venue_members on public.incidents;
create policy incidents_select_reporter_or_supervisors on public.incidents
  for select to authenticated
  using (app_hidden.can_read_incident(venue_id, reported_by));

drop policy if exists incident_attachments_select_venue_members on public.incident_attachments;
create policy incident_attachments_select_reporter_or_supervisors on public.incident_attachments
  for select to authenticated
  -- The uploader, or anyone who can see the incident itself (the subquery is filtered by the
  -- incidents policy above, so a reporter also sees photos a supervisor added to their report).
  using (
    uploaded_by is not distinct from (select auth.uid())
    or exists (select 1 from public.incidents i where i.id = incident_id)
  );

drop policy if exists "incident-evidence_select_venue_members" on storage.objects;
create policy "incident-evidence_select_uploader_or_supervisors" on storage.objects
  for select to authenticated
  using (
    bucket_id = 'incident-evidence'
    and app_hidden.can_read_incident(app_hidden.storage_path_venue_id(name), owner)
  );

drop policy if exists pos_checks_select_members on public.pos_checks;
create policy pos_checks_select_supervisors on public.pos_checks
  for select to authenticated
  using (app_hidden.has_venue_role(
    venue_id,
    array['supervisor', 'venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
  ));

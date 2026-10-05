-- Phase 3: incident evidence attachments. Per the hard requirement to "store object metadata
-- in Postgres" rather than leaving Storage objects with no database linkage, this table
-- connects an incident to the evidence object(s) uploaded for it. The actual bytes live in
-- the `incident-evidence` Storage bucket (supabase/migrations/20261002040000); this table
-- only ever stores the object's path, never the file itself.

create table public.incident_attachments (
  id uuid primary key default gen_random_uuid(),
  incident_id uuid not null references public.incidents (id) on delete cascade,
  organization_id uuid not null references public.organizations (id) on delete cascade,
  venue_id uuid not null references public.venues (id) on delete cascade,
  -- Must match the `{organization_id}/{venue_id}/{filename}` path convention the
  -- incident-evidence bucket's Storage policies enforce — validated below, not just assumed.
  storage_path text not null,
  uploaded_by uuid references auth.users (id),
  created_at timestamptz not null default now()
);

create index incident_attachments_incident_id_idx on public.incident_attachments (incident_id);
create index incident_attachments_venue_id_idx on public.incident_attachments (venue_id);

-- organization_id/venue_id/uploaded_by are derived from incident_id, never client-supplied —
-- same reasoning as checklist_completions' prepare_checklist_completion_insert. Also
-- validates that storage_path actually starts with this incident's own
-- {organization_id}/{venue_id}/ prefix, so a row can't be created pointing at someone else's
-- evidence object even if the insert's venue_id/organization_id are (correctly) derived from
-- a venue the caller belongs to.
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

  v_expected_prefix := v_org_id::text || '/' || v_venue_id::text || '/';
  if left(new.storage_path, length(v_expected_prefix)) <> v_expected_prefix then
    raise exception 'storage_path must be under %', v_expected_prefix;
  end if;

  new.organization_id := v_org_id;
  new.venue_id := v_venue_id;
  new.uploaded_by := auth.uid();
  return new;
end;
$$;

create trigger prepare_incident_attachment_insert
  before insert on public.incident_attachments
  for each row execute function app_hidden.prepare_incident_attachment_insert();

alter table public.incident_attachments enable row level security;
alter table public.incident_attachments force row level security;

create policy incident_attachments_select_venue_members on public.incident_attachments
  for select to authenticated
  using (app_hidden.is_venue_member(venue_id));

-- Symmetric with the incident-evidence Storage bucket's own insert policy: any venue member
-- may attach evidence (the same people who may report the incident in the first place).
create policy incident_attachments_insert_venue_members on public.incident_attachments
  for insert to authenticated
  with check (app_hidden.is_venue_member(venue_id));

-- Symmetric with the Storage bucket's delete policy: only a manager may remove an
-- attachment record. No update policy — an attachment is immutable metadata; replacing
-- evidence means uploading a new object and a new attachment row, not editing one in place.
create policy incident_attachments_delete_managers on public.incident_attachments
  for delete to authenticated
  using (
    app_hidden.has_venue_role(
      venue_id,
      array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
    )
  );

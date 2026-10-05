-- Batch 3 feature: venue document library (SOPs/manuals/recipes/menus/training/forms), ported
-- from packages/api/src/modules/documents. The one piece of legacy's behavior RLS genuinely
-- cannot replicate is the hard ClamAV malware-scan requirement (legacy fails closed with 503 if
-- ClamAV isn't configured) and the magic-byte MIME validation — neither is expressible as a
-- Postgres policy, so this table has NO insert policy for `authenticated` at all. Creation is
-- only possible through the documents-upload Edge Function (service_role), which is where the
-- scan and byte-sniffing actually happen; see supabase/functions/documents-upload/index.ts.
--
-- Category visibility mirrors legacy's MANAGER_ONLY_CATEGORIES exactly: 'form' and 'other' are
-- manager-only (HR paperwork ends up there), the rest (sop/manual/recipe/menu/training) are the
-- working-floor library every staff member can read.

create table public.documents (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  venue_id uuid not null references public.venues (id) on delete cascade,
  title text not null check (char_length(trim(title)) > 0),
  file_name text not null check (char_length(trim(file_name)) > 0),
  category text not null check (category in ('sop', 'manual', 'recipe', 'menu', 'training', 'form', 'other')),
  mime_type text not null check (char_length(trim(mime_type)) > 0),
  -- Matches legacy's MAX_DOCUMENT_BYTES (10MB) exactly.
  size_bytes bigint not null check (size_bytes > 0 and size_bytes <= 10485760),
  -- Path convention: {organization_id}/{venue_id}/{category}--{random_hex}--{safe_file_name},
  -- under the existing staff-documents bucket (supabase/migrations/20261002040000). Category is
  -- folded into the filename segment (not a new path segment) specifically so this still
  -- matches app_hidden.is_safe_storage_deletion_path's existing, already-hardened regex
  -- (org-uuid/venue-uuid/filename) without touching that function at all.
  storage_path text not null,
  uploaded_by uuid references auth.users (id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index documents_venue_id_idx on public.documents (venue_id);
create index documents_organization_id_idx on public.documents (organization_id);
create index documents_venue_category_idx on public.documents (venue_id, category);

-- Derives organization_id from venue_id even though the only writer is the service-role Edge
-- Function (which could set it directly) — same "derive, don't trust" posture as every other
-- table in this codebase, so a bug in the Edge Function can't desync organization_id/venue_id.
create or replace function app_hidden.prepare_document_insert()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org_id uuid;
begin
  select organization_id into v_org_id from public.venues where id = new.venue_id;
  if v_org_id is null then
    raise exception 'venue % does not exist', new.venue_id;
  end if;
  new.organization_id := v_org_id;
  return new;
end;
$$;

create trigger prepare_document_insert
  before insert on public.documents
  for each row execute function app_hidden.prepare_document_insert();

-- Mirrors legacy's atomic "delete the row, queue the storage object for deletion" behavior
-- (the controller's $transaction + outbox job), but as a trigger instead of app-level
-- transaction code, reusing the storage_deletion_jobs worker already built for media-cleanup
-- (supabase/migrations/20261002230000) rather than inventing a second cleanup mechanism.
create or replace function app_hidden.enqueue_document_storage_deletion()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.storage_deletion_jobs (organization_id, venue_id, bucket_id, object_path)
  values (old.organization_id, old.venue_id, 'staff-documents', old.storage_path);
  return old;
end;
$$;

create trigger enqueue_document_storage_deletion
  after delete on public.documents
  for each row execute function app_hidden.enqueue_document_storage_deletion();

alter table public.documents enable row level security;
alter table public.documents force row level security;

-- Staff-readable except the two manager-only categories, exactly like legacy's `list`/`access`
-- endpoints. A non-manager querying a manager-only-category document simply gets zero rows,
-- which is the RLS equivalent of legacy's deliberate "404, not 403" (never confirm existence).
create policy documents_select_venue_members on public.documents
  for select to authenticated
  using (
    app_hidden.is_venue_member(venue_id)
    and (
      category not in ('form', 'other')
      or app_hidden.has_venue_role(
        venue_id,
        array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
      )
    )
  );

-- No insert/update policy for `authenticated`: see the header comment. No update policy either
-- — a document is immutable once scanned and stored, same as incident_attachments; replacing
-- one means uploading a new one.
create policy documents_delete_managers on public.documents
  for delete to authenticated
  using (
    app_hidden.has_venue_role(
      venue_id,
      array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
    )
  );

-- ---------------------------------------------------------------------------
-- Storage policies: the generic 'staff-documents' policies from
-- 20261002040000_storage_buckets.sql allowed any venue member to INSERT directly, which would
-- let a client skip the ClamAV scan entirely. Replace them with documents-specific policies:
-- no direct INSERT or DELETE for `authenticated` at all (service-role/Edge-Function and the
-- storage_deletion_jobs worker respectively), and a SELECT policy that also honors the
-- manager-only category split by reading it out of the filename segment.
-- ---------------------------------------------------------------------------

-- DROP POLICY on storage.objects consistently timed out via this project's SQL tooling (the
-- same class of tool flakiness noted elsewhere in this migration history, e.g.
-- process_storage_deletion_batch) — ALTER POLICY ... using/with check (false) is used instead,
-- which is functionally identical (a permanently-false policy grants nothing) and is what was
-- actually applied live. Kept as ALTER rather than DROP here so this migration reproduces the
-- live project's exact state when replayed locally, not just an equivalent one.
alter policy "staff-documents_select_venue_members" on storage.objects using (false);
alter policy "staff-documents_insert_venue_members" on storage.objects with check (false);
alter policy "staff-documents_delete_managers" on storage.objects using (false);

-- Extracts the category prefix from the filename segment of
-- {org}/{venue}/{category}--{random_hex}--{safe_file_name}. Returns null (safe default, which
-- the SELECT policy below never treats as "not manager-only") for anything malformed.
create or replace function app_hidden.storage_path_document_category(object_name text)
returns text
language plpgsql
immutable
security definer
set search_path = public
as $$
declare
  v_filename text;
  v_category text;
begin
  v_filename := (string_to_array(object_name, '/'))[3];
  if v_filename is null then
    return null;
  end if;
  v_category := split_part(v_filename, '--', 1);
  if v_category not in ('sop', 'manual', 'recipe', 'menu', 'training', 'form', 'other') then
    return null;
  end if;
  return v_category;
end;
$$;

create policy staff_documents_select_scoped on storage.objects
  for select to authenticated
  using (
    bucket_id = 'staff-documents'
    and app_hidden.is_venue_member(app_hidden.storage_path_venue_id(name))
    and (
      coalesce(app_hidden.storage_path_document_category(name), 'other') not in ('form', 'other')
      or app_hidden.has_venue_role(
        app_hidden.storage_path_venue_id(name),
        array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
      )
    )
  );

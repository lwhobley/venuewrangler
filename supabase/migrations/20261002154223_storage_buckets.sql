-- Phase 3: private Supabase Storage buckets. Per the hard requirement, nothing here is a
-- public bucket, and object access is governed by RLS-style Storage policies keyed off the
-- object path, not by convention in application code.
--
-- Path convention for every venue-scoped bucket: `{organization_id}/{venue_id}/{filename}`.
-- Policies extract and validate those two path segments rather than trusting them, the same
-- "derive, don't trust" posture used throughout the table migrations.
--
-- `storage.objects`/`storage.buckets` already exist and already have RLS enabled on a real
-- Supabase project (the platform manages that table) — this migration only inserts bucket
-- rows and adds policies, it does not ALTER TABLE ... ENABLE ROW LEVEL SECURITY on them.

insert into storage.buckets (id, name, public)
values
  ('incident-evidence', 'incident-evidence', false),
  ('checklist-evidence', 'checklist-evidence', false),
  ('staff-documents', 'staff-documents', false),
  ('exports', 'exports', false),
  ('temp-imports', 'temp-imports', false)
on conflict (id) do nothing;

-- Safe uuid cast: a malformed or missing path segment must read as "not a member of
-- anything" (false), never raise an error that would turn a bad path into a 500 instead of a
-- clean access-denied.
create or replace function app_hidden.try_cast_uuid(value text)
returns uuid
language plpgsql
immutable
as $$
begin
  return value::uuid;
exception when others then
  return null;
end;
$$;

-- SECURITY DEFINER (matching every other app_hidden helper) is required here, not optional:
-- without it this function runs as SECURITY INVOKER, i.e. with the calling role's own
-- privileges throughout its body — and `authenticated` has no USAGE on app_hidden (see the
-- REVOKE in the foundation migration), so its internal call to app_hidden.try_cast_uuid
-- would fail with "permission denied for schema app_hidden". `set search_path = public`
-- keeps the function's own unqualified-name resolution predictable.
create or replace function app_hidden.storage_path_venue_id(object_name text)
returns uuid
language plpgsql
immutable
security definer
set search_path = public
as $$
begin
  return app_hidden.try_cast_uuid((string_to_array(object_name, '/'))[2]);
end;
$$;

-- incident-evidence / checklist-evidence / staff-documents: any venue member may read or
-- upload (evidence/documents are a whole-venue-team concern, not just managers'), but only a
-- venue_manager+ may remove an object — there is deliberately no update policy, since
-- evidence is meant to be immutable once uploaded; replacing it means uploading a new object.
do $$
declare
  evidence_bucket text;
begin
  foreach evidence_bucket in array array['incident-evidence', 'checklist-evidence', 'staff-documents']
  loop
    execute format(
      $policy$
        create policy %I on storage.objects
          for select to authenticated
          using (
            bucket_id = %L
            and app_hidden.is_venue_member(app_hidden.storage_path_venue_id(name))
          );
      $policy$,
      evidence_bucket || '_select_venue_members',
      evidence_bucket
    );

    execute format(
      $policy$
        create policy %I on storage.objects
          for insert to authenticated
          with check (
            bucket_id = %L
            and app_hidden.is_venue_member(app_hidden.storage_path_venue_id(name))
          );
      $policy$,
      evidence_bucket || '_insert_venue_members',
      evidence_bucket
    );

    execute format(
      $policy$
        create policy %I on storage.objects
          for delete to authenticated
          using (
            bucket_id = %L
            and app_hidden.has_venue_role(
              app_hidden.storage_path_venue_id(name),
              array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
            )
          );
      $policy$,
      evidence_bucket || '_delete_managers',
      evidence_bucket
    );
  end loop;
end
$$;

-- exports / temp-imports: no policy at all for `authenticated`/`anon` — these buckets are
-- fully service-role-mediated (an Edge Function writes an export or reads an import, then
-- hands the client a short-lived signed URL), per the requirement to "generate short-lived
-- signed URLs for private downloads when direct policy-based access is not appropriate."
-- Nothing further to add here; the absence of a policy is the control.

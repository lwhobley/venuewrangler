-- pgTAP authorization tests for Storage policies (supabase/migrations/20261002040000). Run
-- against supabase/tests/ci_storage_stub.sql's minimal storage.buckets/storage.objects
-- stand-in — see that file and ci_auth_stub.sql for why this is needed outside a real
-- Supabase project. Reuses the same org/venue/membership roster shape as the other test
-- files.

begin;
select plan(12);

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-000000000004', 'venue-a1-manager@example.com'),
  ('00000000-0000-0000-0000-000000000005', 'venue-a1-staff@example.com');

insert into public.organizations (id, name) values
  ('10000000-0000-0000-0000-00000000000a', 'Org A'),
  ('10000000-0000-0000-0000-00000000000b', 'Org B');

insert into public.venues (id, organization_id, name) values
  ('20000000-0000-0000-0000-0000000000a1', '10000000-0000-0000-0000-00000000000a', 'Venue A1'),
  ('20000000-0000-0000-0000-0000000000b1', '10000000-0000-0000-0000-00000000000b', 'Venue B1');

insert into public.memberships (user_id, organization_id, venue_id, role) values
  ('00000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-0000000000a1', 'venue_manager'),
  ('00000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-0000000000a1', 'staff');

-- Seed one object per bucket as the table owner (bypasses RLS), matching how an Edge
-- Function / the Storage API itself would actually write these rows.
insert into storage.objects (bucket_id, name) values
  ('incident-evidence', '10000000-0000-0000-0000-00000000000a/20000000-0000-0000-0000-0000000000a1/photo1.jpg'),
  ('incident-evidence', '10000000-0000-0000-0000-00000000000b/20000000-0000-0000-0000-0000000000b1/photo2.jpg'),
  ('incident-evidence', 'not-a-valid-path.jpg'),
  ('exports', '10000000-0000-0000-0000-00000000000a/20000000-0000-0000-0000-0000000000a1/report.csv');

-- ---------------------------------------------------------------------------
-- incident-evidence: venue-scoped select/insert, manager-only delete
-- ---------------------------------------------------------------------------

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000005';

select is(
  (
    select count(*)::int from storage.objects
    where bucket_id = 'incident-evidence'
      and name = '10000000-0000-0000-0000-00000000000a/20000000-0000-0000-0000-0000000000a1/photo1.jpg'
  ),
  1,
  'a venue member can see evidence uploaded under their own venue''s path'
);

select is(
  (
    select count(*)::int from storage.objects
    where bucket_id = 'incident-evidence'
      and name = '10000000-0000-0000-0000-00000000000b/20000000-0000-0000-0000-0000000000b1/photo2.jpg'
  ),
  0,
  'a venue member cannot see evidence under a different venue''s path (cross-tenant)'
);

select is(
  (
    select count(*)::int from storage.objects
    where bucket_id = 'incident-evidence' and name = 'not-a-valid-path.jpg'
  ),
  0,
  'a malformed object path (no venue segment) safely denies access rather than erroring'
);

select lives_ok(
  $$ insert into storage.objects (bucket_id, name)
     values ('incident-evidence', '10000000-0000-0000-0000-00000000000a/20000000-0000-0000-0000-0000000000a1/photo3.jpg') $$,
  'a venue member can upload evidence under their own venue''s path'
);

select throws_ok(
  $$ insert into storage.objects (bucket_id, name)
     values ('incident-evidence', '10000000-0000-0000-0000-00000000000b/20000000-0000-0000-0000-0000000000b1/rogue.jpg') $$,
  '42501',
  null,
  'a venue member cannot upload evidence under a venue they do not belong to'
);

select lives_ok(
  $$ delete from storage.objects
     where bucket_id = 'incident-evidence'
       and name = '10000000-0000-0000-0000-00000000000a/20000000-0000-0000-0000-0000000000a1/photo1.jpg' $$,
  'a non-manager staff member''s delete attempt executes without error (no delete policy covers them)'
);

select is(
  (
    select count(*)::int from storage.objects
    where bucket_id = 'incident-evidence'
      and name = '10000000-0000-0000-0000-00000000000a/20000000-0000-0000-0000-0000000000a1/photo1.jpg'
  ),
  1,
  'the evidence object still exists afterward (staff has no delete rights)'
);

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000004';

select lives_ok(
  $$ delete from storage.objects
     where bucket_id = 'incident-evidence'
       and name = '10000000-0000-0000-0000-00000000000a/20000000-0000-0000-0000-0000000000a1/photo1.jpg' $$,
  'venue_manager can delete an evidence object in their venue'
);

-- ---------------------------------------------------------------------------
-- checklist-evidence / staff-documents: spot-check the same policy shape was applied
-- ---------------------------------------------------------------------------

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000005';

select lives_ok(
  $$ insert into storage.objects (bucket_id, name)
     values ('checklist-evidence', '10000000-0000-0000-0000-00000000000a/20000000-0000-0000-0000-0000000000a1/check1.jpg') $$,
  'a venue member can upload to checklist-evidence under their own venue''s path'
);

-- staff-documents is the documents module's bucket (supabase/migrations/20261003003000) and no
-- longer has a direct insert policy for `authenticated` at all, unlike checklist-evidence above
-- — uploads must go through the documents-upload Edge Function, since that's the only place the
-- required ClamAV scan and magic-byte MIME validation can happen; RLS has no way to verify a
-- file was scanned.
select throws_ok(
  $$ insert into storage.objects (bucket_id, name)
     values ('staff-documents', '10000000-0000-0000-0000-00000000000a/20000000-0000-0000-0000-0000000000a1/sop--aaaa--w9.pdf') $$,
  '42501',
  null,
  'a client can never upload directly into staff-documents (Edge-Function/service-role only, see documents_rls.test.sql)'
);

-- ---------------------------------------------------------------------------
-- exports: fully service-role-mediated, no client policy at all
-- ---------------------------------------------------------------------------

select is(
  (select count(*)::int from storage.objects where bucket_id = 'exports'),
  0,
  'exports is invisible to a direct client (no select policy at all, by design)'
);

select throws_ok(
  $$ insert into storage.objects (bucket_id, name)
     values ('exports', '10000000-0000-0000-0000-00000000000a/20000000-0000-0000-0000-0000000000a1/rogue-export.csv') $$,
  '42501',
  null,
  'a client can never write directly into exports (Edge-Function/service-role only)'
);

select * from finish();
rollback;

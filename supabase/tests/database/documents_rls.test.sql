-- pgTAP authorization tests for public.documents (supabase/migrations/20261003003000).
-- Reuses the same org/venue/membership roster shape as the other test files.

begin;
select plan(13);

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-000000000004', 'venue-a1-manager@example.com'),
  ('00000000-0000-0000-0000-000000000005', 'venue-a1-staff@example.com'),
  ('00000000-0000-0000-0000-000000000006', 'org-b-owner@example.com');

insert into public.organizations (id, name) values
  ('10000000-0000-0000-0000-00000000000a', 'Org A'),
  ('10000000-0000-0000-0000-00000000000b', 'Org B');

insert into public.venues (id, organization_id, name) values
  ('20000000-0000-0000-0000-0000000000a1', '10000000-0000-0000-0000-00000000000a', 'Venue A1'),
  ('20000000-0000-0000-0000-0000000000b1', '10000000-0000-0000-0000-00000000000b', 'Venue B1');

insert into public.memberships (user_id, organization_id, venue_id, role) values
  ('00000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-0000000000a1', 'venue_manager'),
  ('00000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-0000000000a1', 'staff'),
  ('00000000-0000-0000-0000-000000000006', '10000000-0000-0000-0000-00000000000b', null, 'organization_owner');

-- Seeded as table owner (bypasses RLS), the same way documents-upload's service-role client
-- would write these rows in production after a clean ClamAV scan.
insert into public.documents (id, venue_id, title, file_name, category, mime_type, size_bytes, storage_path, uploaded_by) values
  ('70000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-0000000000a1', 'Fryer SOP', 'fryer-sop.pdf', 'sop', 'application/pdf', 1024,
    '10000000-0000-0000-0000-00000000000a/20000000-0000-0000-0000-0000000000a1/sop--aaaa1111--fryer-sop.pdf',
    '00000000-0000-0000-0000-000000000004'),
  ('70000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-0000000000a1', 'W-4 Form', 'w4.pdf', 'form', 'application/pdf', 2048,
    '10000000-0000-0000-0000-00000000000a/20000000-0000-0000-0000-0000000000a1/form--bbbb2222--w4.pdf',
    '00000000-0000-0000-0000-000000000004');

-- ---------------------------------------------------------------------------
-- select: staff can see the staff-readable category but not the manager-only one
-- ---------------------------------------------------------------------------

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000005';

select is(
  (select count(*)::int from public.documents),
  1,
  'staff sees only the sop document, not the manager-only form document'
);

select is(
  (select category from public.documents limit 1),
  'sop',
  'the one document staff can see is the sop, not the form'
);

select throws_ok(
  $$ insert into public.documents (venue_id, title, file_name, category, mime_type, size_bytes, storage_path)
     values ('20000000-0000-0000-0000-0000000000a1', 'rogue', 'rogue.pdf', 'sop', 'application/pdf', 100,
       '10000000-0000-0000-0000-00000000000a/20000000-0000-0000-0000-0000000000a1/sop--rogue--rogue.pdf') $$,
  null,
  null,
  'a client can never insert a document directly (service-role/Edge-Function only, since RLS cannot verify a ClamAV scan happened)'
);

select lives_ok(
  $$ delete from public.documents where id = '70000000-0000-0000-0000-000000000001' $$,
  'a non-manager''s delete attempt executes without error (no delete policy covers them)'
);

select is(
  (select count(*)::int from public.documents where id = '70000000-0000-0000-0000-000000000001'),
  1,
  'the sop document still exists afterward (staff has no delete rights)'
);

-- ---------------------------------------------------------------------------
-- select/delete: manager can see both categories and delete
-- ---------------------------------------------------------------------------

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000004';

select is(
  (select count(*)::int from public.documents),
  2,
  'venue_manager sees both the sop and the manager-only form document'
);

select lives_ok(
  $$ delete from public.documents where id = '70000000-0000-0000-0000-000000000002' $$,
  'venue_manager can delete the form document'
);

select is(
  (select count(*)::int from public.documents where id = '70000000-0000-0000-0000-000000000002'),
  0,
  'the form document is gone after the manager''s delete'
);

-- storage_deletion_jobs revokes all access from `authenticated` (service-role/worker only — see
-- 20261002230000), so checking the enqueued row has to happen as the table owner, same as any
-- other internal worker-queue state no client role can see.
reset role;

select is(
  (select count(*)::int from public.storage_deletion_jobs where object_path = '10000000-0000-0000-0000-00000000000a/20000000-0000-0000-0000-0000000000a1/form--bbbb2222--w4.pdf'),
  1,
  'deleting a document row automatically enqueues its storage object for deletion'
);

select is(
  (select bucket_id from public.storage_deletion_jobs where object_path = '10000000-0000-0000-0000-00000000000a/20000000-0000-0000-0000-0000000000a1/form--bbbb2222--w4.pdf'),
  'staff-documents',
  'the enqueued cleanup job targets the staff-documents bucket'
);

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000006';

-- ---------------------------------------------------------------------------
-- cross-tenant isolation
-- ---------------------------------------------------------------------------

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000006';

select is(
  (select count(*)::int from public.documents),
  0,
  'org_b_owner cannot see org_a''s documents (cross-tenant)'
);

-- ---------------------------------------------------------------------------
-- app_hidden.storage_path_document_category: pure function, no RLS context needed
-- ---------------------------------------------------------------------------

reset role;

select is(
  app_hidden.storage_path_document_category('10000000-0000-0000-0000-00000000000a/20000000-0000-0000-0000-0000000000a1/sop--aaaa1111--fryer-sop.pdf'),
  'sop',
  'storage_path_document_category extracts the category prefix correctly'
);

select is(
  app_hidden.storage_path_document_category('10000000-0000-0000-0000-00000000000a/20000000-0000-0000-0000-0000000000a1/not-a-real-category--xyz--file.pdf'),
  null,
  'storage_path_document_category returns null for an unrecognized category rather than guessing'
);

select * from finish();
rollback;

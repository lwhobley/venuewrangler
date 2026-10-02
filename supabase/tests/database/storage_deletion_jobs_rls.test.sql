-- pgTAP authorization and safety tests for storage_deletion_jobs (supabase/migrations/20261002230000).
-- Fixture matches standard: org A (owner ...002), venue A1 (manager ...004, staff ...005), org B (owner ...006).

begin;
select plan(12);

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-000000000002', 'org-a-owner@example.com'),
  ('00000000-0000-0000-0000-000000000004', 'venue-a1-manager@example.com'),
  ('00000000-0000-0000-0000-000000000005', 'venue-a1-staff@example.com'),
  ('00000000-0000-0000-0000-000000000006', 'org-b-owner@example.com');

insert into public.organizations (id, name) values
  ('10000000-0000-0000-0000-00000000000a', 'Org A'),
  ('10000000-0000-0000-0000-00000000000b', 'Org B');

insert into public.venues (id, organization_id, name) values
  ('20000000-0000-0000-0000-0000000000a1', '10000000-0000-0000-0000-00000000000a', 'Venue A1');

insert into public.memberships (user_id, organization_id, venue_id, role) values
  ('00000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-00000000000a', null, 'organization_owner'),
  ('00000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-0000000000a1', 'venue_manager'),
  ('00000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-0000000000a1', 'staff');

-- ---------------------------------------------------------------------------
-- 1. Unit test: safe path guard allows compliant path
-- ---------------------------------------------------------------------------
select is(
  app_hidden.is_safe_storage_deletion_path(
    'incident-evidence',
    '10000000-0000-0000-0000-00000000000a/20000000-0000-0000-0000-0000000000a1/photo_123.jpg'
  ),
  true,
  'compliant org/venue/filename path passes safety check'
);

-- ---------------------------------------------------------------------------
-- 2. Unit test: safe path guard rejects directory traversal
-- ---------------------------------------------------------------------------
select is(
  app_hidden.is_safe_storage_deletion_path(
    'incident-evidence',
    '10000000-0000-0000-0000-00000000000a/../../passwords.txt'
  ),
  false,
  'directory traversal path is rejected'
);

-- ---------------------------------------------------------------------------
-- 3. Unit test: safe path guard rejects unknown bucket
-- ---------------------------------------------------------------------------
select is(
  app_hidden.is_safe_storage_deletion_path(
    'arbitrary-bucket',
    '10000000-0000-0000-0000-00000000000a/file.pdf'
  ),
  false,
  'unregistered bucket is rejected'
);

-- ---------------------------------------------------------------------------
-- 4. RLS: authenticated user cannot SELECT from storage_deletion_jobs
-- ---------------------------------------------------------------------------
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000004';

select throws_ok(
  $$ select count(*) from public.storage_deletion_jobs $$,
  '42501',
  null,
  'authenticated user has no SELECT privilege on storage_deletion_jobs'
);

-- ---------------------------------------------------------------------------
-- 5. RLS: authenticated user cannot INSERT into storage_deletion_jobs
-- ---------------------------------------------------------------------------
select throws_ok(
  $$ insert into public.storage_deletion_jobs (organization_id, bucket_id, object_path)
     values ('10000000-0000-0000-0000-00000000000a', 'incident-evidence', '10000000-0000-0000-0000-00000000000a/f.jpg') $$,
  '42501',
  null,
  'authenticated user has no INSERT privilege on storage_deletion_jobs'
);

-- ---------------------------------------------------------------------------
-- 6. Trigger: inserting unsafe path raises 42501 exception even as service/admin
-- ---------------------------------------------------------------------------
reset role;

select throws_ok(
  $$ insert into public.storage_deletion_jobs (organization_id, bucket_id, object_path)
     values ('10000000-0000-0000-0000-00000000000a', 'incident-evidence', 'malicious/../path') $$,
  '42501',
  null,
  'inserting unsafe path triggers permission error'
);

-- ---------------------------------------------------------------------------
-- 7. Trigger: service-role inserts valid job and auto-derives organization_id
-- ---------------------------------------------------------------------------
insert into public.storage_deletion_jobs (
  id, venue_id, bucket_id, object_path
) values (
  '90000000-0000-0000-0000-000000000001',
  '20000000-0000-0000-0000-0000000000a1',
  'incident-evidence',
  '10000000-0000-0000-0000-00000000000a/20000000-0000-0000-0000-0000000000a1/img.png'
);

select is(
  (select organization_id from public.storage_deletion_jobs where id = '90000000-0000-0000-0000-000000000001'),
  '10000000-0000-0000-0000-00000000000a'::uuid,
  'organization_id is auto-derived from venue_id on insert'
);

select is(
  (select status from public.storage_deletion_jobs where id = '90000000-0000-0000-0000-000000000001'),
  'pending',
  'initial job status is pending'
);

-- ---------------------------------------------------------------------------
-- 9 & 10. Worker execution: process batch completes valid job
-- ---------------------------------------------------------------------------
-- Seed dummy object in storage.objects so deletion can succeed
insert into storage.objects (id, bucket_id, name, owner)
values (
  'a0000000-0000-0000-0000-000000000001',
  'incident-evidence',
  '10000000-0000-0000-0000-00000000000a/20000000-0000-0000-0000-0000000000a1/img.png',
  '00000000-0000-0000-0000-000000000004'
) on conflict do nothing;

select lives_ok(
  $$ select * from app_hidden.process_storage_deletion_batch(10) $$,
  'worker batch runs without exception'
);

select is(
  (select status from public.storage_deletion_jobs where id = '90000000-0000-0000-0000-000000000001'),
  'completed',
  'processed job status is completed'
);

-- ---------------------------------------------------------------------------
-- 11. Retry exhaustion: attempts >= 10 transitions job to dead
-- ---------------------------------------------------------------------------
insert into public.storage_deletion_jobs (
  id, organization_id, bucket_id, object_path, status, attempts
) values (
  '90000000-0000-0000-0000-000000000002',
  '10000000-0000-0000-0000-00000000000a',
  'incident-evidence',
  '10000000-0000-0000-0000-00000000000a/test.png',
  'pending',
  10
);

select is(
  (select status from public.storage_deletion_jobs where id = '90000000-0000-0000-0000-000000000002'),
  'dead',
  'attempts >= 10 automatically parks job as dead'
);

-- ---------------------------------------------------------------------------
-- 12. Storage object actually deleted
-- ---------------------------------------------------------------------------
select is(
  (select count(*)::integer from storage.objects where id = 'a0000000-0000-0000-0000-000000000001'),
  0,
  'underlying storage object was deleted by worker'
);

select * from finish();
rollback;

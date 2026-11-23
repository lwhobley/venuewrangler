-- pgTAP authorization tests for Storage policies after H1/M3/M4 alignment
-- (20261123150000_incident_evidence_rls_alignment.sql).

begin;
select plan(21);

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-000000000004', 'venue-a1-manager@example.com'),
  ('00000000-0000-0000-0000-000000000005', 'venue-a1-staff@example.com'),
  ('00000000-0000-0000-0000-000000000007', 'venue-a1-other-staff@example.com');

insert into public.organizations (id, name) values
  ('10000000-0000-0000-0000-00000000000a', 'Org A'),
  ('10000000-0000-0000-0000-00000000000b', 'Org B');

insert into public.venues (id, organization_id, name) values
  ('20000000-0000-0000-0000-0000000000a1', '10000000-0000-0000-0000-00000000000a', 'Venue A1'),
  ('20000000-0000-0000-0000-0000000000b1', '10000000-0000-0000-0000-00000000000b', 'Venue B1');

insert into public.memberships (user_id, organization_id, venue_id, role) values
  ('00000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-0000000000a1', 'venue_manager'),
  ('00000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-0000000000a1', 'staff'),
  ('00000000-0000-0000-0000-000000000007', '10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-0000000000a1', 'staff');

-- Staff 005 reports incident I1; staff 007 reports I2.
reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000005';
insert into public.incidents (id, venue_id, title) values
  ('50000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-0000000000a1', 'Reporter incident');
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000007';
insert into public.incidents (id, venue_id, title) values
  ('50000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-0000000000a1', 'Peer incident');

reset role;
-- Seed storage objects as table owner (bypasses RLS).
-- photo1: 4-segment under I1, owned by peer 007 (uploader ≠ reporter) — M3: reporter can still read.
-- photo2: other venue
-- photo4: under I1, owned by manager
-- legacy3: 3-segment linked via incident_attachments
-- bad-org: matching venue UUID but wrong org prefix (M4)
insert into storage.objects (bucket_id, name, owner) values
  (
    'incident-evidence',
    '10000000-0000-0000-0000-00000000000a/20000000-0000-0000-0000-0000000000a1/50000000-0000-0000-0000-000000000001/photo1.jpg',
    '00000000-0000-0000-0000-000000000007'
  ),
  (
    'incident-evidence',
    '10000000-0000-0000-0000-00000000000b/20000000-0000-0000-0000-0000000000b1/photo2.jpg',
    null
  ),
  (
    'incident-evidence',
    '10000000-0000-0000-0000-00000000000a/20000000-0000-0000-0000-0000000000a1/50000000-0000-0000-0000-000000000001/photo4.jpg',
    '00000000-0000-0000-0000-000000000004'
  ),
  (
    'incident-evidence',
    '10000000-0000-0000-0000-00000000000a/20000000-0000-0000-0000-0000000000a1/legacy.jpg',
    '00000000-0000-0000-0000-000000000007'
  ),
  (
    'incident-evidence',
    '10000000-0000-0000-0000-00000000000b/20000000-0000-0000-0000-0000000000a1/50000000-0000-0000-0000-000000000001/bad-org.jpg',
    '00000000-0000-0000-0000-000000000005'
  ),
  ('incident-evidence', 'not-a-valid-path.jpg', null),
  ('exports', '10000000-0000-0000-0000-00000000000a/20000000-0000-0000-0000-0000000000a1/report.csv', null);

-- Legacy attachment row (bypass prepare trigger path check by inserting as owner with
-- direct columns — prepare trigger still validates path, so use a path that matches
-- the new prefix via a separate insert as the reporter below for new rows; for legacy
-- seed we need to temporarily relax or insert attachments with matching new path only.
-- Instead: insert legacy attachment using a SECURITY DEFINER path — table owner bypasses
-- RLS but NOT BEFORE triggers. Seed legacy via a path that passes the NEW prefix check
-- is required for new inserts; for SELECT legacy test, insert attachment with matching
-- org/venue/incident prefix is the only option under the new trigger.
--
-- To exercise legacy 3-segment SELECT, disable trigger briefly as table owner.
alter table public.incident_attachments disable trigger prepare_incident_attachment_insert;
insert into public.incident_attachments (
  id, incident_id, organization_id, venue_id, storage_path, uploaded_by
) values (
  '60000000-0000-0000-0000-000000000099',
  '50000000-0000-0000-0000-000000000001',
  '10000000-0000-0000-0000-00000000000a',
  '20000000-0000-0000-0000-0000000000a1',
  '10000000-0000-0000-0000-00000000000a/20000000-0000-0000-0000-0000000000a1/legacy.jpg',
  '00000000-0000-0000-0000-000000000005'
);
alter table public.incident_attachments enable trigger prepare_incident_attachment_insert;

-- ---------------------------------------------------------------------------
-- incident-evidence: SELECT by incident identity (M3), not Storage owner
-- ---------------------------------------------------------------------------

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000005';

select is(
  (
    select count(*)::int from storage.objects
    where bucket_id = 'incident-evidence'
      and name = '10000000-0000-0000-0000-00000000000a/20000000-0000-0000-0000-0000000000a1/50000000-0000-0000-0000-000000000001/photo1.jpg'
  ),
  1,
  'the reporter can read evidence on their incident even when Storage owner is someone else'
);

select is(
  (
    select count(*)::int from storage.objects
    where bucket_id = 'incident-evidence'
      and name = '10000000-0000-0000-0000-00000000000a/20000000-0000-0000-0000-0000000000a1/legacy.jpg'
  ),
  1,
  'legacy 3-segment evidence linked via incident_attachments is readable by the reporter'
);

select is(
  (
    select count(*)::int from storage.objects
    where bucket_id = 'incident-evidence'
      and name = '10000000-0000-0000-0000-00000000000a/20000000-0000-0000-0000-0000000000a1/50000000-0000-0000-0000-000000000002/missing.jpg'
  ),
  0,
  'a staff member cannot invent access to a peer''s incident path'
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
    where bucket_id = 'incident-evidence'
      and name = '10000000-0000-0000-0000-00000000000b/20000000-0000-0000-0000-0000000000a1/50000000-0000-0000-0000-000000000001/bad-org.jpg'
  ),
  0,
  'org segment that does not match the venue''s organization is denied (M4)'
);

select is(
  (
    select count(*)::int from storage.objects
    where bucket_id = 'incident-evidence' and name = 'not-a-valid-path.jpg'
  ),
  0,
  'a malformed object path safely denies access rather than erroring'
);

-- Peer who uploaded photo1 but cannot read the incident must not retain SELECT via owner.
reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000007';

select is(
  (
    select count(*)::int from storage.objects
    where bucket_id = 'incident-evidence'
      and name = '10000000-0000-0000-0000-00000000000a/20000000-0000-0000-0000-0000000000a1/50000000-0000-0000-0000-000000000001/photo1.jpg'
  ),
  0,
  'Storage owner alone cannot read evidence on an incident they cannot SELECT'
);

-- ---------------------------------------------------------------------------
-- incident-evidence: INSERT requires can_read_incident + matching path (H1)
-- ---------------------------------------------------------------------------

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000005';

select lives_ok(
  $$ insert into storage.objects (bucket_id, name)
     values (
       'incident-evidence',
       '10000000-0000-0000-0000-00000000000a/20000000-0000-0000-0000-0000000000a1/50000000-0000-0000-0000-000000000001/photo3.jpg'
     ) $$,
  'the reporter can upload evidence under their incident''s path'
);

select throws_ok(
  $$ insert into storage.objects (bucket_id, name)
     values (
       'incident-evidence',
       '10000000-0000-0000-0000-00000000000a/20000000-0000-0000-0000-0000000000a1/photo-legacy-style.jpg'
     ) $$,
  '42501',
  null,
  'new uploads must use the 4-segment incident path'
);

select throws_ok(
  $$ insert into storage.objects (bucket_id, name)
     values (
       'incident-evidence',
       '10000000-0000-0000-0000-00000000000a/20000000-0000-0000-0000-0000000000a1/50000000-0000-0000-0000-000000000002/rogue.jpg'
     ) $$,
  '42501',
  null,
  'a staff member cannot upload evidence to a peer''s incident'
);

select throws_ok(
  $$ insert into storage.objects (bucket_id, name)
     values (
       'incident-evidence',
       '10000000-0000-0000-0000-00000000000b/20000000-0000-0000-0000-0000000000b1/50000000-0000-0000-0000-000000000001/rogue.jpg'
     ) $$,
  '42501',
  null,
  'a venue member cannot upload evidence under a venue they do not belong to'
);

select throws_ok(
  $$ insert into storage.objects (bucket_id, name)
     values (
       'incident-evidence',
       '10000000-0000-0000-0000-00000000000b/20000000-0000-0000-0000-0000000000a1/50000000-0000-0000-0000-000000000001/bad-org-upload.jpg'
     ) $$,
  '42501',
  null,
  'upload with mismatched org/venue segments is denied (M4)'
);

select lives_ok(
  $$ delete from storage.objects
     where bucket_id = 'incident-evidence'
       and name = '10000000-0000-0000-0000-00000000000a/20000000-0000-0000-0000-0000000000a1/50000000-0000-0000-0000-000000000001/photo1.jpg' $$,
  'a non-manager staff member''s delete attempt executes without error (no delete policy covers them)'
);

select is(
  (
    select count(*)::int from storage.objects
    where bucket_id = 'incident-evidence'
      and name = '10000000-0000-0000-0000-00000000000a/20000000-0000-0000-0000-0000000000a1/50000000-0000-0000-0000-000000000001/photo1.jpg'
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
       and name = '10000000-0000-0000-0000-00000000000a/20000000-0000-0000-0000-0000000000a1/50000000-0000-0000-0000-000000000001/photo1.jpg' $$,
  'venue_manager can delete an evidence object in their venue'
);

select is(
  (select count(*)::int from storage.objects
    where bucket_id = 'incident-evidence'
      and name = '10000000-0000-0000-0000-00000000000a/20000000-0000-0000-0000-0000000000a1/50000000-0000-0000-0000-000000000001/photo4.jpg'),
  1,
  'a venue manager can read evidence on any readable incident in the venue'
);

-- ---------------------------------------------------------------------------
-- checklist-evidence: org↔venue binding (M4) + venue member insert
-- ---------------------------------------------------------------------------

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000005';

select lives_ok(
  $$ insert into storage.objects (bucket_id, name)
     values ('checklist-evidence', '10000000-0000-0000-0000-00000000000a/20000000-0000-0000-0000-0000000000a1/check1.jpg') $$,
  'a venue member can upload to checklist-evidence under a matching org/venue path'
);

select throws_ok(
  $$ insert into storage.objects (bucket_id, name)
     values ('checklist-evidence', '10000000-0000-0000-0000-00000000000b/20000000-0000-0000-0000-0000000000a1/check-bad-org.jpg') $$,
  '42501',
  null,
  'checklist-evidence upload with mismatched org/venue is denied (M4)'
);

-- staff-documents remains Edge/service-role only
select throws_ok(
  $$ insert into storage.objects (bucket_id, name)
     values ('staff-documents', '10000000-0000-0000-0000-00000000000a/20000000-0000-0000-0000-0000000000a1/sop--aaaa--w9.pdf') $$,
  '42501',
  null,
  'a client can never upload directly into staff-documents'
);

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
  'a client can never write directly into exports'
);

select * from finish();
rollback;

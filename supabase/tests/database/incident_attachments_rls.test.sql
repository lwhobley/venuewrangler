-- pgTAP authorization tests for incident_attachments (supabase/migrations/20261002050000).
-- Reuses the same org/venue/membership roster shape as the other test files.

begin;
select plan(10);

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

insert into public.incidents (id, venue_id, title) values
  ('50000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-0000000000a1', 'Spilled fryer oil');

-- ---------------------------------------------------------------------------
-- insert
-- ---------------------------------------------------------------------------

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000005';

select lives_ok(
  $$ insert into public.incident_attachments (id, incident_id, storage_path)
     values (
       '60000000-0000-0000-0000-000000000001',
       '50000000-0000-0000-0000-000000000001',
       '10000000-0000-0000-0000-00000000000a/20000000-0000-0000-0000-0000000000a1/photo1.jpg'
     ) $$,
  'a venue member can attach evidence to an incident in their venue'
);

select is(
  (select venue_id from public.incident_attachments where id = '60000000-0000-0000-0000-000000000001'),
  '20000000-0000-0000-0000-0000000000a1'::uuid,
  'venue_id is auto-derived from the parent incident'
);

select is(
  (select uploaded_by from public.incident_attachments where id = '60000000-0000-0000-0000-000000000001'),
  '00000000-0000-0000-0000-000000000005'::uuid,
  'uploaded_by is always the calling user'
);

select throws_ok(
  $$ insert into public.incident_attachments (incident_id, storage_path)
     values ('50000000-0000-0000-0000-000000000001', '99999999-0000-0000-0000-00000000ffff/attack/photo.jpg') $$,
  null,
  null,
  'a storage_path that does not match the incident''s own organization_id/venue_id prefix is rejected'
);

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000006';

select throws_ok(
  $$ insert into public.incident_attachments (incident_id, storage_path)
     values ('50000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-00000000000a/20000000-0000-0000-0000-0000000000a1/rogue.jpg') $$,
  '42501',
  null,
  'a user outside the venue cannot attach evidence to its incident'
);

select is(
  (select count(*)::int from public.incident_attachments),
  0,
  'org_b_owner cannot see org_a''s incident attachments (cross-tenant)'
);

-- ---------------------------------------------------------------------------
-- select / delete
-- ---------------------------------------------------------------------------

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000005';

select is(
  (select count(*)::int from public.incident_attachments),
  1,
  'a venue member can see the attachment'
);

select lives_ok(
  $$ delete from public.incident_attachments where id = '60000000-0000-0000-0000-000000000001' $$,
  'a non-manager''s delete attempt executes without error (no delete policy covers them)'
);

select is(
  (select count(*)::int from public.incident_attachments where id = '60000000-0000-0000-0000-000000000001'),
  1,
  'the attachment still exists afterward (staff has no delete rights)'
);

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000004';

select lives_ok(
  $$ delete from public.incident_attachments where id = '60000000-0000-0000-0000-000000000001' $$,
  'venue_manager can delete an attachment'
);

select * from finish();
rollback;

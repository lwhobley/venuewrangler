-- pgTAP authorization tests for incident_attachments (H1 alignment with can_read_incident).
-- Path convention: {org}/{venue}/{incident_id}/{filename}.

begin;
select plan(12);

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-000000000004', 'venue-a1-manager@example.com'),
  ('00000000-0000-0000-0000-000000000005', 'venue-a1-staff@example.com'),
  ('00000000-0000-0000-0000-000000000007', 'venue-a1-other-staff@example.com'),
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
  ('00000000-0000-0000-0000-000000000007', '10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-0000000000a1', 'staff'),
  ('00000000-0000-0000-0000-000000000006', '10000000-0000-0000-0000-00000000000b', null, 'organization_owner');

-- Staff 005 reports the incident (reported_by set by prepare trigger).
reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000005';
insert into public.incidents (id, venue_id, title) values
  ('50000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-0000000000a1', 'Spilled fryer oil');

-- ---------------------------------------------------------------------------
-- insert
-- ---------------------------------------------------------------------------

select lives_ok(
  $$ insert into public.incident_attachments (id, incident_id, storage_path)
     values (
       '60000000-0000-0000-0000-000000000001',
       '50000000-0000-0000-0000-000000000001',
       '10000000-0000-0000-0000-00000000000a/20000000-0000-0000-0000-0000000000a1/50000000-0000-0000-0000-000000000001/photo1.jpg'
     ) $$,
  'the reporter can attach evidence to their own incident'
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
     values (
       '50000000-0000-0000-0000-000000000001',
       '99999999-0000-0000-0000-00000000ffff/attack/photo.jpg'
     ) $$,
  null,
  null,
  'a storage_path that does not match org/venue/incident prefix is rejected'
);

select throws_ok(
  $$ insert into public.incident_attachments (incident_id, storage_path)
     values (
       '50000000-0000-0000-0000-000000000001',
       '10000000-0000-0000-0000-00000000000a/20000000-0000-0000-0000-0000000000a1/legacy-no-incident.jpg'
     ) $$,
  null,
  null,
  'legacy 3-segment paths are rejected on new attachment inserts'
);

-- Peer staff cannot attach to an incident they cannot read (H1).
reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000007';

select throws_ok(
  $$ insert into public.incident_attachments (incident_id, storage_path)
     values (
       '50000000-0000-0000-0000-000000000001',
       '10000000-0000-0000-0000-00000000000a/20000000-0000-0000-0000-0000000000a1/50000000-0000-0000-0000-000000000001/rogue.jpg'
     ) $$,
  '42501',
  null,
  'another staff member cannot attach evidence to an incident they cannot read'
);

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000006';

select throws_ok(
  $$ insert into public.incident_attachments (incident_id, storage_path)
     values (
       '50000000-0000-0000-0000-000000000001',
       '10000000-0000-0000-0000-00000000000a/20000000-0000-0000-0000-0000000000a1/50000000-0000-0000-0000-000000000001/rogue.jpg'
     ) $$,
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
  'the reporter can see the attachment on their incident'
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

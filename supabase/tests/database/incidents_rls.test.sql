-- pgTAP authorization tests for incidents (supabase/migrations/20261002030000). Reuses the
-- same org/venue/membership roster shape as the other test files; see foundation_rls.test.sql
-- for the full cast if these ids look unfamiliar.

begin;
select plan(20);

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-000000000002', 'org-a-owner@example.com'),
  ('00000000-0000-0000-0000-000000000004', 'venue-a1-manager@example.com'),
  ('00000000-0000-0000-0000-000000000005', 'venue-a1-staff@example.com'),
  ('00000000-0000-0000-0000-000000000006', 'org-b-owner@example.com'),
  ('00000000-0000-0000-0000-000000000008', 'venue-a1-staff-2@example.com');

insert into public.organizations (id, name) values
  ('10000000-0000-0000-0000-00000000000a', 'Org A'),
  ('10000000-0000-0000-0000-00000000000b', 'Org B');

insert into public.venues (id, organization_id, name) values
  ('20000000-0000-0000-0000-0000000000a1', '10000000-0000-0000-0000-00000000000a', 'Venue A1'),
  ('20000000-0000-0000-0000-0000000000b1', '10000000-0000-0000-0000-00000000000b', 'Venue B1');

insert into public.memberships (user_id, organization_id, venue_id, role) values
  ('00000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-00000000000a', null, 'organization_owner'),
  ('00000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-0000000000a1', 'venue_manager'),
  ('00000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-0000000000a1', 'staff'),
  ('00000000-0000-0000-0000-000000000008', '10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-0000000000a1', 'staff'),
  ('00000000-0000-0000-0000-000000000006', '10000000-0000-0000-0000-00000000000b', null, 'organization_owner');

insert into public.memberships (user_id, organization_id, venue_id, role) values
  ('00000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-00000000000b',
   '20000000-0000-0000-0000-0000000000b1', 'venue_manager');

-- ---------------------------------------------------------------------------
-- insert
-- ---------------------------------------------------------------------------

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000005';

select lives_ok(
  $$ insert into public.incidents (id, venue_id, title, severity)
     values ('50000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-0000000000a1', 'Spilled fryer oil', 'medium') $$,
  'a staff member can report an incident in their venue'
);

select is(
  (select reported_by from public.incidents where id = '50000000-0000-0000-0000-000000000001'),
  '00000000-0000-0000-0000-000000000005'::uuid,
  'reported_by is always the calling user'
);

select is(
  (select organization_id from public.incidents where id = '50000000-0000-0000-0000-000000000001'),
  '10000000-0000-0000-0000-00000000000a'::uuid,
  'organization_id is auto-derived from venue_id'
);

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000006';

select throws_ok(
  $$ insert into public.incidents (venue_id, title) values ('20000000-0000-0000-0000-0000000000a1', 'Rogue report') $$,
  '42501',
  null,
  'a user outside the venue cannot report an incident there'
);

select is(
  (select count(*)::int from public.incidents),
  0,
  'org_b_owner cannot see org_a''s incidents (cross-tenant)'
);

-- ---------------------------------------------------------------------------
-- select / reporter edit window
-- ---------------------------------------------------------------------------

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000005';

select is(
  (select count(*)::int from public.incidents),
  1,
  'a venue member can see the incident'
);

select throws_ok(
  $$ update public.incidents set venue_id = '20000000-0000-0000-0000-0000000000b1',
     organization_id = '10000000-0000-0000-0000-00000000000b'
     where id = '50000000-0000-0000-0000-000000000001' $$,
  '42501', null,
  'reporter cannot move an incident into a workspace they manage'
);

select lives_ok(
  $$ update public.incidents set title = 'Spilled fryer oil near entrance' where id = '50000000-0000-0000-0000-000000000001' $$,
  'the reporter can edit the title while the incident is still open'
);

select throws_ok(
  $$ update public.incidents set status = 'resolved' where id = '50000000-0000-0000-0000-000000000001' $$,
  '42501',
  null,
  'the reporter cannot change the incident''s status themselves'
);

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000008';

select lives_ok(
  $$ update public.incidents set title = 'Hijacked by another staff member' where id = '50000000-0000-0000-0000-000000000001' $$,
  'an unrelated staff member''s edit attempt executes without error but matches no rows'
);

select is(
  (select title from public.incidents where id = '50000000-0000-0000-0000-000000000001'),
  'Spilled fryer oil near entrance',
  'the title is unchanged by the unrelated staff member''s no-op update'
);

-- ---------------------------------------------------------------------------
-- manager resolution + audit trail
-- ---------------------------------------------------------------------------

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000004';

select lives_ok(
  $$ update public.incidents set status = 'resolved' where id = '50000000-0000-0000-0000-000000000001' $$,
  'venue_manager can resolve the incident'
);

select is(
  (select resolved_by from public.incidents where id = '50000000-0000-0000-0000-000000000001'),
  '00000000-0000-0000-0000-000000000004'::uuid,
  'resolved_by is auto-set to the resolving manager'
);

select is(
  (select resolved_at is not null from public.incidents where id = '50000000-0000-0000-0000-000000000001'),
  true,
  'resolved_at is auto-set on resolution'
);

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000002';

select is(
  (
    select metadata from public.audit_log
    where action = 'incident.status_changed' and target_id = '50000000-0000-0000-0000-000000000001'
  ),
  '{"to": "resolved", "from": "open"}'::jsonb,
  'the status change is recorded in the audit log with before/after values'
);

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000005';

select lives_ok(
  $$ update public.incidents set title = 'Trying to edit after resolution' where id = '50000000-0000-0000-0000-000000000001' $$,
  'the reporter''s edit attempt after resolution executes without error but matches no rows'
);

select is(
  (select title from public.incidents where id = '50000000-0000-0000-0000-000000000001'),
  'Spilled fryer oil near entrance',
  'the title is unchanged: the reporter''s edit window closed once the incident left ''open'''
);

-- ---------------------------------------------------------------------------
-- delete: managers only
-- ---------------------------------------------------------------------------

select lives_ok(
  $$ delete from public.incidents where id = '50000000-0000-0000-0000-000000000001' $$,
  'the reporter''s delete attempt executes without error (no delete policy covers them)'
);

select is(
  (select count(*)::int from public.incidents where id = '50000000-0000-0000-0000-000000000001'),
  1,
  'the incident still exists afterward (the reporter has no delete rights)'
);

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000004';

select lives_ok(
  $$ delete from public.incidents where id = '50000000-0000-0000-0000-000000000001' $$,
  'venue_manager can delete an incident'
);

select * from finish();
rollback;

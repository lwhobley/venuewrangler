-- pgTAP authorization tests for shift_insights (supabase/migrations/20261002210000).
-- Fixture matches staff_requests_rls.test.sql: org A (owner ...002), venue A1 (manager ...004,
-- staff 1 ...005, staff 2 ...008), org B (owner ...006).

begin;
select plan(13);

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

-- Seed shifts for Venue A1 and Venue B1
insert into public.shifts (id, venue_id, staff_id, start_time, end_time) values
  ('40000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-000000000005', now(), now() + interval '4 hours'),
  ('40000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-0000000000b1', null, now(), now() + interval '4 hours');

-- ---------------------------------------------------------------------------
-- 1. insert: negative (non-member)
-- ---------------------------------------------------------------------------

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000006';

select throws_ok(
  $$ insert into public.shift_insights (venue_id, kind, title, body)
     values ('20000000-0000-0000-0000-0000000000a1', 'shift_summary', 'Busy night', 'Expected peak volume') $$,
  '42501',
  null,
  'non-member cannot insert shift insight for venue A1'
);

-- ---------------------------------------------------------------------------
-- 2. insert: negative (regular staff member)
-- ---------------------------------------------------------------------------

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000005';

select throws_ok(
  $$ insert into public.shift_insights (venue_id, kind, title, body)
     values ('20000000-0000-0000-0000-0000000000a1', 'shift_summary', 'Busy night', 'Expected peak volume') $$,
  '42501',
  null,
  'staff member cannot insert shift insight'
);

-- ---------------------------------------------------------------------------
-- 3. insert: positive (venue manager)
-- ---------------------------------------------------------------------------

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000004';

select lives_ok(
  $$ insert into public.shift_insights (id, venue_id, shift_id, kind, title, body)
     values ('70000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-0000000000a1', '40000000-0000-0000-0000-000000000001', 'rush_prep', 'Dinner Rush Warning', 'Ramp up bar stock before 7 PM.') $$,
  'venue manager can insert shift insight'
);

-- 4. auto-derived fields
select is(
  (select organization_id from public.shift_insights where id = '70000000-0000-0000-0000-000000000001'),
  '10000000-0000-0000-0000-00000000000a'::uuid,
  'organization_id is auto-derived from venue_id'
);

-- 5. created_by is set to manager uid
select is(
  (select created_by from public.shift_insights where id = '70000000-0000-0000-0000-000000000001'),
  '00000000-0000-0000-0000-000000000004'::uuid,
  'created_by is set to the inserting user'
);

-- ---------------------------------------------------------------------------
-- 6. select: positive (venue staff can view)
-- ---------------------------------------------------------------------------

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000005';

select is(
  (select count(*)::integer from public.shift_insights where venue_id = '20000000-0000-0000-0000-0000000000a1'),
  1,
  'venue staff can view shift insights for their venue'
);

-- ---------------------------------------------------------------------------
-- 7. select: cross-tenant isolation (org B owner sees 0 rows)
-- ---------------------------------------------------------------------------

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000006';

select is(
  (select count(*)::integer from public.shift_insights where id = '70000000-0000-0000-0000-000000000001'),
  0,
  'org B user cannot view shift insights belonging to venue A1'
);

-- ---------------------------------------------------------------------------
-- 8. insert: mismatching shift_id and venue_id throws exception
-- ---------------------------------------------------------------------------

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000004';

select throws_ok(
  $$ insert into public.shift_insights (venue_id, shift_id, kind, title, body)
     values ('20000000-0000-0000-0000-0000000000a1', '40000000-0000-0000-0000-000000000002', 'rush_prep', 'Invalid shift', 'Mismatch venue and shift') $$,
  null,
  null,
  'inserting an insight linking a shift belonging to another venue fails'
);

-- ---------------------------------------------------------------------------
-- 9. insert: omitting venue_id when shift_id is provided derives venue_id
-- ---------------------------------------------------------------------------

select lives_ok(
  $$ insert into public.shift_insights (id, shift_id, kind, title, body)
     values ('70000000-0000-0000-0000-000000000002', '40000000-0000-0000-0000-000000000001', 'station_balance', 'Station Check', 'All stations covered.') $$,
  'manager can insert an insight by shift_id alone'
);

select is(
  (select venue_id from public.shift_insights where id = '70000000-0000-0000-0000-000000000002'),
  '20000000-0000-0000-0000-0000000000a1'::uuid,
  'venue_id was auto-derived from shift_id'
);

-- ---------------------------------------------------------------------------
-- 11. update: manager can update insight
-- ---------------------------------------------------------------------------

select lives_ok(
  $$ update public.shift_insights set title = 'Updated Rush Warning' where id = '70000000-0000-0000-0000-000000000001' $$,
  'manager can update shift insight'
);

-- ---------------------------------------------------------------------------
-- 12. update: staff update matches 0 rows
-- ---------------------------------------------------------------------------

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000005';

update public.shift_insights set title = 'Staff Hacked Title' where id = '70000000-0000-0000-0000-000000000001';

select is(
  (select title from public.shift_insights where id = '70000000-0000-0000-0000-000000000001'),
  'Updated Rush Warning',
  'staff member update does not modify the insight'
);

-- ---------------------------------------------------------------------------
-- 13. delete: manager can delete insight
-- ---------------------------------------------------------------------------

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000004';

delete from public.shift_insights where id = '70000000-0000-0000-0000-000000000002';

select is(
  (select count(*)::integer from public.shift_insights where id = '70000000-0000-0000-0000-000000000002'),
  0,
  'manager can delete shift insight'
);

finish();
rollback;

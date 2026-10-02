-- pgTAP authorization tests for staff_requests (supabase/migrations/20261002200000).
-- Fixture matches shift_swaps_rls.test.sql: org A (owner ...002), venue A1 (manager ...004,
-- staff 1 ...005, staff 2 ...008), org B (owner ...006).

begin;
select plan(14);

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

-- Seed shifts: shift 1 assigned to staff 1; shift 2 is open (staff_id is null)
insert into public.shifts (id, venue_id, staff_id, start_time, end_time) values
  ('40000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-000000000005', now(), now() + interval '4 hours'),
  ('40000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-0000000000a1', null, now() + interval '1 day', now() + interval '1 day 4 hours');

-- ---------------------------------------------------------------------------
-- 1. insert: negative (non-member)
-- ---------------------------------------------------------------------------

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000006';

select throws_ok(
  $$ insert into public.staff_requests (venue_id, kind, title, details)
     values ('20000000-0000-0000-0000-0000000000a1', 'time_off', 'Vacation', 'Going away') $$,
  '42501',
  null,
  'non-member cannot submit a staff request for venue A1'
);

-- ---------------------------------------------------------------------------
-- 2. insert: positive (venue staff)
-- ---------------------------------------------------------------------------

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000005';

select lives_ok(
  $$ insert into public.staff_requests (id, venue_id, kind, title, details, requested_range_start, requested_range_end)
     values ('60000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-0000000000a1', 'time_off', 'Vacation', 'Trip to see family', '2026-11-01', '2026-11-05') $$,
  'staff member can create a time_off request for their venue'
);

-- 3. auto-derived fields
select is(
  (select organization_id from public.staff_requests where id = '60000000-0000-0000-0000-000000000001'),
  '10000000-0000-0000-0000-00000000000a'::uuid,
  'organization_id is auto-derived from venue_id'
);

select is(
  (select user_id from public.staff_requests where id = '60000000-0000-0000-0000-000000000001'),
  '00000000-0000-0000-0000-000000000005'::uuid,
  'user_id is always forced to auth.uid()'
);

select is(
  (select status from public.staff_requests where id = '60000000-0000-0000-0000-000000000001'),
  'pending',
  'initial status is forced to pending'
);

-- 4. cross-venue shift validation
select throws_ok(
  $$ insert into public.staff_requests (venue_id, kind, title, requested_shift_id)
     values ('20000000-0000-0000-0000-0000000000a1', 'drop_shift', 'Drop', '00000000-0000-0000-0000-999999999999') $$,
  null,
  null,
  'cannot reference a non-existent or foreign shift'
);

-- ---------------------------------------------------------------------------
-- 5. select: cross-tenant isolation
-- ---------------------------------------------------------------------------

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000006';

select is(
  (select count(*)::int from public.staff_requests),
  0,
  'org_b_owner cannot see org_a staff requests'
);

-- 6. select: staff cannot see coworker requests
reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000008';

select is(
  (select count(*)::int from public.staff_requests where id = '60000000-0000-0000-0000-000000000001'),
  0,
  'staff 2 cannot see staff 1 request'
);

-- 7. select: manager can see all venue requests
reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000004';

select is(
  (select count(*)::int from public.staff_requests where id = '60000000-0000-0000-0000-000000000001'),
  1,
  'venue manager can see staff requests for their venue'
);

-- ---------------------------------------------------------------------------
-- 8. staff update: can cancel own request
-- ---------------------------------------------------------------------------

-- Seed a second request for staff 1 to cancel
reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000005';

insert into public.staff_requests (id, venue_id, kind, title, details)
values ('60000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-0000000000a1', 'other', 'Schedule question', 'Nevermind');

select lives_ok(
  $$ update public.staff_requests set status = 'cancelled' where id = '60000000-0000-0000-0000-000000000002' $$,
  'requester can cancel their own pending request'
);

-- 9. staff update: cannot self-approve
select throws_ok(
  $$ update public.staff_requests set status = 'approved' where id = '60000000-0000-0000-0000-000000000001' $$,
  '42501',
  null,
  'requester cannot approve their own request'
);

-- ---------------------------------------------------------------------------
-- 10. manager review: approve request
-- ---------------------------------------------------------------------------

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000004';

select lives_ok(
  $$ update public.staff_requests
     set status = 'approved', response_notes = 'Approved, enjoy your time off!'
     where id = '60000000-0000-0000-0000-000000000001' $$,
  'venue manager can approve pending staff request'
);

-- 11. reviewer metadata recorded
select is(
  (select reviewer_id from public.staff_requests where id = '60000000-0000-0000-0000-000000000001'),
  '00000000-0000-0000-0000-000000000004'::uuid,
  'reviewer_id is recorded as the reviewing manager'
);

-- 12. manager cannot re-review already decided request
select throws_ok(
  $$ update public.staff_requests set status = 'denied' where id = '60000000-0000-0000-0000-000000000001' $$,
  '42501',
  null,
  'cannot re-review an already decided request'
);

-- ---------------------------------------------------------------------------
-- 13 & 14. shift side-effects: drop_shift unassigns, add_shift claims
-- ---------------------------------------------------------------------------

-- Staff 1 requests drop on shift 1
reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000005';

insert into public.staff_requests (id, venue_id, kind, title, requested_shift_id)
values ('60000000-0000-0000-0000-000000000003', '20000000-0000-0000-0000-0000000000a1', 'drop_shift', 'Drop shift', '40000000-0000-0000-0000-000000000001');

-- Manager approves drop
reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000004';

update public.staff_requests set status = 'approved' where id = '60000000-0000-0000-0000-000000000003';

select is(
  (select staff_id from public.shifts where id = '40000000-0000-0000-0000-000000000001'),
  null,
  'approving drop_shift removes staff assignment from the shift'
);

-- Staff 2 requests to add open shift 2
reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000008';

insert into public.staff_requests (id, venue_id, kind, title, requested_shift_id)
values ('60000000-0000-0000-0000-000000000004', '20000000-0000-0000-0000-0000000000a1', 'add_shift', 'Claim open shift', '40000000-0000-0000-0000-000000000002');

-- Manager approves add_shift
reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000004';

update public.staff_requests set status = 'approved' where id = '60000000-0000-0000-0000-000000000004';

select is(
  (select staff_id from public.shifts where id = '40000000-0000-0000-0000-000000000002'),
  '00000000-0000-0000-0000-000000000008'::uuid,
  'approving add_shift assigns staff 2 to the open shift'
);

finish();
rollback;

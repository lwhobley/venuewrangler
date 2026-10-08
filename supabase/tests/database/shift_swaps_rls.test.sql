-- pgTAP authorization tests for shift_swaps (supabase/migrations/20261002160000). Same
-- org/venue/membership fixture shape as operational_tasks_rls.test.sql, with two staff
-- members (...005 and ...008) to exercise accept/offered-to logic.

begin;
select plan(18);

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

-- The requester also manages a free workspace in another organization.
insert into public.memberships (user_id, organization_id, venue_id, role) values
  ('00000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-00000000000b',
   '20000000-0000-0000-0000-0000000000b1', 'venue_manager');

-- Seeded as table owner: two shifts in venue A1, each assigned to a different staff member.
insert into public.shifts (id, venue_id, staff_id, start_time, end_time) values
  ('40000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-000000000005', now(), now() + interval '4 hours'),
  ('40000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-000000000005', now() + interval '1 day', now() + interval '1 day 4 hours');

-- ---------------------------------------------------------------------------
-- insert
-- ---------------------------------------------------------------------------

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000008';

select throws_ok(
  $$ insert into public.shift_swaps (shift_id) values ('40000000-0000-0000-0000-000000000001') $$,
  '42501',
  null,
  'a staff member cannot request a swap for a shift that isn''t theirs'
);

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000005';

select lives_ok(
  $$ insert into public.shift_swaps (id, shift_id) values ('50000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000001') $$,
  'the assigned staff member can request a swap for their own shift'
);
select throws_ok(
  $$ insert into public.shift_swaps (shift_id) values ('40000000-0000-0000-0000-000000000001') $$,
  '23505', null, 'a second pending request for the same shift is rejected'
);

select is(
  (select organization_id from public.shift_swaps where id = '50000000-0000-0000-0000-000000000001'),
  '10000000-0000-0000-0000-00000000000a'::uuid,
  'organization_id/venue_id are auto-derived from the shift'
);

select is(
  (select requested_by from public.shift_swaps where id = '50000000-0000-0000-0000-000000000001'),
  '00000000-0000-0000-0000-000000000005'::uuid,
  'requested_by is always the calling user'
);

select throws_ok(
  $$ update public.shift_swaps set venue_id = '20000000-0000-0000-0000-0000000000b1',
     organization_id = '10000000-0000-0000-0000-00000000000b', status = 'accepted',
     accepted_by = '00000000-0000-0000-0000-000000000008'
     where id = '50000000-0000-0000-0000-000000000001' $$,
  '42501', null,
  'managing another workspace cannot move and accept a swap from this venue'
);
select is(
  (select staff_id from public.shifts where id = '40000000-0000-0000-0000-000000000001'),
  '00000000-0000-0000-0000-000000000005'::uuid,
  'rejected cross-venue swap does not reassign the underlying shift'
);

-- ---------------------------------------------------------------------------
-- select: cross-tenant isolation
-- ---------------------------------------------------------------------------

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000006';

select is(
  (select count(*)::int from public.shift_swaps),
  0,
  'org_b_owner cannot see org_a''s shift swap requests (cross-tenant)'
);

-- ---------------------------------------------------------------------------
-- accept: an open swap request (offered_to is null)
-- ---------------------------------------------------------------------------

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000008';

select lives_ok(
  $$ update public.shift_swaps set status = 'accepted', accepted_by = '00000000-0000-0000-0000-000000000008' where id = '50000000-0000-0000-0000-000000000001' $$,
  'another staff member can accept an open swap request'
);

select is(
  (select staff_id from public.shifts where id = '40000000-0000-0000-0000-000000000001'),
  '00000000-0000-0000-0000-000000000008'::uuid,
  'accepting the swap reassigns the underlying shift to the accepter'
);

select throws_ok(
  $$ update public.shift_swaps set status = 'cancelled' where id = '50000000-0000-0000-0000-000000000001' $$,
  '42501',
  null,
  'a swap request that is no longer pending cannot be touched by a non-manager'
);

-- ---------------------------------------------------------------------------
-- offered_to: only the named recipient may accept
-- ---------------------------------------------------------------------------

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000005';

select lives_ok(
  $$ insert into public.shift_swaps (id, shift_id, offered_to) values ('50000000-0000-0000-0000-000000000002', '40000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000004') $$,
  'a swap can be offered to a specific user'
);

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000008';

select throws_ok(
  $$ update public.shift_swaps set status = 'accepted', accepted_by = '00000000-0000-0000-0000-000000000008' where id = '50000000-0000-0000-0000-000000000002' $$,
  '42501',
  null,
  'a swap offered to a specific user cannot be accepted by someone else'
);

-- ---------------------------------------------------------------------------
-- cancel: the requester may cancel their own pending request
-- ---------------------------------------------------------------------------

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000005';

select lives_ok(
  $$ update public.shift_swaps set status = 'cancelled' where id = '50000000-0000-0000-0000-000000000002' $$,
  'the requester can cancel their own pending swap request'
);

-- ---------------------------------------------------------------------------
-- managers may act regardless of requester/offered_to
-- ---------------------------------------------------------------------------

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000005';

select lives_ok(
  $$ insert into public.shift_swaps (id, shift_id) values ('50000000-0000-0000-0000-000000000003', '40000000-0000-0000-0000-000000000002') $$,
  'a new open swap request can be created on the same shift after the previous one was cancelled'
);

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000004';

select lives_ok(
  $$ update public.shift_swaps set status = 'declined' where id = '50000000-0000-0000-0000-000000000003' $$,
  'a venue_manager can decline a swap request on anyone''s behalf'
);

select is(
  (select status from public.shift_swaps where id = '50000000-0000-0000-0000-000000000003'),
  'declined',
  'the decline was applied'
);

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000005';
insert into public.shift_swaps(id,shift_id) values
  ('50000000-0000-0000-0000-000000000004',
   '40000000-0000-0000-0000-000000000002');
reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000004';
update public.shifts set staff_id = '00000000-0000-0000-0000-000000000008'
  where id = '40000000-0000-0000-0000-000000000002';
reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000008';
select throws_ok(
  $$ update public.shift_swaps set status='accepted',
       accepted_by='00000000-0000-0000-0000-000000000008'
     where id='50000000-0000-0000-0000-000000000004' $$,
  '40001', null, 'stale swap cannot reassign a shift that changed owners'
);

select * from finish();
rollback;

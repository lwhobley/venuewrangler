-- pgTAP tests for the launch-review schedule fixes:
--   D2  20261022120001_shift_versions_and_realtime.sql — stale board edits match no row
--   U1  20261022120002_manager_approved_swaps.sql     — take/approve flow, no double-booking
--   U2  20261022120003_staff_request_shift_guards.sql — request shift guards, pick-up overlap
-- Fixture: org A / venue A1 with manager Devon (...004), Ingrid (...005), Jada (...008),
-- Victor (...009); org B owner (...006).

begin;
select plan(38);

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-000000000004', 'devon@example.com'),
  ('00000000-0000-0000-0000-000000000005', 'ingrid@example.com'),
  ('00000000-0000-0000-0000-000000000006', 'org-b-owner@example.com'),
  ('00000000-0000-0000-0000-000000000008', 'jada@example.com'),
  ('00000000-0000-0000-0000-000000000009', 'victor@example.com');

insert into public.profiles (id, display_name) values
  ('00000000-0000-0000-0000-000000000004', 'Devon Patel'),
  ('00000000-0000-0000-0000-000000000005', 'Ingrid Ortega'),
  ('00000000-0000-0000-0000-000000000008', 'Jada Echols'),
  ('00000000-0000-0000-0000-000000000009', 'Victor Yang')
on conflict (id) do update set display_name = excluded.display_name;

insert into public.organizations (id, name) values
  ('10000000-0000-0000-0000-00000000000a', 'Org A'),
  ('10000000-0000-0000-0000-00000000000b', 'Org B');

insert into public.venues (id, organization_id, name, timezone) values
  ('20000000-0000-0000-0000-0000000000a1', '10000000-0000-0000-0000-00000000000a', 'Copper Kettle', 'America/Denver'),
  ('20000000-0000-0000-0000-0000000000b1', '10000000-0000-0000-0000-00000000000b', 'Venue B1', 'UTC');

insert into public.memberships (user_id, organization_id, venue_id, role) values
  ('00000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-0000000000a1', 'venue_manager'),
  ('00000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-0000000000a1', 'staff'),
  ('00000000-0000-0000-0000-000000000008', '10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-0000000000a1', 'staff'),
  ('00000000-0000-0000-0000-000000000009', '10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-0000000000a1', 'staff'),
  ('00000000-0000-0000-0000-000000000006', '10000000-0000-0000-0000-00000000000b', null, 'organization_owner');

-- s1: Ingrid's Thu server shift 22:30-04:30Z. s2: Jada's bar shift overlapping it.
-- s3: Ingrid's Fri server shift (for the D2 stale-board case). s4: an open shift overlapping s2.
insert into public.shifts (id, venue_id, staff_id, role_label, section, start_time, end_time) values
  ('40000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-000000000005', 'Server', 'main', '2026-10-22 22:30Z', '2026-10-23 04:30Z'),
  ('40000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-000000000008', 'Bartender', 'bar', '2026-10-22 22:00Z', '2026-10-23 06:30Z'),
  ('40000000-0000-0000-0000-000000000003', '20000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-000000000005', 'Server', 'main', '2026-10-23 22:30Z', '2026-10-24 04:30Z'),
  ('40000000-0000-0000-0000-000000000004', '20000000-0000-0000-0000-0000000000a1', null, 'Busser', null, '2026-10-22 23:00Z', '2026-10-23 03:00Z');

-- ---------------------------------------------------------------------------
-- D2: versions
-- ---------------------------------------------------------------------------

select is(
  (select version from public.shifts where id = '40000000-0000-0000-0000-000000000003'),
  1, 'a new shift starts at version 1'
);

-- Ingrid offers the Friday shift; Victor takes it; Devon approves.
reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000005';
insert into public.shift_swaps (id, shift_id) values
  ('50000000-0000-0000-0000-000000000003', '40000000-0000-0000-0000-000000000003');

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000009';
select is(
  public.claim_shift_swap('50000000-0000-0000-0000-000000000003'),
  'claimed', 'Victor offers to take Ingrid''s Friday shift'
);

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000004';
select lives_ok(
  $$ select public.approve_shift_swap('50000000-0000-0000-0000-000000000003') $$,
  'Devon approves the swap'
);
select is(
  (select version from public.shifts where id = '40000000-0000-0000-0000-000000000003'),
  2, 'the swap moved the shift forward one version'
);

-- Devon's stale board still holds version 1 and Ingrid: a patch filtered on that version
-- matches nothing and leaves Victor on the shift.
select is_empty(
  $$ update public.shifts set section = 'patio'
     where id = '40000000-0000-0000-0000-000000000003' and version = 1
     returning id $$,
  'an edit from a stale board (old version) matches no row'
);
select is(
  (select staff_id from public.shifts where id = '40000000-0000-0000-0000-000000000003'),
  '00000000-0000-0000-0000-000000000009'::uuid,
  'the stale edit did not undo Victor''s approved swap'
);
select isnt_empty(
  $$ update public.shifts set section = 'patio'
     where id = '40000000-0000-0000-0000-000000000003' and version = 2
     returning id $$,
  'the same edit against the current version applies'
);
select results_eq(
  $$ select staff_id, section, version from public.shifts
     where id = '40000000-0000-0000-0000-000000000003' $$,
  $$ values ('00000000-0000-0000-0000-000000000009'::uuid, 'patio'::text, 3) $$,
  'a section-only patch changes only the section and bumps the version'
);
select lives_ok(
  $$ update public.shifts set version = 99 where id = '40000000-0000-0000-0000-000000000003' $$,
  'a client may send a version...'
);
select is(
  (select version from public.shifts where id = '40000000-0000-0000-0000-000000000003'),
  4, '...but the database only ever moves it forward by one'
);
reset role;
select ok(
  (select count(*) from public.notification_events
   where target_user_id = '00000000-0000-0000-0000-000000000005'
     and kind = 'shift_swap' and title = 'Shift swap approved') = 1,
  'Ingrid is told her swap was approved'
);

-- ---------------------------------------------------------------------------
-- U1: Thursday swap, Jada already tends bar then
-- ---------------------------------------------------------------------------

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000005';
insert into public.shift_swaps (id, shift_id) values
  ('50000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000001');

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000008';

select throws_ok(
  $$ update public.shift_swaps set status = 'accepted',
       accepted_by = '00000000-0000-0000-0000-000000000008'
     where id = '50000000-0000-0000-0000-000000000001' $$,
  '42501', null, 'Jada cannot accept by writing the swap row directly'
);
select throws_ok(
  $$ update public.shift_swaps set status = 'claimed',
       accepted_by = '00000000-0000-0000-0000-000000000008'
     where id = '50000000-0000-0000-0000-000000000001' $$,
  '42501', null, 'Jada cannot claim by writing the swap row directly'
);
select throws_like(
  $$ select public.claim_shift_swap('50000000-0000-0000-0000-000000000001') $$,
  'shift_overlap: already working Bartender · Thu Oct 22, 04:00 PM',
  'taking a shift that overlaps your own is refused and names the clash in venue time'
);
select is(
  (select status from public.shift_swaps where id = '50000000-0000-0000-0000-000000000001'),
  'pending', 'the refused take left the swap open'
);
select is(
  public.claim_shift_swap('50000000-0000-0000-0000-000000000001', true),
  'claimed', 'Jada can take it anyway with an explicit override'
);
select is(
  (select staff_id from public.shifts where id = '40000000-0000-0000-0000-000000000001'),
  '00000000-0000-0000-0000-000000000005'::uuid,
  'the shift stays with Ingrid until a manager approves'
);
select throws_ok(
  $$ select public.approve_shift_swap('50000000-0000-0000-0000-000000000001') $$,
  '42501', null, 'staff cannot approve swaps'
);

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000004';

select ok(
  (select count(*) from public.notification_events
   where audience = 'venue_managers' and kind = 'shift_swap'
     and body = 'Jada Echols wants to take Ingrid Ortega''s Server · Thu Oct 22, 04:30 PM') = 1,
  'managers are asked to approve, with names and the shift'
);
select throws_ok(
  $$ update public.shift_swaps set status = 'accepted',
       accepted_by = '00000000-0000-0000-0000-000000000004'
     where id = '50000000-0000-0000-0000-000000000001' $$,
  '42501', null, 'a manager cannot take a claimed shift by writing the row'
);
select throws_ok(
  $$ select public.approve_shift_swap('50000000-0000-0000-0000-000000000001') $$,
  '23P01', null, 'approving re-checks the double-booking'
);
select lives_ok(
  $$ select public.approve_shift_swap('50000000-0000-0000-0000-000000000001', true) $$,
  'the manager can approve with an explicit override'
);
select results_eq(
  $$ select s.staff_id, w.accepted_by, w.approved_by, w.status
     from public.shifts s join public.shift_swaps w on w.shift_id = s.id
     where w.id = '50000000-0000-0000-0000-000000000001' $$,
  $$ values ('00000000-0000-0000-0000-000000000008'::uuid,
             '00000000-0000-0000-0000-000000000008'::uuid,
             '00000000-0000-0000-0000-000000000004'::uuid, 'accepted'::text) $$,
  'approval gives the shift to Jada and records Devon only as approver'
);

-- An open swap nobody has taken cannot be "approved" onto the manager.
reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000008';
insert into public.shift_swaps (id, shift_id) values
  ('50000000-0000-0000-0000-000000000002', '40000000-0000-0000-0000-000000000002');

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000004';
select throws_ok(
  $$ select public.approve_shift_swap('50000000-0000-0000-0000-000000000002') $$,
  '22023', null, 'an untaken open swap has nobody to approve it for'
);
select lives_ok(
  $$ update public.shift_swaps set status = 'declined'
     where id = '50000000-0000-0000-0000-000000000002' $$,
  'a manager can still decline directly'
);

-- Requester cannot take their own; outsiders cannot see or take.
reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000008';
insert into public.shift_swaps (id, shift_id) values
  ('50000000-0000-0000-0000-000000000004', '40000000-0000-0000-0000-000000000002');
select throws_ok(
  $$ select public.claim_shift_swap('50000000-0000-0000-0000-000000000004') $$,
  '42501', null, 'you cannot take your own shift'
);

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000006';
select throws_ok(
  $$ select public.claim_shift_swap('50000000-0000-0000-0000-000000000004') $$,
  '42501', null, 'another organization cannot take a swap'
);

-- A manager taking a shift for themselves is applied at once (they are the approver).
reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000004';
select is(
  public.claim_shift_swap('50000000-0000-0000-0000-000000000004'),
  'accepted', 'a manager choosing to take a shift themselves is applied directly'
);
select is(
  (select staff_id from public.shifts where id = '40000000-0000-0000-0000-000000000002'),
  '00000000-0000-0000-0000-000000000004'::uuid,
  '...and only then is the manager on the shift'
);

-- ---------------------------------------------------------------------------
-- U2: staff requests
-- ---------------------------------------------------------------------------

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000009';

select throws_ok(
  $$ insert into public.staff_requests (venue_id, kind, title, requested_shift_id)
     values ('20000000-0000-0000-0000-0000000000a1', 'drop_shift', 'Drop',
             '40000000-0000-0000-0000-000000000001') $$,
  '42501', null, 'staff cannot ask to drop someone else''s shift'
);
select throws_ok(
  $$ insert into public.staff_requests (venue_id, kind, title)
     values ('20000000-0000-0000-0000-0000000000a1', 'add_shift', 'Pick up') $$,
  '22023', null, 'a pick-up request must name the shift'
);
select lives_ok(
  $$ insert into public.staff_requests (id, venue_id, kind, title, requested_range_start, requested_range_end)
     values ('60000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-0000000000a1',
             'time_off', 'Time off Sat Oct 24', '2026-10-24', '2026-10-24') $$,
  'staff can request time off'
);

-- Jada now works s1 (22:30-04:30Z); the open busser shift s4 overlaps it.
reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000008';
insert into public.staff_requests (id, venue_id, kind, title, requested_shift_id)
values ('60000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-0000000000a1',
        'add_shift', 'Pick up busser', '40000000-0000-0000-0000-000000000004');

select throws_ok(
  $$ select public.review_staff_request('60000000-0000-0000-0000-000000000002', 'approved') $$,
  '42501', null, 'staff cannot approve their own pick-up through the review RPC'
);

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000004';

select throws_ok(
  $$ select public.review_staff_request('60000000-0000-0000-0000-000000000002', 'approved') $$,
  '23P01', null, 'approving a pick-up that double-books is refused'
);
select lives_ok(
  $$ select public.review_staff_request('60000000-0000-0000-0000-000000000002', 'approved', 'Covering both', true) $$,
  'the manager can approve it with an explicit override'
);
select is(
  (select staff_id from public.shifts where id = '40000000-0000-0000-0000-000000000004'),
  '00000000-0000-0000-0000-000000000008'::uuid,
  'the approved pick-up assigns the open shift'
);
select lives_ok(
  $$ select public.review_staff_request('60000000-0000-0000-0000-000000000001', 'denied', 'Short-staffed') $$,
  'the manager can deny time off'
);
reset role;
select ok(
  (select count(*) from public.notification_events
   where target_user_id = '00000000-0000-0000-0000-000000000009'
     and kind = 'staff_request' and title = 'Request denied'
     and body = 'Time off Sat Oct 24 — Short-staffed') = 1,
  'the requester is told the outcome'
);

select * from finish();
rollback;

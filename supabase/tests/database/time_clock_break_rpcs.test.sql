-- pgTAP tests for start/end break RPCs and attested punch shift_id
-- (20261123160000_time_clock_break_rpcs_and_shift.sql).

begin;
select plan(10);

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-000000000005', 'venue-a1-staff@example.com'),
  ('00000000-0000-0000-0000-000000000008', 'venue-a1-staff-2@example.com');

insert into public.organizations (id, name) values
  ('10000000-0000-0000-0000-00000000000a', 'Org A');

insert into public.venues (id, organization_id, name, latitude, longitude, geofence_radius_m) values
  ('20000000-0000-0000-0000-0000000000a1', '10000000-0000-0000-0000-00000000000a', 'Venue A1', 29.7604, -95.3698, 100);

insert into public.memberships (user_id, organization_id, venue_id, role) values
  ('00000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-0000000000a1', 'staff'),
  ('00000000-0000-0000-0000-000000000008', '10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-0000000000a1', 'staff');

set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000005';
insert into public.time_entries (
  id, organization_id, venue_id, user_id, clock_in_lat, clock_in_lng, clock_in_accuracy_m
) values (
  '80000000-0000-0000-0000-000000000010',
  '10000000-0000-0000-0000-00000000000a',
  '20000000-0000-0000-0000-0000000000a1',
  '00000000-0000-0000-0000-000000000005',
  29.76041, -95.36981, 15.0
);

set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000005';

select lives_ok(
  $$ select public.start_time_entry_break('80000000-0000-0000-0000-000000000010', 'unpaid') $$,
  'staff can start a break via RPC'
);

select ok(
  (select breaks -> 0 ->> 'end_at' is null
     and breaks -> 0 ->> 'type' = 'unpaid'
   from public.time_entries where id = '80000000-0000-0000-0000-000000000010'),
  'RPC opens a single unpaid break'
);

select throws_ok(
  $$ select public.start_time_entry_break('80000000-0000-0000-0000-000000000010', 'paid') $$,
  '42501',
  null,
  'RPC refuses a second open break'
);

select lives_ok(
  $$ select public.end_time_entry_break('80000000-0000-0000-0000-000000000010') $$,
  'staff can end a break via RPC'
);

select ok(
  (select (breaks -> 0 ->> 'end_at') is not null
   from public.time_entries where id = '80000000-0000-0000-0000-000000000010'),
  'RPC closes the open break'
);

select throws_ok(
  $$ select public.end_time_entry_break('80000000-0000-0000-0000-000000000010') $$,
  'P0002',
  null,
  'ending with no open break reports not found'
);

select throws_ok(
  $$ select public.start_time_entry_break('80000000-0000-0000-0000-000000000010', 'sideways') $$,
  '22023',
  null,
  'invalid break type is rejected'
);

-- Another staff member cannot start a break on this entry.
-- SECURITY INVOKER + RLS: the row is invisible, so the RPC raises P0002 (not found)
-- before the ownership check that would raise 42501.
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000008';
select throws_ok(
  $$ select public.start_time_entry_break('80000000-0000-0000-0000-000000000010', 'paid') $$,
  'P0002',
  null,
  'staff cannot start a break on someone else''s entry (RLS hides it as not found)'
);

-- Attested clock-in with optional shift_id (staff 8 has no open entry).
reset role;
insert into public.shifts (
  id, organization_id, venue_id, start_time, end_time, staff_id
) values (
  '90000000-0000-0000-0000-0000000000b1',
  '10000000-0000-0000-0000-00000000000a',
  '20000000-0000-0000-0000-0000000000a1',
  now(), now() + interval '4 hours',
  '00000000-0000-0000-0000-000000000008'
);

set local role service_role;
select lives_ok(
  $$ select public.record_attested_punch(
       '00000000-0000-0000-0000-000000000008'::uuid,
       '20000000-0000-0000-0000-0000000000a1'::uuid,
       'in', 29.7604, -95.3698, 12.0, false, true,
       '90000000-0000-0000-0000-0000000000b1'::uuid
     ) $$,
  'attested clock-in accepts an optional shift_id'
);
reset role;

select results_eq(
  $$ select shift_id, clock_in_attested, punch_source
     from public.time_entries
     where user_id = '00000000-0000-0000-0000-000000000008' and is_open $$,
  $$ values (
       '90000000-0000-0000-0000-0000000000b1'::uuid,
       true,
       'attested'::text
     ) $$,
  'attested punch stores the shift association'
);

select * from finish();
rollback;

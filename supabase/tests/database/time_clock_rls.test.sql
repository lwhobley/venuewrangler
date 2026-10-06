-- pgTAP authorization tests for time_clock (supabase/migrations/20261002220000).
-- Fixture: org A (owner ...002), venue A1 (manager ...004, staff 1 ...005, staff 2 ...008), org B (owner ...006).

begin;
select plan(27);

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-000000000002', 'org-a-owner@example.com'),
  ('00000000-0000-0000-0000-000000000004', 'venue-a1-manager@example.com'),
  ('00000000-0000-0000-0000-000000000005', 'venue-a1-staff@example.com'),
  ('00000000-0000-0000-0000-000000000006', 'org-b-owner@example.com'),
  ('00000000-0000-0000-0000-000000000008', 'venue-a1-staff-2@example.com');

insert into public.organizations (id, name) values
  ('10000000-0000-0000-0000-00000000000a', 'Org A'),
  ('10000000-0000-0000-0000-00000000000b', 'Org B');

-- Venue A1 at (29.7604, -95.3698) [Downtown Houston], geofence 100 metres
insert into public.venues (id, organization_id, name, latitude, longitude, geofence_radius_m) values
  ('20000000-0000-0000-0000-0000000000a1', '10000000-0000-0000-0000-00000000000a', 'Venue A1', 29.7604, -95.3698, 100),
  ('20000000-0000-0000-0000-0000000000b1', '10000000-0000-0000-0000-00000000000b', 'Venue B1', 29.7604, -95.3698, 100);

insert into public.memberships (user_id, organization_id, venue_id, role) values
  ('00000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-00000000000a', null, 'organization_owner'),
  ('00000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-0000000000a1', 'venue_manager'),
  ('00000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-0000000000a1', 'staff'),
  ('00000000-0000-0000-0000-000000000008', '10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-0000000000a1', 'staff'),
  ('00000000-0000-0000-0000-000000000006', '10000000-0000-0000-0000-00000000000b', null, 'organization_owner');

-- ---------------------------------------------------------------------------
-- 1. Haversine distance unit check: distance from self is 0m
-- ---------------------------------------------------------------------------
select is(
  round(app_hidden.haversine_distance_m(29.7604, -95.3698, 29.7604, -95.3698)::numeric, 1),
  0.0::numeric,
  'haversine distance to identical point is 0'
);

-- ---------------------------------------------------------------------------
-- 2. insert: negative (non-member)
-- ---------------------------------------------------------------------------
reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000006';

select throws_ok(
  $$ insert into public.time_entries (venue_id, clock_in_lat, clock_in_lng, clock_in_accuracy_m)
     values ('20000000-0000-0000-0000-0000000000a1', 29.7604, -95.3698, 15.0) $$,
  '42501',
  null,
  'non-member cannot clock in to venue A1'
);

-- ---------------------------------------------------------------------------
-- 3. insert: negative (outside geofence, e.g. Austin at 30.2672, -97.7431)
-- ---------------------------------------------------------------------------
reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000005';

select throws_ok(
  $$ insert into public.time_entries (venue_id, clock_in_lat, clock_in_lng, clock_in_accuracy_m)
     values ('20000000-0000-0000-0000-0000000000a1', 30.2672, -97.7431, 15.0) $$,
  '42501',
  null,
  'clock-in outside geofence fails'
);

-- ---------------------------------------------------------------------------
-- 4. insert: negative (mocked location)
-- ---------------------------------------------------------------------------
select throws_ok(
  $$ insert into public.time_entries (venue_id, clock_in_lat, clock_in_lng, clock_in_accuracy_m, clock_in_mocked)
     values ('20000000-0000-0000-0000-0000000000a1', 29.7604, -95.3698, 15.0, true) $$,
  null,
  null,
  'clock-in with mocked location fails'
);

-- ---------------------------------------------------------------------------
-- 5. insert: positive (inside geofence by staff 1)
-- ---------------------------------------------------------------------------
select lives_ok(
  $$ insert into public.time_entries (id, venue_id, clock_in_lat, clock_in_lng, clock_in_accuracy_m)
     values ('80000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-0000000000a1', 29.76041, -95.36981, 15.0) $$,
  'staff can clock in within venue geofence'
);

-- 6. auto-derived fields
select is(
  (select organization_id from public.time_entries where id = '80000000-0000-0000-0000-000000000001'),
  '10000000-0000-0000-0000-00000000000a'::uuid,
  'organization_id is auto-derived from venue_id'
);

select is(
  (select user_id from public.time_entries where id = '80000000-0000-0000-0000-000000000001'),
  '00000000-0000-0000-0000-000000000005'::uuid,
  'user_id is auto-derived from auth.uid()'
);

-- ---------------------------------------------------------------------------
-- 8. multiple open entries rejected by partial unique index
-- ---------------------------------------------------------------------------
select throws_ok(
  $$ insert into public.time_entries (venue_id, clock_in_lat, clock_in_lng, clock_in_accuracy_m)
     values ('20000000-0000-0000-0000-0000000000a1', 29.76041, -95.36981, 15.0) $$,
  '23505',
  null,
  'cannot create second open time entry while one is active'
);

-- ---------------------------------------------------------------------------
-- 9. select: staff can view own entries
-- ---------------------------------------------------------------------------
select is(
  (select count(*)::integer from public.time_entries where user_id = '00000000-0000-0000-0000-000000000005'),
  1,
  'staff can view own time entry'
);

-- ---------------------------------------------------------------------------
-- 10. select: manager can view all staff entries in venue
-- ---------------------------------------------------------------------------
reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000004';

select is(
  (select count(*)::integer from public.time_entries where venue_id = '20000000-0000-0000-0000-0000000000a1'),
  1,
  'manager can view staff time entries for the venue'
);

-- ---------------------------------------------------------------------------
-- 11. select: org B cannot view venue A1 time entries
-- ---------------------------------------------------------------------------
reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000006';

select is(
  (select count(*)::integer from public.time_entries where id = '80000000-0000-0000-0000-000000000001'),
  0,
  'org B user cannot view time entries from venue A1'
);

-- ---------------------------------------------------------------------------
-- 12. update: staff clocks out successfully within geofence, but a future
-- clock_out_at they supply is ignored and the server's own time is used instead
-- (the fix for the P1: an employee could previously inflate hours this way).
-- ---------------------------------------------------------------------------
reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000005';

select lives_ok(
  $$ update public.time_entries
     set is_open = false,
         clock_out_at = now() + interval '8 hours',
         clock_out_lat = 29.76041,
         clock_out_lng = -95.36981,
         clock_out_accuracy_m = 12.0
     where id = '80000000-0000-0000-0000-000000000001' $$,
  'staff can clock out within venue geofence'
);

select is(
  (select is_open from public.time_entries where id = '80000000-0000-0000-0000-000000000001'),
  false,
  'time entry is now closed'
);

select ok(
  (select clock_out_at < now() + interval '1 minute'
   from public.time_entries where id = '80000000-0000-0000-0000-000000000001'),
  'a client-supplied future clock_out_at is ignored; the server''s own time is used'
);

-- ---------------------------------------------------------------------------
-- 12b. a closed time entry is immutable to ordinary updates, including reopening it
-- ---------------------------------------------------------------------------
select throws_ok(
  $$ update public.time_entries set breaks = '[]'::jsonb
     where id = '80000000-0000-0000-0000-000000000001' $$,
  '42501',
  null,
  'staff cannot edit a closed time entry'
);

select throws_ok(
  $$ update public.time_entries set is_open = true
     where id = '80000000-0000-0000-0000-000000000001' $$,
  '42501',
  null,
  'staff cannot reopen a closed time entry'
);

-- ---------------------------------------------------------------------------
-- 12c. breaks: append-only, server-timestamped, one open at a time
-- ---------------------------------------------------------------------------
reset role;
-- Open a fresh entry for staff 2 to exercise break transitions.
insert into public.time_entries (
  id, organization_id, venue_id, user_id, clock_in_lat, clock_in_lng, clock_in_accuracy_m
) values (
  '80000000-0000-0000-0000-000000000003',
  '10000000-0000-0000-0000-00000000000a',
  '20000000-0000-0000-0000-0000000000a1',
  '00000000-0000-0000-0000-000000000008',
  29.76041, -95.36981, 15.0
);

set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000008';

select lives_ok(
  $$ update public.time_entries
     set breaks = '[{"type":"unpaid","start_at":"2001-01-01T00:00:00Z","end_at":"2001-01-01T01:00:00Z"}]'::jsonb
     where id = '80000000-0000-0000-0000-000000000003' $$,
  'staff can start a break (a forged start/end is overwritten, not rejected)'
);

select ok(
  (select breaks -> 0 ->> 'end_at' is null
   from public.time_entries where id = '80000000-0000-0000-0000-000000000003'),
  'the break''s forged end_at is discarded; the server opens it instead'
);

select throws_ok(
  $$ update public.time_entries
     set breaks = breaks || '[{"type":"paid","start_at":"x","end_at":null}]'::jsonb
     where id = '80000000-0000-0000-0000-000000000003' $$,
  '42501',
  null,
  'staff cannot have two breaks open at once'
);

select lives_ok(
  $$ update public.time_entries
     set breaks = jsonb_set(breaks, '{0,end_at}', to_jsonb(now() + interval '1 hour'))
     where id = '80000000-0000-0000-0000-000000000003' $$,
  'staff can close the open break (a forged future end_at is overwritten)'
);

select ok(
  (select (breaks -> 0 ->> 'end_at')::timestamptz < now() + interval '1 minute'
   from public.time_entries where id = '80000000-0000-0000-0000-000000000003'),
  'the break''s forged future end_at is discarded; the server closes it at now()'
);

select throws_ok(
  $$ update public.time_entries
     set breaks = jsonb_set(breaks, '{0,type}', '"paid"')
     where id = '80000000-0000-0000-0000-000000000003' $$,
  '42501',
  null,
  'staff cannot rewrite a historical break once it is closed'
);

-- ---------------------------------------------------------------------------
-- 12d. public.correct_time_entry: manager-only, audited
-- ---------------------------------------------------------------------------
reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000008';

select throws_ok(
  $$ select public.correct_time_entry('80000000-0000-0000-0000-000000000003', now(), null, 'self-correction attempt') $$,
  '42501',
  null,
  'staff cannot call correct_time_entry on their own punch'
);

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000004';

select lives_ok(
  $$ select public.correct_time_entry('80000000-0000-0000-0000-000000000003', now(), null, 'manager correction') $$,
  'a venue manager can correct a punch via correct_time_entry'
);

select ok(
  (select exists(
     select 1 from public.audit_log
     where target_id = '80000000-0000-0000-0000-000000000003'
       and action = 'time_entry.correct'
   )),
  'the manager correction is written to audit_log'
);

-- ---------------------------------------------------------------------------
-- 14. anti-replay: seed previous day entry, then attempt identical satellite fix
-- ---------------------------------------------------------------------------
reset role;
-- Insert previous day entry directly
insert into public.time_entries (
  id, organization_id, venue_id, user_id,
  clock_in_at, clock_in_lat, clock_in_lng, clock_in_accuracy_m, is_open, clock_out_at
) values (
  '80000000-0000-0000-0000-000000000002',
  '10000000-0000-0000-0000-00000000000a',
  '20000000-0000-0000-0000-0000000000a1',
  '00000000-0000-0000-0000-000000000005',
  now() - interval '2 days',
  29.760455, -95.369855, 5.0, false, now() - interval '2 days' + interval '6 hours'
);

set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000005';

select throws_ok(
  $$ insert into public.time_entries (venue_id, clock_in_lat, clock_in_lng, clock_in_accuracy_m)
     values ('20000000-0000-0000-0000-0000000000a1', 29.760455, -95.369855, 5.0) $$,
  '42501',
  null,
  'identical satellite-grade fix from previous day is rejected as replay'
);

-- ---------------------------------------------------------------------------
-- 15. delete: staff member cannot delete time entries
-- ---------------------------------------------------------------------------
delete from public.time_entries where id = '80000000-0000-0000-0000-000000000001';

select is(
  (select count(*)::integer from public.time_entries where id = '80000000-0000-0000-0000-000000000001'),
  1,
  'staff delete does not affect time entries'
);

select * from finish();
rollback;

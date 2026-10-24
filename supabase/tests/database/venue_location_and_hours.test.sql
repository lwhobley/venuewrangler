-- pgTAP tests for 20261022100000_venue_location_and_hours.sql (launch review S1, D1, U5).
-- Fixture: org A with venue A1 (no location yet) and venue A2 (Chicago, 100 m fence);
-- A1: manager M, supervisor S, staff T and T2; A2: manager M2. Org B: owner X with venue B1.

begin;
select plan(50);

insert into auth.users (id, email) values
  ('e1000000-0000-0000-0000-000000000001', 'm@example.com'),
  ('e1000000-0000-0000-0000-000000000002', 's@example.com'),
  ('e1000000-0000-0000-0000-000000000003', 't@example.com'),
  ('e1000000-0000-0000-0000-000000000004', 't2@example.com'),
  ('e1000000-0000-0000-0000-000000000005', 'm2@example.com'),
  ('e1000000-0000-0000-0000-000000000006', 'x@example.com');
insert into public.profiles (id) values
  ('e1000000-0000-0000-0000-000000000001'), ('e1000000-0000-0000-0000-000000000002'),
  ('e1000000-0000-0000-0000-000000000003'), ('e1000000-0000-0000-0000-000000000004'),
  ('e1000000-0000-0000-0000-000000000005'), ('e1000000-0000-0000-0000-000000000006')
on conflict (id) do nothing;
update public.profiles set display_name = 'Morgan Manager' where id = 'e1000000-0000-0000-0000-000000000001';
update public.profiles set display_name = null where id <> 'e1000000-0000-0000-0000-000000000001'
  and id::text like 'e1000000-%';

insert into public.organizations (id, name) values
  ('e2000000-0000-0000-0000-00000000000a', 'Org A'),
  ('e2000000-0000-0000-0000-00000000000b', 'Org B');
insert into public.venues (id, organization_id, name, timezone) values
  ('e3000000-0000-0000-0000-0000000000a1', 'e2000000-0000-0000-0000-00000000000a', 'Marigold', 'America/Chicago');
insert into public.venues (id, organization_id, name, latitude, longitude, geofence_radius_m) values
  ('e3000000-0000-0000-0000-0000000000a2', 'e2000000-0000-0000-0000-00000000000a', 'Fulton', 41.8864, -87.6483, 100),
  ('e3000000-0000-0000-0000-0000000000b1', 'e2000000-0000-0000-0000-00000000000b', 'Other', 41.8864, -87.6483, 100);
insert into public.memberships (user_id, organization_id, venue_id, role) values
  ('e1000000-0000-0000-0000-000000000001', 'e2000000-0000-0000-0000-00000000000a', 'e3000000-0000-0000-0000-0000000000a1', 'venue_manager'),
  ('e1000000-0000-0000-0000-000000000002', 'e2000000-0000-0000-0000-00000000000a', 'e3000000-0000-0000-0000-0000000000a1', 'supervisor'),
  ('e1000000-0000-0000-0000-000000000003', 'e2000000-0000-0000-0000-00000000000a', 'e3000000-0000-0000-0000-0000000000a1', 'staff'),
  ('e1000000-0000-0000-0000-000000000004', 'e2000000-0000-0000-0000-00000000000a', 'e3000000-0000-0000-0000-0000000000a1', 'staff'),
  ('e1000000-0000-0000-0000-000000000005', 'e2000000-0000-0000-0000-00000000000a', 'e3000000-0000-0000-0000-0000000000a2', 'venue_manager'),
  ('e1000000-0000-0000-0000-000000000006', 'e2000000-0000-0000-0000-00000000000b', null, 'organization_owner');

-- ---------------------------------------------------------------------------
-- S1. A venue without a location refuses self-recorded clock-ins.
-- ---------------------------------------------------------------------------
set local role authenticated;
set local "request.jwt.claim.sub" to 'e1000000-0000-0000-0000-000000000003';
select throws_ok(
  $$ insert into public.time_entries (venue_id, clock_in_lat, clock_in_lng, clock_in_accuracy_m)
     values ('e3000000-0000-0000-0000-0000000000a1', 43.0389, -87.9065, 12.0) $$,
  '42501', 'venue_location_required',
  'staff cannot clock in from anywhere at a venue with no location');

reset role;
update public.venues set latitude = 0, longitude = 0 where id = 'e3000000-0000-0000-0000-0000000000a1';
set local role authenticated;
set local "request.jwt.claim.sub" to 'e1000000-0000-0000-0000-000000000003';
select throws_ok(
  $$ insert into public.time_entries (venue_id, clock_in_lat, clock_in_lng, clock_in_accuracy_m)
     values ('e3000000-0000-0000-0000-0000000000a1', 43.0389, -87.9065, 12.0) $$,
  '42501', 'venue_location_required',
  'a (0, 0) venue location counts as no location');

reset role;
select throws_ok(
  $$ select public.record_attested_punch('e1000000-0000-0000-0000-000000000003',
       'e3000000-0000-0000-0000-0000000000a1', 'in', 43.0389, -87.9065, 12.0, false, true) $$,
  '42501', 'venue_location_required',
  'the attested (Edge Function) path refuses it too');

-- ---------------------------------------------------------------------------
-- S1. set_venue_location: managers of the venue only, validated, audited.
-- ---------------------------------------------------------------------------
set local role authenticated;
set local "request.jwt.claim.sub" to 'e1000000-0000-0000-0000-000000000003';
select throws_ok(
  $$ select public.set_venue_location('e3000000-0000-0000-0000-0000000000a1', 43.0389, -87.9065, 100, 'Home') $$,
  '42501', null, 'staff cannot move the venue to where they are');

set local "request.jwt.claim.sub" to 'e1000000-0000-0000-0000-000000000002';
select throws_ok(
  $$ select public.set_venue_location('e3000000-0000-0000-0000-0000000000a1', 43.0389, -87.9065, 100, null) $$,
  '42501', null, 'supervisors cannot set the venue location');

set local "request.jwt.claim.sub" to 'e1000000-0000-0000-0000-000000000005';
select throws_ok(
  $$ select public.set_venue_location('e3000000-0000-0000-0000-0000000000a1', 43.0389, -87.9065, 100, null) $$,
  '42501', null, 'a manager of another venue in the organization cannot set it');

set local "request.jwt.claim.sub" to 'e1000000-0000-0000-0000-000000000006';
select throws_ok(
  $$ select public.set_venue_location('e3000000-0000-0000-0000-0000000000a1', 43.0389, -87.9065, 100, null) $$,
  '42501', null, 'an owner of another organization cannot set it');

set local "request.jwt.claim.sub" to 'e1000000-0000-0000-0000-000000000001';
select throws_ok(
  $$ select public.set_venue_location('e3000000-0000-0000-0000-0000000000a1', 91, -87.6, 100, null) $$,
  '22023', null, 'an out-of-range latitude is rejected');
select throws_ok(
  $$ select public.set_venue_location('e3000000-0000-0000-0000-0000000000a1', 0, 0, 100, null) $$,
  '22023', null, '(0, 0) is rejected');
select throws_ok(
  $$ select public.set_venue_location('e3000000-0000-0000-0000-0000000000a1', 41.8781, -87.6298, 20, null) $$,
  '22023', null, 'a fence smaller than the accepted GPS accuracy is rejected');
select throws_ok(
  $$ select public.set_venue_location('e3000000-0000-0000-0000-0000000000a1', 41.8781, -87.6298, 5000, null) $$,
  '22023', null, 'a fence over 1 km is rejected');
select lives_ok(
  $$ select public.set_venue_location('e3000000-0000-0000-0000-0000000000a1', 41.8781, -87.6298, 150,
       '  123 W Marigold St, Chicago  ') $$,
  'the venue manager sets the location');

reset role;
select results_eq(
  $$ select latitude, longitude, geofence_radius_m, address from public.venues
     where id = 'e3000000-0000-0000-0000-0000000000a1' $$,
  $$ values (41.8781::double precision, -87.6298::double precision, 150, '123 W Marigold St, Chicago'::text) $$,
  'location, radius and trimmed address are stored');
select ok(
  exists (select 1 from public.audit_log
          where action = 'venue.update' and target_id = 'e3000000-0000-0000-0000-0000000000a1'
            and actor_user_id = 'e1000000-0000-0000-0000-000000000001'
            and metadata ? 'latitude' and metadata ? 'address'),
  'the change is audited with who made it and the old/new values');

-- Org owners/admins can still set it, as they could update the row before.
insert into auth.users (id, email) values ('e1000000-0000-0000-0000-000000000007', 'owner@example.com');
insert into public.profiles (id) values ('e1000000-0000-0000-0000-000000000007') on conflict (id) do nothing;
insert into public.memberships (user_id, organization_id, venue_id, role) values
  ('e1000000-0000-0000-0000-000000000007', 'e2000000-0000-0000-0000-00000000000a', null, 'organization_owner');
set local role authenticated;
set local "request.jwt.claim.sub" to 'e1000000-0000-0000-0000-000000000007';
select lives_ok(
  $$ select public.set_venue_location('e3000000-0000-0000-0000-0000000000a2', 41.8864, -87.6483, 100, null) $$,
  'an organization owner can set any venue location in the organization');

-- ---------------------------------------------------------------------------
-- S1. Once set, the geofence applies.
-- ---------------------------------------------------------------------------
set local "request.jwt.claim.sub" to 'e1000000-0000-0000-0000-000000000003';
select throws_ok(
  $$ insert into public.time_entries (venue_id, clock_in_lat, clock_in_lng, clock_in_accuracy_m)
     values ('e3000000-0000-0000-0000-0000000000a1', 43.0389, -87.9065, 12.0) $$,
  '42501', 'You are outside the venue geofence',
  'a clock-in 130 km away (Milwaukee) is refused');
select lives_ok(
  $$ insert into public.time_entries (id, venue_id, clock_in_lat, clock_in_lng, clock_in_accuracy_m)
     values ('e5000000-0000-0000-0000-000000000001', 'e3000000-0000-0000-0000-0000000000a1', 41.8782, -87.6299, 12.0) $$,
  'a clock-in at the venue is accepted');

-- An entry opened before the location was cleared can still be closed.
reset role;
set local "request.jwt.claim.sub" to 'e1000000-0000-0000-0000-000000000004';
insert into public.time_entries (id, venue_id, clock_in_lat, clock_in_lng, clock_in_accuracy_m)
  values ('e5000000-0000-0000-0000-000000000002', 'e3000000-0000-0000-0000-0000000000a1', 41.87815, -87.62985, 14.0);
update public.venues set latitude = null, longitude = null where id = 'e3000000-0000-0000-0000-0000000000a1';
set local role authenticated;
set local "request.jwt.claim.sub" to 'e1000000-0000-0000-0000-000000000004';
select lives_ok(
  $$ update public.time_entries set is_open = false, clock_out_lat = 41.8782, clock_out_lng = -87.6299,
       clock_out_accuracy_m = 12.0 where id = 'e5000000-0000-0000-0000-000000000002' $$,
  'clock-out is not blocked at a venue whose location is unset');
reset role;
select is((select is_open from public.time_entries where id = 'e5000000-0000-0000-0000-000000000002'), false,
  '...and the entry is closed');
update public.venues set latitude = 41.8781, longitude = -87.6298 where id = 'e3000000-0000-0000-0000-0000000000a1';

-- T2 forgets to clock out of a new punch, with a break still open.
set local "request.jwt.claim.sub" to 'e1000000-0000-0000-0000-000000000004';
insert into public.time_entries (id, venue_id, clock_in_lat, clock_in_lng, clock_in_accuracy_m)
  values ('e5000000-0000-0000-0000-000000000003', 'e3000000-0000-0000-0000-0000000000a1', 41.87816, -87.62986, 14.0);
-- Backdate it (and its break) as if it started 10 hours ago.
set local "app.time_entry_correction" to 'on';
update public.time_entries set breaks = jsonb_build_array(jsonb_build_object(
    'type', 'unpaid', 'start_at', now() - interval '5 hours', 'end_at', null))
  where id = 'e5000000-0000-0000-0000-000000000003';
set local "app.time_entry_correction" to 'off';
alter table public.time_entries disable trigger user;
update public.time_entries set clock_in_at = now() - interval '10 hours'
  where id = 'e5000000-0000-0000-0000-000000000003';
alter table public.time_entries enable trigger user;

-- ---------------------------------------------------------------------------
-- D1. Only managers of the venue can correct someone else's punch, with a reason.
-- ---------------------------------------------------------------------------
set local role authenticated;
set local "request.jwt.claim.sub" to 'e1000000-0000-0000-0000-000000000003';
select throws_ok(
  $$ select public.correct_time_entry('e5000000-0000-0000-0000-000000000003', now() - interval '2 hours', null, 'Closing for a teammate') $$,
  '42501', null, 'staff cannot correct a teammate''s punch');
select is_empty(
  $$ update public.time_entries set is_open = false, clock_out_lat = 41.8782, clock_out_lng = -87.6299,
       clock_out_accuracy_m = 12 where id = 'e5000000-0000-0000-0000-000000000003' returning id $$,
  'staff cannot close a teammate''s punch directly either');

set local "request.jwt.claim.sub" to 'e1000000-0000-0000-0000-000000000002';
select throws_ok(
  $$ select public.correct_time_entry('e5000000-0000-0000-0000-000000000003', now() - interval '2 hours', null, 'Supervisor fix') $$,
  '42501', null, 'supervisors cannot correct punches');

set local "request.jwt.claim.sub" to 'e1000000-0000-0000-0000-000000000005';
select throws_ok(
  $$ select public.correct_time_entry('e5000000-0000-0000-0000-000000000003', now() - interval '2 hours', null, 'Other venue fix') $$,
  '42501', null, 'a manager of another venue cannot correct this venue''s punches');

set local "request.jwt.claim.sub" to 'e1000000-0000-0000-0000-000000000006';
select throws_ok(
  $$ select public.correct_time_entry('e5000000-0000-0000-0000-000000000003', now() - interval '2 hours', null, 'Other org fix') $$,
  '42501', null, 'an owner of another organization cannot correct it');

set local "request.jwt.claim.sub" to 'e1000000-0000-0000-0000-000000000001';
select throws_ok(
  $$ select public.correct_time_entry('e5000000-0000-0000-0000-000000000003', now() - interval '2 hours', null, '  ') $$,
  '22023', null, 'a correction without a reason is refused');
select throws_ok(
  $$ select public.correct_time_entry('e5000000-0000-0000-0000-000000000003', null, null, 'Nothing') $$,
  '22023', null, 'a correction that changes nothing is refused');
select lives_ok(
  $$ select public.correct_time_entry('e5000000-0000-0000-0000-000000000003', now() - interval '2 hours', null,
       'Forgot to clock out; left at close') $$,
  'the venue manager closes the missed clock-out');

reset role;
select ok(
  (select not is_open and clock_out_at = now() - interval '2 hours'
     from public.time_entries where id = 'e5000000-0000-0000-0000-000000000003'),
  'the entry is closed at the corrected time');
select is(
  (select (breaks -> 0 ->> 'end_at')::timestamptz from public.time_entries where id = 'e5000000-0000-0000-0000-000000000003'),
  now() - interval '2 hours',
  'its open break ends at the corrected clock-out');
select ok(
  exists (select 1 from public.audit_log
          where action = 'time_entry.correct' and target_id = 'e5000000-0000-0000-0000-000000000003'
            and actor_user_id = 'e1000000-0000-0000-0000-000000000001'
            and metadata ->> 'reason' = 'Forgot to clock out; left at close'
            and metadata -> 'before' ->> 'clock_out_at' is null
            and (metadata -> 'before' ->> 'is_open')::boolean
            and metadata -> 'after' ->> 'clock_out_at' is not null
            and not (metadata -> 'before' ? 'clock_in_lat')),
  'the audit trail keeps who, why, and the original value (without GPS)');

-- ---------------------------------------------------------------------------
-- D1. Timesheet: managers only, with names and the correction history.
-- ---------------------------------------------------------------------------
insert into public.employee_hr_profiles (venue_id, user_id, legal_name, preferred_name) values
  ('e3000000-0000-0000-0000-0000000000a1', 'e1000000-0000-0000-0000-000000000004', 'Camila Reyes', 'Camila'),
  ('e3000000-0000-0000-0000-0000000000a1', 'e1000000-0000-0000-0000-000000000003', 'Marcus Lee', null);

set local role authenticated;
set local "request.jwt.claim.sub" to 'e1000000-0000-0000-0000-000000000001';
select results_eq(
  $$ select display_name, is_open, jsonb_array_length(corrections)
     from public.venue_timesheet('e3000000-0000-0000-0000-0000000000a1', now() - interval '1 day', now() + interval '1 minute')
     order by clock_in_at $$,
  $$ values ('Camila'::text, false, 1), ('Marcus Lee'::text, true, 0), ('Camila'::text, false, 0) $$,
  'the manager sees each punch by name, with its corrections');
select is(
  (select corrections -> 0 ->> 'corrected_by_name'
     from public.venue_timesheet('e3000000-0000-0000-0000-0000000000a1', now() - interval '1 day', now())
    where time_entry_id = 'e5000000-0000-0000-0000-000000000003'),
  'Morgan Manager',
  'the correction names the manager who made it');
select is(
  (select corrections -> 0 ->> 'reason'
     from public.venue_timesheet('e3000000-0000-0000-0000-0000000000a1', now() - interval '1 day', now())
    where time_entry_id = 'e5000000-0000-0000-0000-000000000003'),
  'Forgot to clock out; left at close',
  'the correction carries its reason');
select is(
  (select count(*)::int from public.venue_timesheet('e3000000-0000-0000-0000-0000000000a1',
     now() + interval '1 hour', now() + interval '2 hours')),
  1,
  'a punch still open from before the range is listed so it can be closed');
select throws_ok(
  $$ select * from public.venue_timesheet('e3000000-0000-0000-0000-0000000000a1', now() - interval '120 days', now()) $$,
  '22023', null, 'ranges over 93 days are refused');

set local "request.jwt.claim.sub" to 'e1000000-0000-0000-0000-000000000003';
select throws_ok(
  $$ select * from public.venue_timesheet('e3000000-0000-0000-0000-0000000000a1', now() - interval '1 day', now()) $$,
  '42501', null, 'staff cannot read the venue timesheet');
set local "request.jwt.claim.sub" to 'e1000000-0000-0000-0000-000000000002';
select throws_ok(
  $$ select * from public.venue_timesheet('e3000000-0000-0000-0000-0000000000a1', now() - interval '1 day', now()) $$,
  '42501', null, 'supervisors cannot read the venue timesheet');
set local "request.jwt.claim.sub" to 'e1000000-0000-0000-0000-000000000005';
select throws_ok(
  $$ select * from public.venue_timesheet('e3000000-0000-0000-0000-0000000000a1', now() - interval '1 day', now()) $$,
  '42501', null, 'a manager of another venue cannot read it');
set local "request.jwt.claim.sub" to 'e1000000-0000-0000-0000-000000000006';
select throws_ok(
  $$ select * from public.venue_timesheet('e3000000-0000-0000-0000-0000000000a1', now() - interval '1 day', now()) $$,
  '42501', null, 'an owner of another organization cannot read it');

-- ---------------------------------------------------------------------------
-- D1. Clock board: supervisors and up, by name.
-- ---------------------------------------------------------------------------
set local "request.jwt.claim.sub" to 'e1000000-0000-0000-0000-000000000002';
select results_eq(
  $$ select display_name from public.venue_clock_board('e3000000-0000-0000-0000-0000000000a1') $$,
  $$ values ('Marcus Lee'::text) $$,
  'a supervisor sees who is on the clock, by name');
set local "request.jwt.claim.sub" to 'e1000000-0000-0000-0000-000000000003';
select throws_ok(
  $$ select * from public.venue_clock_board('e3000000-0000-0000-0000-0000000000a1') $$,
  '42501', null, 'staff cannot read the clock board');
set local "request.jwt.claim.sub" to 'e1000000-0000-0000-0000-000000000006';
select throws_ok(
  $$ select * from public.venue_clock_board('e3000000-0000-0000-0000-0000000000a1') $$,
  '42501', null, 'another organization cannot read the clock board');

-- ---------------------------------------------------------------------------
-- U5. The staff-profile name is used wherever members are listed.
-- ---------------------------------------------------------------------------
set local "request.jwt.claim.sub" to 'e1000000-0000-0000-0000-000000000001';
select is(
  (select display_name from public.venue_roster('e3000000-0000-0000-0000-0000000000a1')
    where user_id = 'e1000000-0000-0000-0000-000000000004'),
  'Camila', 'venue_roster uses the preferred name from the staff profile');
select is(
  (select display_name from public.team_members('e3000000-0000-0000-0000-0000000000a1')
    where user_id = 'e1000000-0000-0000-0000-000000000003'),
  'Marcus Lee', 'team_members falls back to the legal name');
select is(
  (select display_name from public.chat_contacts('e3000000-0000-0000-0000-0000000000a1')
    where user_id = 'e1000000-0000-0000-0000-000000000004'),
  'Camila', 'chat_contacts uses it');
set local "request.jwt.claim.sub" to 'e1000000-0000-0000-0000-000000000003';
select is(
  (select display_name from public.venue_schedule_roster('e3000000-0000-0000-0000-0000000000a1')
    where user_id = 'e1000000-0000-0000-0000-000000000004'),
  'Camila', 'venue_schedule_roster (staff-visible) uses it');

reset role;
update public.profiles set display_name = 'Cami R.' where id = 'e1000000-0000-0000-0000-000000000004';
set local role authenticated;
set local "request.jwt.claim.sub" to 'e1000000-0000-0000-0000-000000000003';
select is(
  (select display_name from public.venue_schedule_roster('e3000000-0000-0000-0000-0000000000a1')
    where user_id = 'e1000000-0000-0000-0000-000000000004'),
  'Cami R.', 'the person''s own display name wins once they set one');

-- A name recorded on the accepted invite (whatever the column is called) is picked up too.
reset role;
alter table public.invites add column if not exists full_name text;
insert into public.invites (organization_id, venue_id, email, role, status, full_name, invited_by)
  values ('e2000000-0000-0000-0000-00000000000a', 'e3000000-0000-0000-0000-0000000000a1', 's@example.com',
          'supervisor', 'accepted', 'Sam Supervisor', 'e1000000-0000-0000-0000-000000000001');
set local role authenticated;
set local "request.jwt.claim.sub" to 'e1000000-0000-0000-0000-000000000003';
select is(
  (select display_name from public.chat_contacts('e3000000-0000-0000-0000-0000000000a1')
    where user_id = 'e1000000-0000-0000-0000-000000000002'),
  'Sam Supervisor', 'a name stored on the accepted invite is used when nothing else is set');
select is(
  (select display_name from public.chat_contacts('e3000000-0000-0000-0000-0000000000a1')
    where user_id = 'e1000000-0000-0000-0000-000000000001'),
  'Morgan Manager', 'members with a display name are unchanged');

reset role;
select ok(
  not has_function_privilege('authenticated', 'app_hidden.member_display_name(uuid, uuid)', 'execute'),
  'the name helper is not callable by clients directly');

select * from finish();
rollback;

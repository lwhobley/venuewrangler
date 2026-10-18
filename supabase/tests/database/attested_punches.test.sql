-- pgTAP tests for attested time punches (20261017130000_attested_punches.sql).
-- Fixture: org A venue A1 (geofence 100 m) with manager M, staff T and staff T2; outsider X in org B.

begin;
select plan(37);

insert into auth.users (id, email) values
  ('d1000000-0000-0000-0000-000000000001', 'm@example.com'),
  ('d1000000-0000-0000-0000-000000000002', 't@example.com'),
  ('d1000000-0000-0000-0000-000000000003', 't2@example.com'),
  ('d1000000-0000-0000-0000-000000000004', 'x@example.com');

insert into public.organizations (id, name) values
  ('d2000000-0000-0000-0000-00000000000a', 'Org A'),
  ('d2000000-0000-0000-0000-00000000000b', 'Org B');
insert into public.venues (id, organization_id, name, latitude, longitude, geofence_radius_m) values
  ('d3000000-0000-0000-0000-0000000000a1', 'd2000000-0000-0000-0000-00000000000a', 'Venue A1', 29.7604, -95.3698, 100),
  ('d3000000-0000-0000-0000-0000000000b1', 'd2000000-0000-0000-0000-00000000000b', 'Venue B1', 29.7604, -95.3698, 100);
insert into public.memberships (user_id, organization_id, venue_id, role) values
  ('d1000000-0000-0000-0000-000000000001', 'd2000000-0000-0000-0000-00000000000a', 'd3000000-0000-0000-0000-0000000000a1', 'venue_manager'),
  ('d1000000-0000-0000-0000-000000000002', 'd2000000-0000-0000-0000-00000000000a', 'd3000000-0000-0000-0000-0000000000a1', 'staff'),
  ('d1000000-0000-0000-0000-000000000003', 'd2000000-0000-0000-0000-00000000000a', 'd3000000-0000-0000-0000-0000000000a1', 'staff'),
  ('d1000000-0000-0000-0000-000000000004', 'd2000000-0000-0000-0000-00000000000b', null, 'organization_owner');

-- ---------------------------------------------------------------------------
-- Default (observe) mode: direct punches still work and are marked unattested.
-- ---------------------------------------------------------------------------
set local role authenticated;
set local "request.jwt.claim.sub" to 'd1000000-0000-0000-0000-000000000002';

select lives_ok(
  $$ insert into public.time_entries (id, venue_id, clock_in_lat, clock_in_lng, clock_in_accuracy_m,
                                       clock_in_attested, clock_out_attested, punch_source)
     values ('d5000000-0000-0000-0000-000000000001', 'd3000000-0000-0000-0000-0000000000a1',
             29.7604, -95.3698, 15.0, true, true, 'attested') $$,
  'a direct clock-in works while attestation is not required');

reset role;
select results_eq(
  $$ select clock_in_attested, clock_out_attested, punch_source from public.time_entries
     where id = 'd5000000-0000-0000-0000-000000000001' $$,
  $$ values (false, false, 'direct'::text) $$,
  'client-supplied attestation flags are ignored: the punch is stamped unattested/direct');

set local role authenticated;
set local "request.jwt.claim.sub" to 'd1000000-0000-0000-0000-000000000002';
select lives_ok(
  $$ update public.time_entries set clock_in_attested = true, punch_source = 'attested'
       where id = 'd5000000-0000-0000-0000-000000000001' $$,
  'a client update touching the flags does not error...');
select lives_ok(
  $$ update public.time_entries set is_open = false, clock_out_lat = 29.7604, clock_out_lng = -95.3698,
       clock_out_accuracy_m = 15.0, clock_out_attested = true
     where id = 'd5000000-0000-0000-0000-000000000001' $$,
  'a direct clock-out works while attestation is not required');
reset role;
select results_eq(
  $$ select clock_in_attested, clock_out_attested, punch_source from public.time_entries
     where id = 'd5000000-0000-0000-0000-000000000001' $$,
  $$ values (false, false, 'direct'::text) $$,
  '...but the flags are unchanged and the close is unattested');

-- ---------------------------------------------------------------------------
-- record_attested_punch (service role): attested in/out, membership check, flags.
-- ---------------------------------------------------------------------------
set local role service_role;
select lives_ok(
  $$ select public.record_attested_punch('d1000000-0000-0000-0000-000000000003', 'd3000000-0000-0000-0000-0000000000a1',
       'in', 29.7604, -95.3698, 12.0, false, true) $$,
  'an attested clock-in is recorded for the verified user');
reset role;
select results_eq(
  $$ select user_id, clock_in_attested, clock_out_attested, punch_source, is_open
     from public.time_entries where user_id = 'd1000000-0000-0000-0000-000000000003' $$,
  $$ values ('d1000000-0000-0000-0000-000000000003'::uuid, true, false, 'attested'::text, true) $$,
  'the entry belongs to the user and is marked attested/open');

set local role service_role;
select lives_ok(
  $$ select public.record_attested_punch('d1000000-0000-0000-0000-000000000003', 'd3000000-0000-0000-0000-0000000000a1',
       'out', 29.7604, -95.3698, 12.0, false, true) $$,
  'an attested clock-out closes the open punch');
reset role;
select results_eq(
  $$ select clock_in_attested, clock_out_attested, is_open from public.time_entries
     where user_id = 'd1000000-0000-0000-0000-000000000003' $$,
  $$ values (true, true, false) $$,
  'both ends are attested');

set local role service_role;
select throws_ok(
  $$ select public.record_attested_punch('d1000000-0000-0000-0000-000000000004', 'd3000000-0000-0000-0000-0000000000a1',
       'in', 29.7604, -95.3698, 12.0, false, true) $$,
  '42501', null, 'a non-member cannot be punched in, even with a valid attestation');
select throws_ok(
  $$ select public.record_attested_punch('d1000000-0000-0000-0000-000000000003', 'd3000000-0000-0000-0000-0000000000a1',
       'in', 30.2672, -97.7431, 12.0, false, true) $$,
  '42501', null, 'the geofence still applies to attested punches');
select throws_ok(
  $$ select public.record_attested_punch('d1000000-0000-0000-0000-000000000003', 'd3000000-0000-0000-0000-0000000000a1',
       'out', 29.7604, -95.3698, 12.0, false, true) $$,
  'P0002', null, 'closing with no open punch reports not found');
select throws_ok(
  $$ select public.record_attested_punch('d1000000-0000-0000-0000-000000000003', 'd3000000-0000-0000-0000-0000000000a1',
       'in', 29.7604, -95.3698, 80.0, false, true) $$,
  '42501', null, 'the accuracy limit still applies to attested punches');
reset role;
select is(current_setting('app.attested_punch', true), 'off', 'the attested flag is reset after each call');

-- ---------------------------------------------------------------------------
-- Enforcement flag: self-recorded punches must be attested.
-- ---------------------------------------------------------------------------
update app_hidden.platform_settings set require_attested_punches = true;

set local role authenticated;
set local "request.jwt.claim.sub" to 'd1000000-0000-0000-0000-000000000003';
select throws_ok(
  $$ insert into public.time_entries (venue_id, clock_in_lat, clock_in_lng, clock_in_accuracy_m)
     values ('d3000000-0000-0000-0000-0000000000a1', 29.7604, -95.3698, 12.0) $$,
  '42501', null, 'with enforcement on, a direct self clock-in is refused');

reset role;
set local role service_role;
select lives_ok(
  $$ select public.record_attested_punch('d1000000-0000-0000-0000-000000000003', 'd3000000-0000-0000-0000-0000000000a1',
       'in', 29.7604, -95.3698, 12.0, false, true) $$,
  'with enforcement on, the attested path still works');
reset role;

set local role authenticated;
set local "request.jwt.claim.sub" to 'd1000000-0000-0000-0000-000000000003';
select throws_ok(
  $$ update public.time_entries set is_open = false, clock_out_lat = 29.7604, clock_out_lng = -95.3698,
       clock_out_accuracy_m = 12.0
     where user_id = 'd1000000-0000-0000-0000-000000000003' and is_open $$,
  '42501', null, 'with enforcement on, a direct self clock-out is refused');

-- Managers acting on someone else's behalf are exempt (walk-in punch, remote close).
set local "request.jwt.claim.sub" to 'd1000000-0000-0000-0000-000000000001';
select lives_ok(
  $$ update public.time_entries set is_open = false
     where user_id = 'd1000000-0000-0000-0000-000000000003' and is_open $$,
  'a manager can still remote-close a team member''s punch');
select lives_ok(
  $$ insert into public.time_entries (venue_id, user_id, clock_in_lat, clock_in_lng, clock_in_accuracy_m)
     values ('d3000000-0000-0000-0000-0000000000a1', 'd1000000-0000-0000-0000-000000000002', 29.7604, -95.3698, 12.0) $$,
  'a manager can still record a walk-in punch for staff');
reset role;
select results_eq(
  $$ select punch_source, clock_in_attested from public.time_entries
     where user_id = 'd1000000-0000-0000-0000-000000000002' and is_open $$,
  $$ values ('direct'::text, false) $$,
  'manager-entered punches are marked direct/unattested for review');

update app_hidden.platform_settings set require_attested_punches = false;

-- ---------------------------------------------------------------------------
-- Corrections cannot flip attestation flags.
-- ---------------------------------------------------------------------------
set local role authenticated;
set local "request.jwt.claim.sub" to 'd1000000-0000-0000-0000-000000000001';
select lives_ok(
  $$ select public.correct_time_entry(
       (select id from public.time_entries where user_id = 'd1000000-0000-0000-0000-000000000003' and not clock_out_attested limit 1),
       now() + interval '30 seconds', null, 'fix') $$,
  'a manager correction goes through');
reset role;
select is(
  (select bool_or(clock_out_attested) from public.time_entries
    where user_id = 'd1000000-0000-0000-0000-000000000003' and clock_in_attested and not clock_out_attested),
  false,
  'a manager correction does not mark a punch as attested');

-- ---------------------------------------------------------------------------
-- Nonces, counters, key registry
-- ---------------------------------------------------------------------------
set local role service_role;
select lives_ok(
  $$ select public.issue_punch_nonce('d1000000-0000-0000-0000-000000000002', repeat('a', 64)) $$,
  'a punch nonce is issued');
select is((select public.consume_punch_nonce('d1000000-0000-0000-0000-000000000002', repeat('a', 64))), true,
  'a nonce is consumed once...');
select is((select public.consume_punch_nonce('d1000000-0000-0000-0000-000000000002', repeat('a', 64))), false,
  '...and never again (replay)');
select lives_ok(
  $$ select public.issue_punch_nonce('d1000000-0000-0000-0000-000000000002', repeat('b', 64)) $$,
  'a second nonce is issued');
select is((select public.consume_punch_nonce('d1000000-0000-0000-0000-000000000003', repeat('b', 64))), false,
  'another user cannot consume the nonce');
reset role;
update public.punch_nonces set expires_at = now() - interval '1 second' where nonce_hash = repeat('b', 64);
set local role service_role;
select is((select public.consume_punch_nonce('d1000000-0000-0000-0000-000000000002', repeat('b', 64))), false,
  'an expired nonce is refused');

select lives_ok(
  $$ select public.register_attestation_key('d1000000-0000-0000-0000-000000000002', 'ios', 'key-1', 'c3BraQ==') $$,
  'an attested key is registered');
select is((select public.advance_attestation_counter('d1000000-0000-0000-0000-000000000002', 'ios', 'key-1', 5)), true,
  'the counter advances');
select is((select public.advance_attestation_counter('d1000000-0000-0000-0000-000000000002', 'ios', 'key-1', 5)), false,
  'the same counter value is refused (replay)');
select is((select public.advance_attestation_counter('d1000000-0000-0000-0000-000000000002', 'ios', 'key-1', 3)), false,
  'a lower counter is refused');
select lives_ok(
  $$ select public.register_attestation_key('d1000000-0000-0000-0000-000000000002', 'ios', 'key-1', 'bmV3a2V5') $$,
  're-attesting the same key succeeds...');
select is((select counter from public.device_attestation_keys where key_id = 'key-1'), 5::bigint,
  '...without resetting the counter');
reset role;

-- Clients cannot touch the new tables or functions.
set local role authenticated;
set local "request.jwt.claim.sub" to 'd1000000-0000-0000-0000-000000000002';
select throws_ok($$ select * from public.device_attestation_keys $$, '42501', null, 'clients cannot read attested keys');
select throws_ok($$ select * from public.punch_nonces $$, '42501', null, 'clients cannot read punch nonces');
select throws_ok(
  $$ select public.record_attested_punch('d1000000-0000-0000-0000-000000000002', 'd3000000-0000-0000-0000-0000000000a1',
       'in', 29.7604, -95.3698, 12.0, false, true) $$,
  '42501', null, 'clients cannot call record_attested_punch directly');
reset role;

select * from finish();
rollback;

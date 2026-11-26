-- pgTAP tests for supabase/migrations/20261125120000_security_review_fixes.sql (F04, F08, F13, F14; F02 regression check).
begin;
select plan(16);

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000000b2', 'owner@example.com'),
  ('00000000-0000-0000-0000-0000000000b4', 'manager@example.com'),
  ('00000000-0000-0000-0000-0000000000b5', 'staff@example.com'),
  ('00000000-0000-0000-0000-0000000000b8', 'supervisor@example.com');

insert into public.organizations (id, name) values ('10000000-0000-0000-0000-0000000000bb', 'Org');
insert into public.venues (id, organization_id, name, latitude, longitude, geofence_radius_m) values
  ('20000000-0000-0000-0000-0000000000b1', '10000000-0000-0000-0000-0000000000bb', 'Mapped', 29.7604, -95.3698, 100);
insert into public.venues (id, organization_id, name) values
  ('20000000-0000-0000-0000-0000000000b2', '10000000-0000-0000-0000-0000000000bb', 'Unmapped');

insert into public.memberships (user_id, organization_id, venue_id, role) values
  ('00000000-0000-0000-0000-0000000000b2', '10000000-0000-0000-0000-0000000000bb', null, 'organization_owner'),
  ('00000000-0000-0000-0000-0000000000b4', '10000000-0000-0000-0000-0000000000bb', '20000000-0000-0000-0000-0000000000b1', 'venue_manager'),
  ('00000000-0000-0000-0000-0000000000b5', '10000000-0000-0000-0000-0000000000bb', '20000000-0000-0000-0000-0000000000b1', 'staff'),
  ('00000000-0000-0000-0000-0000000000b5', '10000000-0000-0000-0000-0000000000bb', '20000000-0000-0000-0000-0000000000b2', 'staff'),
  ('00000000-0000-0000-0000-0000000000b8', '10000000-0000-0000-0000-0000000000bb', '20000000-0000-0000-0000-0000000000b1', 'supervisor');

-- The HR guard trigger only lets a manager set employment details, so seed as the venue manager.
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-0000000000b4';
insert into public.employee_hr_profiles (venue_id, user_id, hourly_rate_cents) values
  ('20000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000b5', 1500);
reset role;

insert into public.floor_plans (id, venue_id, name) values
  ('50000000-0000-0000-0000-0000000000b1', '20000000-0000-0000-0000-0000000000b1', 'Main');
insert into public.floor_tables (id, floor_plan_id, venue_id, label, capacity) values
  ('51000000-0000-0000-0000-0000000000b1', '50000000-0000-0000-0000-0000000000b1', '20000000-0000-0000-0000-0000000000b1', 'T1', 4),
  ('51000000-0000-0000-0000-0000000000b2', '50000000-0000-0000-0000-0000000000b1', '20000000-0000-0000-0000-0000000000b1', 'T2', 4);

-- ---------------------------------------------------------------------------
-- F02 (already enforced by app_hidden.require_clock_in_location): no punches without a geofence
-- ---------------------------------------------------------------------------
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-0000000000b5';

select throws_ok(
  $$ insert into public.time_entries (venue_id, clock_in_lat, clock_in_lng, clock_in_accuracy_m)
     values ('20000000-0000-0000-0000-0000000000b2', 29.7604, -95.3698, 10.0) $$,
  '42501', null,
  'a punch at a venue with no coordinates is refused'
);
select lives_ok(
  $$ insert into public.time_entries (venue_id, clock_in_lat, clock_in_lng, clock_in_accuracy_m)
     values ('20000000-0000-0000-0000-0000000000b1', 29.7604, -95.3698, 10.0) $$,
  'a punch inside a mapped venue''s geofence still works'
);
reset role;

-- ---------------------------------------------------------------------------
-- F04: MFA for wage edits and the caller_mfa_satisfied RPC
-- ---------------------------------------------------------------------------
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-0000000000b4';
select is(public.caller_mfa_satisfied(), true, 'with the MFA switch off, every caller passes');
select lives_ok(
  $$ update public.employee_hr_profiles set hourly_rate_cents = 1600
     where user_id = '00000000-0000-0000-0000-0000000000b5' $$,
  'with the MFA switch off, a manager can edit a wage'
);

reset role;
update app_hidden.platform_settings set require_mfa_for_admin_actions = true;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-0000000000b4';
set local "request.jwt.claims" to '{"aal": "aal1"}';
select is(public.caller_mfa_satisfied(), false, 'with the switch on, an aal1 session fails the MFA check');
select throws_ok(
  $$ update public.employee_hr_profiles set hourly_rate_cents = 9999
     where user_id = '00000000-0000-0000-0000-0000000000b5' $$,
  '42501', 'mfa_required',
  'with the switch on, an aal1 session cannot edit a wage'
);
select lives_ok(
  $$ update public.employee_hr_profiles set job_title = 'Bartender'
     where user_id = '00000000-0000-0000-0000-0000000000b5' $$,
  'non-pay HR fields stay editable without MFA'
);
set local "request.jwt.claims" to '{"aal": "aal2"}';
select is(public.caller_mfa_satisfied(), true, 'an aal2 session passes the MFA check');
select lives_ok(
  $$ update public.employee_hr_profiles set hourly_rate_cents = 1700
     where user_id = '00000000-0000-0000-0000-0000000000b5' $$,
  'an aal2 session can edit a wage'
);
reset role;
update app_hidden.platform_settings set require_mfa_for_admin_actions = false;

-- ---------------------------------------------------------------------------
-- F08: merge/split need a supervisor or above
-- ---------------------------------------------------------------------------
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-0000000000b5';
select throws_ok(
  $$ select public.merge_floor_tables('20000000-0000-0000-0000-0000000000b1',
       array['51000000-0000-0000-0000-0000000000b1', '51000000-0000-0000-0000-0000000000b2']::uuid[]) $$,
  '42501', null,
  'staff cannot merge tables'
);
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-0000000000b8';
select lives_ok(
  $$ select public.merge_floor_tables('20000000-0000-0000-0000-0000000000b1',
       array['51000000-0000-0000-0000-0000000000b1', '51000000-0000-0000-0000-0000000000b2']::uuid[]) $$,
  'a supervisor can merge tables'
);

-- ---------------------------------------------------------------------------
-- F14: a missing id answers exactly like a forbidden one
-- ---------------------------------------------------------------------------
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-0000000000b4';
select throws_ok(
  $$ select public.correct_time_entry('99999999-0000-0000-0000-000000000001', now() - interval '2 hours', null, 'typo fix') $$,
  '42501', null,
  'correct_time_entry: a missing entry looks forbidden, not missing'
);
select throws_ok(
  $$ select public.erase_guest('99999999-0000-0000-0000-000000000002') $$,
  '42501', null,
  'erase_guest: a missing guest looks forbidden, not missing'
);
select throws_ok(
  $$ select public.remove_or_cancel_shift('99999999-0000-0000-0000-000000000003') $$,
  '42501', null,
  'remove_or_cancel_shift: a missing shift looks forbidden, not missing'
);

-- ---------------------------------------------------------------------------
-- F13: no SECURITY DEFINER function runs with public on its search_path
-- ---------------------------------------------------------------------------
reset role;
select is_empty(
  $$ select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('public', 'app_hidden') and p.prosecdef
       and exists (select 1 from unnest(p.proconfig) c where c like 'search_path=%' and c <> 'search_path=""') $$,
  'every SECURITY DEFINER function pins search_path to the empty string'
);
select ok(
  app_hidden.has_venue_role('20000000-0000-0000-0000-0000000000b1', array['staff']::public.app_role[]) is not null,
  'a normalized helper (has_venue_role) still runs'
);

select * from finish();
rollback;

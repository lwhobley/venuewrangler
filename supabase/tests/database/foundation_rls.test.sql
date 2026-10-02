-- pgTAP authorization tests for the Phase 1 foundation schema (organizations, venues,
-- memberships, profiles, platform_admins, audit_log).
--
-- Run with the Supabase CLI: `supabase test db`
-- (locally verified during authoring by installing pgTAP directly against a throwaway
-- Postgres database, applying this repo's migrations, and running this file with
-- `psql -f` — see docs/migration/flutter-supabase-rebuild-plan.md Phase 1 notes.)
--
-- Convention: seed fixtures as the connecting (table-owner) role, which bypasses RLS, then
-- `set local role authenticated` plus `set local "request.jwt.claim.sub"` to simulate a
-- specific signed-in user for each assertion. `reset role` returns to the owner role so the
-- next fixture/user switch starts clean. Every table gets at least one cross-tenant negative
-- test, per the Phase 1 requirement that authorization tests exist before any feature
-- screens are built on this schema.

begin;
select plan(31);

-- ---------------------------------------------------------------------------
-- Fixtures (seeded as table owner, bypasses RLS)
-- ---------------------------------------------------------------------------

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-000000000001', 'platform-admin@example.com'),
  ('00000000-0000-0000-0000-000000000002', 'org-a-owner@example.com'),
  ('00000000-0000-0000-0000-000000000003', 'org-a-admin@example.com'),
  ('00000000-0000-0000-0000-000000000004', 'venue-a1-manager@example.com'),
  ('00000000-0000-0000-0000-000000000005', 'venue-a1-staff@example.com'),
  ('00000000-0000-0000-0000-000000000006', 'org-b-owner@example.com'),
  ('00000000-0000-0000-0000-000000000007', 'no-membership@example.com');

insert into public.platform_admins (user_id) values
  ('00000000-0000-0000-0000-000000000001');

insert into public.organizations (id, name) values
  ('10000000-0000-0000-0000-00000000000a', 'Org A'),
  ('10000000-0000-0000-0000-00000000000b', 'Org B');

insert into public.venues (id, organization_id, name) values
  ('20000000-0000-0000-0000-0000000000a1', '10000000-0000-0000-0000-00000000000a', 'Venue A1'),
  ('20000000-0000-0000-0000-0000000000a2', '10000000-0000-0000-0000-00000000000a', 'Venue A2'),
  ('20000000-0000-0000-0000-0000000000b1', '10000000-0000-0000-0000-00000000000b', 'Venue B1');

insert into public.memberships (user_id, organization_id, venue_id, role) values
  ('00000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-00000000000a', null, 'organization_owner'),
  ('00000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-00000000000a', null, 'organization_admin'),
  ('00000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-0000000000a1', 'venue_manager'),
  ('00000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-0000000000a1', 'staff'),
  ('00000000-0000-0000-0000-000000000006', '10000000-0000-0000-0000-00000000000b', null, 'organization_owner');

-- profiles for the shared-scope / self-update tests below
insert into public.profiles (id, display_name) values
  ('00000000-0000-0000-0000-000000000004', 'Venue A1 Manager'),
  ('00000000-0000-0000-0000-000000000005', 'Venue A1 Staff'),
  ('00000000-0000-0000-0000-000000000006', 'Org B Owner')
on conflict (id) do update set display_name = excluded.display_name;

insert into public.audit_log (organization_id, venue_id, actor_user_id, action) values
  ('10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-000000000004', 'venue.updated'),
  ('10000000-0000-0000-0000-00000000000b', '20000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-000000000006', 'venue.updated');

-- ---------------------------------------------------------------------------
-- organizations
-- ---------------------------------------------------------------------------

set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000002';

select is(
  (select count(*)::int from public.organizations),
  1,
  'org_a_owner sees exactly their own organization'
);

select is(
  (select count(*)::int from public.organizations where id = '10000000-0000-0000-0000-00000000000b'),
  0,
  'org_a_owner cannot see org_b (cross-tenant)'
);

select throws_ok(
  $$ insert into public.organizations (name) values ('Rogue Org') $$,
  '42501',
  null,
  'org_a_owner cannot insert a new organization directly (server-mediated only)'
);

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000007';

select is(
  (select count(*)::int from public.organizations),
  0,
  'a user with no membership sees zero organizations'
);

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000001';

select is(
  (select count(*)::int from public.organizations),
  2,
  'platform_admin sees every organization'
);

-- ---------------------------------------------------------------------------
-- venues
-- ---------------------------------------------------------------------------

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000004';

select is(
  (select count(*)::int from public.venues),
  1,
  'venue_a1_manager (venue-scoped membership) sees only venue A1'
);

select is(
  (select count(*)::int from public.venues where id = '20000000-0000-0000-0000-0000000000b1'),
  0,
  'venue_a1_manager cannot see venue B1 (cross-tenant)'
);

select throws_ok(
  $$ insert into public.venues (organization_id, name) values ('10000000-0000-0000-0000-00000000000a', 'Rogue Venue') $$,
  '42501',
  null,
  'venue_a1_manager cannot create a venue (not an organization-level admin)'
);

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000002';

select is(
  (select count(*)::int from public.venues),
  2,
  'org_a_owner (org-level membership) sees every venue in org A'
);

select lives_ok(
  $$ insert into public.venues (organization_id, name) values ('10000000-0000-0000-0000-00000000000a', 'Venue A3') $$,
  'org_a_owner can create a new venue in their own organization'
);

select lives_ok(
  $$ update public.venues set name = 'Venue A1 Renamed' where id = '20000000-0000-0000-0000-0000000000a1' $$,
  'org_a_owner can rename a venue in their own organization'
);

-- DELETE with no applicable policy is a silent no-op in Postgres RLS (the implicit USING
-- clause matches zero rows) rather than an error, so assert on the row's survival, not on
-- an exception.
select lives_ok(
  $$ delete from public.venues where id = '20000000-0000-0000-0000-0000000000a1' $$,
  'org_a_owner''s delete attempt executes without error (no delete policy exists)'
);

select is(
  (select count(*)::int from public.venues where id = '20000000-0000-0000-0000-0000000000a1'),
  1,
  'venue A1 still exists afterward (the delete attempt matched zero rows, per no delete policy for any client role)'
);

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000004';

-- Same reasoning: UPDATE with a failing USING clause is a silent no-op, not an error.
select lives_ok(
  $$ update public.venues set name = 'Hijacked By Manager' where id = '20000000-0000-0000-0000-0000000000a1' $$,
  'venue_a1_manager''s update attempt executes without error but matches no rows'
);

select is(
  (select name from public.venues where id = '20000000-0000-0000-0000-0000000000a1'),
  'Venue A1 Renamed',
  'venue_a1_manager cannot actually rename the venue (update policy requires an organization-level admin role)'
);

-- ---------------------------------------------------------------------------
-- profiles
-- ---------------------------------------------------------------------------

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000005';

select is(
  (select count(*)::int from public.profiles where id = '00000000-0000-0000-0000-000000000005'),
  1,
  'a user can always read their own profile'
);

select is(
  (select count(*)::int from public.profiles where id = '00000000-0000-0000-0000-000000000004'),
  1,
  'venue_a1_staff can read a co-member''s profile (shared venue scope)'
);

select is(
  (select count(*)::int from public.profiles where id = '00000000-0000-0000-0000-000000000006'),
  0,
  'venue_a1_staff cannot read org_b_owner''s profile (no shared scope)'
);

select lives_ok(
  $$ update public.profiles set display_name = 'Venue A1 Staff (updated)' where id = '00000000-0000-0000-0000-000000000005' $$,
  'a user can update their own profile'
);

-- Same reasoning again: UPDATE with a failing USING clause is a silent no-op, not an error.
select lives_ok(
  $$ update public.profiles set display_name = 'hijacked' where id = '00000000-0000-0000-0000-000000000004' $$,
  'a user''s attempt to update someone else''s profile executes without error but matches no rows'
);

select is(
  (select display_name from public.profiles where id = '00000000-0000-0000-0000-000000000004'),
  'Venue A1 Manager',
  'the other user''s profile is left unchanged'
);

-- ---------------------------------------------------------------------------
-- memberships
-- ---------------------------------------------------------------------------

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000005';

select is(
  (select count(*)::int from public.memberships),
  1,
  'a non-admin user sees only their own membership row'
);

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000002';

select is(
  (select count(*)::int from public.memberships where organization_id = '10000000-0000-0000-0000-00000000000a'),
  4,
  'org_a_owner sees every membership row in their own organization'
);

select is(
  (select count(*)::int from public.memberships where organization_id = '10000000-0000-0000-0000-00000000000b'),
  0,
  'org_a_owner cannot see org_b''s membership rows (cross-tenant)'
);

select throws_ok(
  $$ insert into public.memberships (user_id, organization_id, role) values ('00000000-0000-0000-0000-000000000007', '10000000-0000-0000-0000-00000000000a', 'organization_owner') $$,
  '42501',
  null,
  'org_a_owner cannot grant a role directly (membership writes are server-mediated only)'
);

-- ---------------------------------------------------------------------------
-- platform_admins
-- ---------------------------------------------------------------------------

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000002';

select is(
  (select count(*)::int from public.platform_admins),
  0,
  'platform_admins is fully invisible to a non-platform-admin client (no select policy at all)'
);

select throws_ok(
  $$ insert into public.platform_admins (user_id) values ('00000000-0000-0000-0000-000000000002') $$,
  '42501',
  null,
  'a client can never self-grant platform_admin'
);

-- ---------------------------------------------------------------------------
-- audit_log
-- ---------------------------------------------------------------------------

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000002';

select is(
  (select count(*)::int from public.audit_log where organization_id = '10000000-0000-0000-0000-00000000000a'),
  1,
  'org_a_owner can read their own organization''s audit log'
);

select is(
  (select count(*)::int from public.audit_log where organization_id = '10000000-0000-0000-0000-00000000000b'),
  0,
  'org_a_owner cannot read org_b''s audit log (cross-tenant)'
);

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000005';

select is(
  (select count(*)::int from public.audit_log),
  0,
  'venue_a1_staff (non-admin) cannot read any audit log rows, even in their own organization'
);

select throws_ok(
  $$ insert into public.audit_log (organization_id, action) values ('10000000-0000-0000-0000-00000000000a', 'forged') $$,
  '42501',
  null,
  'a client can never write its own audit log entry'
);

select * from finish();
rollback;

-- pgTAP tests for the member lifecycle RPCs and segregation of duties
-- (20261017100000_audit_member_lifecycle_and_integrity.sql).
-- Fixture: org A  owner O1, admin AD, venue A1 {manager M, other manager M2, supervisor S, staff T1, T2},
--          org B  owner X (outsider). Venue B1 belongs to org B.

begin;
select plan(45);

insert into auth.users (id, email) values
  ('b1000000-0000-0000-0000-000000000001', 'o1@example.com'),
  ('b1000000-0000-0000-0000-000000000002', 'admin@example.com'),
  ('b1000000-0000-0000-0000-000000000003', 'manager@example.com'),
  ('b1000000-0000-0000-0000-000000000004', 'manager2@example.com'),
  ('b1000000-0000-0000-0000-000000000005', 'supervisor@example.com'),
  ('b1000000-0000-0000-0000-000000000006', 'staff1@example.com'),
  ('b1000000-0000-0000-0000-000000000007', 'staff2@example.com'),
  ('b1000000-0000-0000-0000-000000000008', 'outsider@example.com');

insert into public.organizations (id, name) values
  ('b2000000-0000-0000-0000-00000000000a', 'Org A'),
  ('b2000000-0000-0000-0000-00000000000b', 'Org B');

insert into public.venues (id, organization_id, name) values
  ('b3000000-0000-0000-0000-0000000000a1', 'b2000000-0000-0000-0000-00000000000a', 'Venue A1'),
  ('b3000000-0000-0000-0000-0000000000b1', 'b2000000-0000-0000-0000-00000000000b', 'Venue B1');

insert into public.memberships (user_id, organization_id, venue_id, role) values
  ('b1000000-0000-0000-0000-000000000001', 'b2000000-0000-0000-0000-00000000000a', null, 'organization_owner'),
  ('b1000000-0000-0000-0000-000000000002', 'b2000000-0000-0000-0000-00000000000a', null, 'organization_admin'),
  ('b1000000-0000-0000-0000-000000000003', 'b2000000-0000-0000-0000-00000000000a', 'b3000000-0000-0000-0000-0000000000a1', 'venue_manager'),
  ('b1000000-0000-0000-0000-000000000004', 'b2000000-0000-0000-0000-00000000000a', 'b3000000-0000-0000-0000-0000000000a1', 'venue_manager'),
  ('b1000000-0000-0000-0000-000000000005', 'b2000000-0000-0000-0000-00000000000a', 'b3000000-0000-0000-0000-0000000000a1', 'supervisor'),
  ('b1000000-0000-0000-0000-000000000006', 'b2000000-0000-0000-0000-00000000000a', 'b3000000-0000-0000-0000-0000000000a1', 'staff'),
  ('b1000000-0000-0000-0000-000000000007', 'b2000000-0000-0000-0000-00000000000a', 'b3000000-0000-0000-0000-0000000000a1', 'staff'),
  ('b1000000-0000-0000-0000-000000000008', 'b2000000-0000-0000-0000-00000000000b', null, 'organization_owner');

insert into public.push_tokens (organization_id, venue_id, user_id, token, platform, enabled) values
  ('b2000000-0000-0000-0000-00000000000a', 'b3000000-0000-0000-0000-0000000000a1',
   'b1000000-0000-0000-0000-000000000006', 'member-lifecycle-token-1', 'ios', true);

create temp table mid as
  select user_id, id as membership_id from public.memberships where organization_id in
    ('b2000000-0000-0000-0000-00000000000a', 'b2000000-0000-0000-0000-00000000000b');
grant select on mid to authenticated;

-- ---------------------------------------------------------------------------
-- team_members: managers see the venue + org-level members; others are refused.
-- ---------------------------------------------------------------------------
set local role authenticated;
set local "request.jwt.claim.sub" to 'b1000000-0000-0000-0000-000000000003';

select is(
  (select count(*)::int from public.team_members('b3000000-0000-0000-0000-0000000000a1')),
  7,
  'a venue manager sees the 5 venue members plus the org-level owner and admin'
);
select is(
  (select membership_id from public.team_members('b3000000-0000-0000-0000-0000000000a1') where user_id = 'b1000000-0000-0000-0000-000000000001'),
  (select membership_id from mid where user_id = 'b1000000-0000-0000-0000-000000000001'),
  'team_members exposes membership ids'
);
select throws_ok($$ select * from public.team_members('b3000000-0000-0000-0000-0000000000b1') $$, '42501', null,
  'a manager cannot list another organization''s team');

set local "request.jwt.claim.sub" to 'b1000000-0000-0000-0000-000000000006';
select throws_ok($$ select * from public.team_members('b3000000-0000-0000-0000-0000000000a1') $$, '42501', null,
  'staff cannot list the team');

-- ---------------------------------------------------------------------------
-- remove_member
-- ---------------------------------------------------------------------------
set local "request.jwt.claim.sub" to 'b1000000-0000-0000-0000-000000000008';
select throws_ok(
  $$ select public.remove_member((select membership_id from mid where user_id = 'b1000000-0000-0000-0000-000000000006')) $$,
  '42501', null, 'an outsider from another organization cannot remove a member');

set local "request.jwt.claim.sub" to 'b1000000-0000-0000-0000-000000000006';
select throws_ok(
  $$ select public.remove_member((select membership_id from mid where user_id = 'b1000000-0000-0000-0000-000000000007')) $$,
  '42501', null, 'staff cannot remove a colleague');

set local "request.jwt.claim.sub" to 'b1000000-0000-0000-0000-000000000003';
select throws_ok(
  $$ select public.remove_member((select membership_id from mid where user_id = 'b1000000-0000-0000-0000-000000000003')) $$,
  'P0001', null, 'a manager cannot remove themselves (the delete-account flow handles that)');
select throws_ok(
  $$ select public.remove_member((select membership_id from mid where user_id = 'b1000000-0000-0000-0000-000000000004')) $$,
  '42501', null, 'a manager cannot remove another manager');
select throws_ok(
  $$ select public.remove_member((select membership_id from mid where user_id = 'b1000000-0000-0000-0000-000000000002')) $$,
  '42501', null, 'a manager cannot remove an org admin');
select lives_ok(
  $$ select public.remove_member((select membership_id from mid where user_id = 'b1000000-0000-0000-0000-000000000006')) $$,
  'a manager removes a staff member');

reset role;
select is((select count(*)::int from public.memberships where user_id = 'b1000000-0000-0000-0000-000000000006'), 0,
  'the removed member has no membership left');
select is((select enabled from public.push_tokens where token = 'member-lifecycle-token-1'), false,
  'the removed member''s push token is disabled so notifications stop');
select is((select count(*)::int from public.audit_log where action = 'member.remove'
            and metadata ->> 'user_id' = 'b1000000-0000-0000-0000-000000000006'), 1,
  'the removal is audited');

set local role authenticated;
set local "request.jwt.claim.sub" to 'b1000000-0000-0000-0000-000000000002';
select lives_ok(
  $$ select public.remove_member((select membership_id from mid where user_id = 'b1000000-0000-0000-0000-000000000004')) $$,
  'an org admin removes a venue manager');
select throws_ok(
  $$ select public.remove_member((select membership_id from mid where user_id = 'b1000000-0000-0000-0000-000000000001')) $$,
  '42501', null, 'an org admin cannot remove the owner');
select throws_ok($$ select public.remove_member('b9000000-0000-0000-0000-000000000000') $$, 'P0002', null,
  'removing a missing membership reports not found');

-- ---------------------------------------------------------------------------
-- change_member_role
-- ---------------------------------------------------------------------------
set local "request.jwt.claim.sub" to 'b1000000-0000-0000-0000-000000000003';
select lives_ok(
  $$ select public.change_member_role((select membership_id from mid where user_id = 'b1000000-0000-0000-0000-000000000005'), 'staff') $$,
  'a manager demotes a supervisor to staff');
select throws_ok(
  $$ select public.change_member_role((select membership_id from mid where user_id = 'b1000000-0000-0000-0000-000000000007'), 'venue_manager') $$,
  '42501', null, 'a manager cannot promote staff to venue manager (privilege escalation)');
select throws_ok(
  $$ select public.change_member_role((select membership_id from mid where user_id = 'b1000000-0000-0000-0000-000000000007'), 'organization_owner') $$,
  'P0001', null, 'a venue-level membership cannot become an org-level role');
select throws_ok(
  $$ select public.change_member_role((select membership_id from mid where user_id = 'b1000000-0000-0000-0000-000000000003'), 'staff') $$,
  'P0001', null, 'a manager cannot change their own role');

set local "request.jwt.claim.sub" to 'b1000000-0000-0000-0000-000000000002';
select lives_ok(
  $$ select public.change_member_role((select membership_id from mid where user_id = 'b1000000-0000-0000-0000-000000000007'), 'venue_manager') $$,
  'an org admin promotes staff to venue manager');
select throws_ok(
  $$ select public.change_member_role((select membership_id from mid where user_id = 'b1000000-0000-0000-0000-000000000001'), 'organization_admin') $$,
  '42501', null, 'an org admin cannot demote the owner');
select throws_ok(
  $$ select public.change_member_role((select membership_id from mid where user_id = 'b1000000-0000-0000-0000-000000000002'), 'organization_owner') $$,
  'P0001', null, 'an org admin cannot promote themselves to owner');

reset role;
select is((select role::text from public.memberships where user_id = 'b1000000-0000-0000-0000-000000000007'), 'venue_manager',
  'the promotion persisted');
select is((select count(*)::int from public.audit_log where action = 'member.change_role'), 2,
  'both role changes are audited');

-- Cross-tenant: org B's owner cannot touch org A rows.
set local role authenticated;
set local "request.jwt.claim.sub" to 'b1000000-0000-0000-0000-000000000008';
select throws_ok(
  $$ select public.change_member_role((select membership_id from mid where user_id = 'b1000000-0000-0000-0000-000000000007'), 'staff') $$,
  '42501', null, 'another organization''s owner cannot change roles here');

-- ---------------------------------------------------------------------------
-- transfer_ownership and the last-owner rule
-- ---------------------------------------------------------------------------
set local "request.jwt.claim.sub" to 'b1000000-0000-0000-0000-000000000001';
select throws_ok(
  $$ select public.change_member_role((select membership_id from mid where user_id = 'b1000000-0000-0000-0000-000000000001'), 'organization_admin') $$,
  'P0001', null, 'the sole owner cannot step down (last_owner)');
select throws_ok(
  $$ select public.transfer_ownership('b2000000-0000-0000-0000-00000000000a', 'b1000000-0000-0000-0000-000000000008') $$,
  'P0001', null, 'ownership can only go to an existing member of the organization');
select throws_ok(
  $$ select public.transfer_ownership('b2000000-0000-0000-0000-00000000000a', 'b1000000-0000-0000-0000-000000000001') $$,
  'P0001', null, 'ownership cannot be transferred to yourself');

set local "request.jwt.claim.sub" to 'b1000000-0000-0000-0000-000000000002';
select throws_ok(
  $$ select public.transfer_ownership('b2000000-0000-0000-0000-00000000000a', 'b1000000-0000-0000-0000-000000000002') $$,
  '42501', null, 'an org admin cannot transfer ownership');

set local "request.jwt.claim.sub" to 'b1000000-0000-0000-0000-000000000001';
select lives_ok(
  $$ select public.transfer_ownership('b2000000-0000-0000-0000-00000000000a', 'b1000000-0000-0000-0000-000000000002') $$,
  'the owner promotes an existing admin to co-owner');
select lives_ok(
  $$ select public.change_member_role((select membership_id from mid where user_id = 'b1000000-0000-0000-0000-000000000001'), 'organization_admin') $$,
  'with a second owner in place the original owner can step down');
select throws_ok(
  $$ select public.change_member_role((select membership_id from mid where user_id = 'b1000000-0000-0000-0000-000000000002'), 'organization_admin') $$,
  '42501', null, 'the original owner, now an admin, can no longer demote the new owner');

reset role;
select is((select role::text from public.memberships where user_id = 'b1000000-0000-0000-0000-000000000002'), 'organization_owner',
  'the admin is now an owner');

-- ---------------------------------------------------------------------------
-- Optional MFA gate for manager-level mutations (platform_settings flag).
-- ---------------------------------------------------------------------------
update app_hidden.platform_settings set require_mfa_for_admin_actions = true;

set local role authenticated;
set local "request.jwt.claim.sub" to 'b1000000-0000-0000-0000-000000000002';
set local "request.jwt.claims" to '{"aal":"aal1"}';
select throws_ok(
  $$ select public.change_member_role((select membership_id from mid where user_id = 'b1000000-0000-0000-0000-000000000007'), 'supervisor') $$,
  '42501', null, 'with the MFA flag on, aal1 sessions cannot change manager-level roles');
set local "request.jwt.claims" to '{"aal":"aal2"}';
select lives_ok(
  $$ select public.change_member_role((select membership_id from mid where user_id = 'b1000000-0000-0000-0000-000000000007'), 'supervisor') $$,
  'with an aal2 session the same change succeeds');
set local "request.jwt.claims" to '{"aal":"aal1"}';
select lives_ok(
  $$ select public.change_member_role((select membership_id from mid where user_id = 'b1000000-0000-0000-0000-000000000007'), 'staff') $$,
  'supervisor/staff changes do not need aal2');

reset role;
update app_hidden.platform_settings set require_mfa_for_admin_actions = false;

-- ---------------------------------------------------------------------------
-- Segregation of duties on pay and staff requests (A-06).
-- ---------------------------------------------------------------------------
insert into public.employee_hr_profiles (venue_id, user_id, hourly_rate_cents) values
  ('b3000000-0000-0000-0000-0000000000a1', 'b1000000-0000-0000-0000-000000000001', 5000),
  ('b3000000-0000-0000-0000-0000000000a1', 'b1000000-0000-0000-0000-000000000002', 7000),
  ('b3000000-0000-0000-0000-0000000000a1', 'b1000000-0000-0000-0000-000000000003', 3000),
  ('b3000000-0000-0000-0000-0000000000a1', 'b1000000-0000-0000-0000-000000000007', 2000);

-- user ...001 is now an org admin (stepped down), ...002 is the owner.
set local role authenticated;
set local "request.jwt.claim.sub" to 'b1000000-0000-0000-0000-000000000001';
select throws_ok(
  $$ update public.employee_hr_profiles set hourly_rate_cents = 9000 where user_id = 'b1000000-0000-0000-0000-000000000001' $$,
  '42501', null, 'an org admin cannot raise their own pay');
select lives_ok(
  $$ update public.employee_hr_profiles set hourly_rate_cents = 9000 where user_id = 'b1000000-0000-0000-0000-000000000002' $$,
  'an org admin''s attempt on the owner''s HR row is filtered out by RLS (no error, no rows)');
select lives_ok(
  $$ update public.employee_hr_profiles set hourly_rate_cents = 2100 where user_id = 'b1000000-0000-0000-0000-000000000007' $$,
  'an org admin can still set a subordinate''s pay');

reset role;
select is((select hourly_rate_cents from public.employee_hr_profiles where user_id = 'b1000000-0000-0000-0000-000000000002'), 7000,
  'the owner''s pay is unchanged by the admin''s attempt');

set local role authenticated;
set local "request.jwt.claim.sub" to 'b1000000-0000-0000-0000-000000000002';
select lives_ok(
  $$ update public.employee_hr_profiles set hourly_rate_cents = 6000 where user_id = 'b1000000-0000-0000-0000-000000000001' $$,
  'the owner can set an admin''s pay');

-- Requests are created by their requesters (the insert trigger stamps user_id from the session).
set local role authenticated;
set local "request.jwt.claim.sub" to 'b1000000-0000-0000-0000-000000000003';
insert into public.staff_requests (id, venue_id, kind, title, details) values
  ('b4000000-0000-0000-0000-000000000001', 'b3000000-0000-0000-0000-0000000000a1', 'time_off', 'Manager PTO', 'self');
set local "request.jwt.claim.sub" to 'b1000000-0000-0000-0000-000000000002';
insert into public.staff_requests (id, venue_id, kind, title, details) values
  ('b4000000-0000-0000-0000-000000000002', 'b3000000-0000-0000-0000-0000000000a1', 'time_off', 'Owner PTO', 'self');

set local role authenticated;
set local "request.jwt.claim.sub" to 'b1000000-0000-0000-0000-000000000003';
select throws_ok(
  $$ update public.staff_requests set status = 'approved' where id = 'b4000000-0000-0000-0000-000000000001' $$,
  '42501', null, 'a manager cannot approve their own request');

set local "request.jwt.claim.sub" to 'b1000000-0000-0000-0000-000000000002';
select lives_ok(
  $$ update public.staff_requests set status = 'approved' where id = 'b4000000-0000-0000-0000-000000000001' $$,
  'the owner can approve a manager''s request');
select lives_ok(
  $$ update public.staff_requests set status = 'approved' where id = 'b4000000-0000-0000-0000-000000000002' $$,
  'the owner may approve their own request (nobody sits above them)');

select * from finish();
rollback;

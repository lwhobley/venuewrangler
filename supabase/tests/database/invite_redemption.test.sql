-- pgTAP tests for invite redemption after the audit remediation
-- (20261017100000_audit_member_lifecycle_and_integrity.sql). Sign-up no longer joins invited
-- users silently; a user with a verified email lists their invites (my_pending_invites) and
-- accepts one explicitly (accept_invite).

begin;
select plan(30);

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-000000000004', 'venue-a1-manager@example.com');

insert into public.organizations (id, name) values
  ('10000000-0000-0000-0000-00000000000a', 'Org A');

insert into public.venues (id, organization_id, name) values
  ('20000000-0000-0000-0000-0000000000a1', '10000000-0000-0000-0000-00000000000a', 'Venue A1');

insert into public.memberships (user_id, organization_id, venue_id, role) values
  ('00000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-0000000000a1', 'venue_manager');

-- Seeded as table owner. The expired row sets expires_at on insert because
-- enforce_invite_revoke_only forbids changing it on update, by design.
-- invited_by is derived from auth.uid() on insert; seed as the inviter.
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000004';
insert into public.invites (id, venue_id, email, role, invited_by) values
  ('30000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-0000000000a1', 'new-hire@example.com', 'staff', '00000000-0000-0000-0000-000000000004'),
  ('30000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-0000000000a1', 'revoked-hire@example.com', 'staff', '00000000-0000-0000-0000-000000000004');
set local "request.jwt.claim.sub" to '';

-- invited_by is derived from auth.uid() on insert; seed as the inviter.
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000004';
insert into public.invites (id, venue_id, email, role, invited_by, expires_at) values
  ('30000000-0000-0000-0000-000000000003', '20000000-0000-0000-0000-0000000000a1', 'expired-hire@example.com', 'staff', '00000000-0000-0000-0000-000000000004', now() - interval '1 day');
set local "request.jwt.claim.sub" to '';

update public.invites set status = 'revoked' where id = '30000000-0000-0000-0000-000000000002';

-- ---------------------------------------------------------------------------
-- Confirming an email no longer redeems anything (P-10).
-- ---------------------------------------------------------------------------
insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-000000000010', 'New-Hire@Example.com');

select is(
  (select count(*)::int from public.profiles where id = '00000000-0000-0000-0000-000000000010'),
  1,
  'signup still creates the profile'
);

update auth.users set email_confirmed_at = now()
  where id = '00000000-0000-0000-0000-000000000010';

select is(
  (select count(*)::int from public.memberships where user_id = '00000000-0000-0000-0000-000000000010'),
  0,
  'confirming the email does NOT silently join the invited venue'
);

select is(
  (select status from public.invites where id = '30000000-0000-0000-0000-000000000001'),
  'pending',
  'the invite stays pending until the user accepts it'
);

-- ---------------------------------------------------------------------------
-- Listing and accepting as the invited (confirmed) user.
-- ---------------------------------------------------------------------------
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000010';

select results_eq(
  $$ select invite_id, organization_name, venue_name, role::text from public.my_pending_invites() $$,
  $$ values ('30000000-0000-0000-0000-000000000001'::uuid, 'Org A'::text, 'Venue A1'::text, 'staff'::text) $$,
  'my_pending_invites lists the matching pending invite (case-insensitive email) with names'
);

select throws_ok(
  $$ select public.accept_invite('30000000-0000-0000-0000-000000000002') $$,
  'P0002', null,
  'an invite addressed to someone else cannot be accepted'
);

select lives_ok(
  $$ select public.accept_invite('30000000-0000-0000-0000-000000000001') $$,
  'the invited user accepts their invite'
);

reset role;

select is(
  (select role::text from public.memberships where user_id = '00000000-0000-0000-0000-000000000010'),
  'staff',
  'accepting creates the membership with the invited role'
);

select is(
  (select venue_id from public.memberships where user_id = '00000000-0000-0000-0000-000000000010'),
  '20000000-0000-0000-0000-0000000000a1'::uuid,
  'the membership is scoped to the invite''s venue'
);

select is(
  (select status from public.invites where id = '30000000-0000-0000-0000-000000000001'),
  'accepted',
  'the invite is marked accepted'
);

select is(
  (select count(*)::int from public.audit_log where action = 'invite.accept'
     and target_id = '30000000-0000-0000-0000-000000000001'),
  1,
  'acceptance is audited'
);

set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000010';

select throws_ok(
  $$ select public.accept_invite('30000000-0000-0000-0000-000000000001') $$,
  'P0001', null,
  'an invite cannot be accepted twice'
);

select is(
  (select count(*)::int from public.my_pending_invites()),
  0,
  'accepted invites no longer appear as pending'
);

-- ---------------------------------------------------------------------------
-- Unverified email, revoked and expired invites, anonymous callers.
-- ---------------------------------------------------------------------------
reset role;

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-000000000014', 'new-hire@example.com');   -- same address, unverified

-- invited_by is derived from auth.uid() on insert; seed as the inviter.
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000004';
insert into public.invites (id, venue_id, email, role, invited_by) values
  ('30000000-0000-0000-0000-000000000004', '20000000-0000-0000-0000-0000000000a1', 'new-hire@example.com', 'supervisor', '00000000-0000-0000-0000-000000000004');
set local "request.jwt.claim.sub" to '';

set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000014';

select is(
  (select count(*)::int from public.my_pending_invites()),
  0,
  'a user whose email is not verified sees no invites'
);

select throws_ok(
  $$ select public.accept_invite('30000000-0000-0000-0000-000000000004') $$,
  '42501', null,
  'a user whose email is not verified cannot accept an invite'
);

reset role;
insert into auth.users (id, email, email_confirmed_at) values
  ('00000000-0000-0000-0000-000000000012', 'revoked-hire@example.com', now()),
  ('00000000-0000-0000-0000-000000000013', 'expired-hire@example.com', now());

set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000012';
select throws_ok(
  $$ select public.accept_invite('30000000-0000-0000-0000-000000000002') $$,
  'P0001', null,
  'a revoked invite cannot be accepted'
);
select is((select count(*)::int from public.my_pending_invites()), 0, 'a revoked invite is not listed');

set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000013';
select throws_ok(
  $$ select public.accept_invite('30000000-0000-0000-0000-000000000003') $$,
  'P0001', null,
  'an expired invite cannot be accepted'
);
select is((select count(*)::int from public.my_pending_invites()), 0, 'an expired invite is not listed');

set local "request.jwt.claim.sub" to '';
select throws_ok(
  $$ select public.accept_invite('30000000-0000-0000-0000-000000000001') $$,
  '42501', null,
  'an unauthenticated caller cannot accept an invite'
);

-- ---------------------------------------------------------------------------
-- M1: membership conflict updates role; M2: pending→accepted only via RPC.
-- ---------------------------------------------------------------------------
reset role;
insert into auth.users (id, email, email_confirmed_at) values
  ('00000000-0000-0000-0000-000000000015', 'promo@example.com', now()),
  ('00000000-0000-0000-0000-000000000016', 'org-admin@example.com', now()),
  ('00000000-0000-0000-0000-000000000017', 'peer-manager@example.com', now());
-- Only org owners/admins may grant venue_manager (can_manage_member_role).
insert into public.memberships (user_id, organization_id, venue_id, role) values
  ('00000000-0000-0000-0000-000000000016', '10000000-0000-0000-0000-00000000000a', null, 'organization_admin'),
  ('00000000-0000-0000-0000-000000000017', '10000000-0000-0000-0000-00000000000a',
   '20000000-0000-0000-0000-0000000000a1', 'venue_manager');
insert into public.memberships (user_id, organization_id, venue_id, role) values
  ('00000000-0000-0000-0000-000000000015', '10000000-0000-0000-0000-00000000000a',
   '20000000-0000-0000-0000-0000000000a1', 'staff');
-- invited_by is derived from auth.uid() on insert; seed as the inviter.
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000016';
insert into public.invites (id, venue_id, email, role, invited_by) values
  ('30000000-0000-0000-0000-000000000005', '20000000-0000-0000-0000-0000000000a1',
   'promo@example.com', 'venue_manager', '00000000-0000-0000-0000-000000000016'),
  ('30000000-0000-0000-0000-000000000006', '20000000-0000-0000-0000-0000000000a1',
   'forge-accept@example.com', 'staff', '00000000-0000-0000-0000-000000000004');
set local "request.jwt.claim.sub" to '';

set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000015';
select lives_ok(
  $$ select public.accept_invite('30000000-0000-0000-0000-000000000005') $$,
  'accepting a promotion invite upgrades the existing membership role'
);
reset role;
select is(
  (select role::text from public.memberships
    where user_id = '00000000-0000-0000-0000-000000000015'
      and venue_id = '20000000-0000-0000-0000-0000000000a1'),
  'venue_manager',
  'membership role matches the invite after conflict upsert'
);
select is(
  (select status from public.invites where id = '30000000-0000-0000-0000-000000000005'),
  'accepted',
  'invite is accepted only after membership matches'
);

set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000004';
select throws_ok(
  $$ update public.invites set status = 'accepted'
      where id = '30000000-0000-0000-0000-000000000006' $$,
  '42501', null,
  'managers cannot mark an invite accepted without accept_invite'
);
select lives_ok(
  $$ select public.revoke_invite('30000000-0000-0000-0000-000000000006') $$,
  'revoke_invite revokes a pending invite'
);
reset role;
select is(
  (select status from public.invites where id = '30000000-0000-0000-0000-000000000006'),
  'revoked',
  'revoke_invite marks the invite revoked'
);

-- ---------------------------------------------------------------------------
-- Invite role gate: a venue_manager cannot grant venue_manager, nor use a re-invite to
-- change a peer manager's role.
-- ---------------------------------------------------------------------------
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000004';
select throws_ok(
  $$ select public.prepare_staff_invite(
       '20000000-0000-0000-0000-0000000000a1', 'want-manager@example.com', 'venue_manager') $$,
  '42501', null,
  'a venue_manager cannot invite someone as venue_manager'
);
reset role;
-- invited_by is derived from auth.uid() on insert; seed as the inviter.
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000004';
insert into public.invites (id, venue_id, email, role, invited_by) values
  ('30000000-0000-0000-0000-000000000007', '20000000-0000-0000-0000-0000000000a1',
   'peer-manager@example.com', 'staff', '00000000-0000-0000-0000-000000000004');
set local "request.jwt.claim.sub" to '';
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000017';
select throws_ok(
  $$ select public.accept_invite('30000000-0000-0000-0000-000000000007') $$,
  '42501', 'invite_inviter_not_authorized',
  'a manager''s re-invite cannot demote a peer manager'
);
reset role;
select is(
  (select role::text from public.memberships
    where user_id = '00000000-0000-0000-0000-000000000017'
      and venue_id = '20000000-0000-0000-0000-0000000000a1'),
  'venue_manager',
  'peer manager keeps their role'
);

-- ---------------------------------------------------------------------------
-- Re-invite records the re-inviter: a manager's staff invite that an admin upgrades to
-- venue_manager is accepted under the admin's authority.
-- ---------------------------------------------------------------------------
reset role;
insert into auth.users (id, email, email_confirmed_at) values
  ('00000000-0000-0000-0000-000000000019', 'upgrade@example.com', now());
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000004';
select public.prepare_staff_invite('20000000-0000-0000-0000-0000000000a1', 'upgrade@example.com', 'staff');
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000016';
select public.prepare_staff_invite('20000000-0000-0000-0000-0000000000a1', 'upgrade@example.com', 'venue_manager');
reset role;
select is(
  (select invited_by from public.invites where email = 'upgrade@example.com' and status = 'pending'),
  '00000000-0000-0000-0000-000000000016'::uuid,
  'a reconciling re-invite records the re-inviter as invited_by'
);
-- The invitee cannot read invites under RLS; resolve the id as table owner.
select set_config('test.upgrade_invite', id::text, true)
  from public.invites where email = 'upgrade@example.com' and status = 'pending';
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000019';
select lives_ok(
  $$ select public.accept_invite(current_setting('test.upgrade_invite')::uuid) $$,
  'an admin-upgraded invite can be accepted'
);
reset role;

select * from finish();
rollback;

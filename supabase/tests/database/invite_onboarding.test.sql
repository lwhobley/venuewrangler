-- pgTAP tests for invite onboarding (20261022110000_invite_onboarding.sql): create/resend
-- RPCs, expired invites no longer blocking a new one, invitee names, send bookkeeping, and
-- the owner's rule that venue managers cannot invite other managers.
-- Fixture: org A owner O, admin AD, venue A1 {manager M, staff T}; org B owner X.

begin;
select plan(30);

insert into auth.users (id, email, email_confirmed_at) values
  ('c1000000-0000-0000-0000-000000000001', 'owner@example.com', now()),
  ('c1000000-0000-0000-0000-000000000002', 'admin@example.com', now()),
  ('c1000000-0000-0000-0000-000000000003', 'manager@example.com', now()),
  ('c1000000-0000-0000-0000-000000000004', 'staff@example.com', now()),
  ('c1000000-0000-0000-0000-000000000005', 'outsider@example.com', now());

insert into public.organizations (id, name) values
  ('c2000000-0000-0000-0000-00000000000a', 'Org A'),
  ('c2000000-0000-0000-0000-00000000000b', 'Org B');

insert into public.venues (id, organization_id, name) values
  ('c3000000-0000-0000-0000-0000000000a1', 'c2000000-0000-0000-0000-00000000000a', 'Venue A1'),
  ('c3000000-0000-0000-0000-0000000000b1', 'c2000000-0000-0000-0000-00000000000b', 'Venue B1');

insert into public.memberships (user_id, organization_id, venue_id, role) values
  ('c1000000-0000-0000-0000-000000000001', 'c2000000-0000-0000-0000-00000000000a', null, 'organization_owner'),
  ('c1000000-0000-0000-0000-000000000002', 'c2000000-0000-0000-0000-00000000000a', null, 'organization_admin'),
  ('c1000000-0000-0000-0000-000000000003', 'c2000000-0000-0000-0000-00000000000a', 'c3000000-0000-0000-0000-0000000000a1', 'venue_manager'),
  ('c1000000-0000-0000-0000-000000000004', 'c2000000-0000-0000-0000-00000000000a', 'c3000000-0000-0000-0000-0000000000a1', 'staff'),
  ('c1000000-0000-0000-0000-000000000005', 'c2000000-0000-0000-0000-00000000000b', null, 'organization_owner');

update public.profiles set display_name = 'Mia Manager' where id = 'c1000000-0000-0000-0000-000000000003';

-- An invite that expired on its own (seeded as table owner; expires_at is immutable later).
insert into public.invites (id, venue_id, email, role, invited_by, full_name, expires_at) values
  ('c4000000-0000-0000-0000-000000000001', 'c3000000-0000-0000-0000-0000000000a1', 'lena@example.com', 'staff',
   'c1000000-0000-0000-0000-000000000003', 'Lena Park', now() - interval '3 days');

create temp table ids (label text primary key, id uuid);
grant all on ids to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Creating invites as a venue manager.
-- ---------------------------------------------------------------------------
set local role authenticated;
set local "request.jwt.claim.sub" to 'c1000000-0000-0000-0000-000000000003';

select lives_ok(
  $$ insert into ids select 'camila', (public.create_invite(
       'c3000000-0000-0000-0000-0000000000a1', ' Camila@Example.com ', 'staff', '  Camila   Reyes ')).id $$,
  'a manager invites staff with a name'
);

select results_eq(
  $$ select email, role::text, full_name, invited_by, organization_id, status
     from public.invites where id = (select id from ids where label = 'camila') $$,
  $$ values ('camila@example.com'::text, 'staff'::text, 'Camila Reyes'::text,
             'c1000000-0000-0000-0000-000000000003'::uuid, 'c2000000-0000-0000-0000-00000000000a'::uuid, 'pending'::text) $$,
  'the invite stores the normalised email and name, the inviter and the organization'
);

select throws_ok(
  $$ select public.create_invite('c3000000-0000-0000-0000-0000000000a1', 'newmgr@example.com', 'venue_manager', 'New Manager') $$,
  '42501', null,
  'a manager cannot invite another venue manager (owner decision)'
);

select throws_ok(
  $$ insert into public.invites (venue_id, email, role) values ('c3000000-0000-0000-0000-0000000000a1', 'newmgr@example.com', 'venue_manager') $$,
  '42501', null,
  'a manager cannot insert a venue-manager invite directly either'
);

select lives_ok(
  $$ insert into public.invites (venue_id, email, role) values ('c3000000-0000-0000-0000-0000000000a1', 'direct@example.com', 'supervisor') $$,
  'a manager may still insert a supervisor invite directly'
);

select throws_ok(
  $$ select public.create_invite('c3000000-0000-0000-0000-0000000000a1', 'staff@example.com', 'staff', null) $$,
  'P0001', 'already_member',
  'inviting someone who is already on the team is refused with a clear reason'
);

select throws_ok(
  $$ select public.create_invite('c3000000-0000-0000-0000-0000000000a1', 'not-an-email', 'staff', null) $$,
  '22023', 'invalid_email',
  'an invalid email is refused'
);

select throws_ok(
  $$ select public.create_invite('c3000000-0000-0000-0000-0000000000b1', 'someone@example.com', 'staff', null) $$,
  '42501', null,
  'a manager cannot invite into another organization''s venue'
);

-- ---------------------------------------------------------------------------
-- Expired invites no longer block, live ones are replaced.
-- ---------------------------------------------------------------------------
select lives_ok(
  $$ insert into ids select 'lena2', (public.create_invite(
       'c3000000-0000-0000-0000-0000000000a1', 'lena@example.com', 'staff', 'Lena Park')).id $$,
  'an expired invite for the same email does not block a new one'
);

select is(
  (select status from public.invites where id = 'c4000000-0000-0000-0000-000000000001'),
  'expired',
  'the stale invite is marked expired'
);

select lives_ok(
  $$ insert into ids select 'camila2', (public.create_invite(
       'c3000000-0000-0000-0000-0000000000a1', 'camila@example.com', 'supervisor', 'Camila Reyes')).id $$,
  'inviting the same email again replaces the live invite'
);

select results_eq(
  $$ select status from public.invites where email = 'camila@example.com' order by created_at, status $$,
  $$ values ('pending'::text), ('revoked'::text) $$,
  'exactly one invite stays pending; the replaced one is revoked'
);

select is(
  (select (public.resend_invite((select id from ids where label = 'camila2'))).id),
  (select id from ids where label = 'camila2'),
  'resending a live invite keeps the same invite (and link)'
);

reset role;
-- Age camila2 past its expiry (table owner; the trigger would refuse a client).
alter table public.invites disable trigger enforce_invite_revoke_only;
update public.invites set expires_at = now() - interval '1 minute' where id = (select id from ids where label = 'camila2');
alter table public.invites enable trigger enforce_invite_revoke_only;

set local role authenticated;
set local "request.jwt.claim.sub" to 'c1000000-0000-0000-0000-000000000003';

select lives_ok(
  $$ insert into ids select 'camila3', (public.resend_invite((select id from ids where label = 'camila2'))).id $$,
  'resending an expired invite issues a fresh one'
);

select results_eq(
  $$ select role::text, full_name, status, expires_at > now() + interval '13 days'
     from public.invites where id = (select id from ids where label = 'camila3') $$,
  $$ values ('supervisor'::text, 'Camila Reyes'::text, 'pending'::text, true) $$,
  'the fresh invite keeps the role and name with a new 14-day expiry'
);

select is(
  (select status from public.invites where id = (select id from ids where label = 'camila2')),
  'expired',
  'the expired original is marked expired'
);

-- ---------------------------------------------------------------------------
-- Send bookkeeping and column guards.
-- ---------------------------------------------------------------------------
select throws_ok(
  $$ update public.invites set last_sent_at = now() where id = (select id from ids where label = 'camila3') $$,
  '42501', null,
  'a client cannot write the send record'
);

select throws_ok(
  $$ select public.record_invite_email_sent((select id from ids where label = 'camila3')) $$,
  '42501', null,
  'only the service role may record a send'
);

reset role;
set local role service_role;
select lives_ok(
  $$ select public.record_invite_email_sent((select id from ids where label = 'camila3')) $$,
  'the email function records a send'
);
reset role;

select results_eq(
  $$ select send_count, last_sent_at is not null, status from public.invites where id = (select id from ids where label = 'camila3') $$,
  $$ values (1, true, 'pending'::text) $$,
  'the send is counted without touching the status'
);

-- ---------------------------------------------------------------------------
-- Owners/admins and manager-level invites.
-- ---------------------------------------------------------------------------
set local role authenticated;
set local "request.jwt.claim.sub" to 'c1000000-0000-0000-0000-000000000002';
select lives_ok(
  $$ insert into ids select 'mgr', (public.create_invite(
       'c3000000-0000-0000-0000-0000000000a1', 'newmgr@example.com', 'venue_manager', 'Nora Manager')).id $$,
  'an organization admin may invite a venue manager'
);

set local "request.jwt.claim.sub" to 'c1000000-0000-0000-0000-000000000003';
select throws_ok(
  $$ select public.create_invite('c3000000-0000-0000-0000-0000000000a1', 'newmgr@example.com', 'staff', null) $$,
  '42501', null,
  'a manager cannot replace (downgrade) a manager invite issued by an admin'
);
select throws_ok(
  $$ select public.resend_invite((select id from ids where label = 'mgr')) $$,
  '42501', null,
  'a manager cannot resend a manager invite'
);

update public.invites set status = 'revoked' where id = (select id from ids where label = 'mgr');
select is(
  (select status from public.invites where id = (select id from ids where label = 'mgr')),
  'pending',
  'a manager cannot revoke a manager invite (the row is not theirs to manage)'
);

set local "request.jwt.claim.sub" to 'c1000000-0000-0000-0000-000000000004';
select throws_ok(
  $$ select public.create_invite('c3000000-0000-0000-0000-0000000000a1', 'friend@example.com', 'staff', null) $$,
  '42501', null,
  'staff cannot invite anyone'
);

-- ---------------------------------------------------------------------------
-- The invitee: listing shows who invited them; accepting applies the name.
-- ---------------------------------------------------------------------------
reset role;
insert into auth.users (id, email, email_confirmed_at) values
  ('c1000000-0000-0000-0000-000000000010', 'lena@example.com', now()),
  ('c1000000-0000-0000-0000-000000000011', 'camila@example.com', now());
update public.profiles set display_name = 'Cami' where id = 'c1000000-0000-0000-0000-000000000011';

set local role authenticated;
set local "request.jwt.claim.sub" to 'c1000000-0000-0000-0000-000000000010';

select results_eq(
  $$ select invite_id, venue_name, invited_by_name, expires_at > now() from public.my_pending_invites() $$,
  $$ select id, 'Venue A1'::text, 'Mia Manager'::text, true from ids where label = 'lena2' $$,
  'my_pending_invites lists the live invite with the inviter''s name, not the expired one'
);

select lives_ok(
  $$ select public.accept_invite((select id from ids where label = 'lena2')) $$,
  'Lena accepts her replacement invite'
);

select is(
  (select display_name from public.profiles where id = 'c1000000-0000-0000-0000-000000000010'),
  'Lena Park',
  'the invited name becomes the new member''s display name'
);

set local "request.jwt.claim.sub" to 'c1000000-0000-0000-0000-000000000011';
select lives_ok(
  $$ select public.accept_invite((select id from ids where label = 'camila3')) $$,
  'Camila accepts her invite'
);
select is(
  (select display_name from public.profiles where id = 'c1000000-0000-0000-0000-000000000011'),
  'Cami',
  'a display name the member chose is not overwritten'
);

select * from finish();
rollback;

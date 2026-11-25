-- pgTAP tests for supabase/migrations/20261125110000_audit_invites_swaps_pos_ai.sql.
begin;
select plan(24);

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000000a2', 'owner@example.com'),
  ('00000000-0000-0000-0000-0000000000a4', 'manager@example.com'),
  ('00000000-0000-0000-0000-0000000000a5', 'staff@example.com'),
  ('00000000-0000-0000-0000-0000000000a7', 'staff2@example.com'),
  ('00000000-0000-0000-0000-0000000000a8', 'supervisor@example.com');

insert into public.organizations (id, name) values ('10000000-0000-0000-0000-0000000000aa', 'Org');
insert into public.venues (id, organization_id, name) values
  ('20000000-0000-0000-0000-0000000000aa', '10000000-0000-0000-0000-0000000000aa', 'Venue');

insert into public.memberships (user_id, organization_id, venue_id, role) values
  ('00000000-0000-0000-0000-0000000000a2', '10000000-0000-0000-0000-0000000000aa', null, 'organization_owner'),
  ('00000000-0000-0000-0000-0000000000a4', '10000000-0000-0000-0000-0000000000aa', '20000000-0000-0000-0000-0000000000aa', 'venue_manager'),
  ('00000000-0000-0000-0000-0000000000a5', '10000000-0000-0000-0000-0000000000aa', '20000000-0000-0000-0000-0000000000aa', 'staff'),
  ('00000000-0000-0000-0000-0000000000a7', '10000000-0000-0000-0000-0000000000aa', '20000000-0000-0000-0000-0000000000aa', 'staff'),
  ('00000000-0000-0000-0000-0000000000a8', '10000000-0000-0000-0000-0000000000aa', '20000000-0000-0000-0000-0000000000aa', 'supervisor');

-- Invites seeded as the table owner (an organization owner's invite for a manager, etc.).
insert into public.invites (id, venue_id, email, role, invited_by) values
  ('30000000-0000-0000-0000-0000000000a1', '20000000-0000-0000-0000-0000000000aa', 'boss@example.com', 'venue_manager',
   '00000000-0000-0000-0000-0000000000a2'),
  ('30000000-0000-0000-0000-0000000000a2', '20000000-0000-0000-0000-0000000000aa', 'server@example.com', 'staff',
   '00000000-0000-0000-0000-0000000000a4');
insert into public.invites (id, venue_id, email, role, invited_by, created_at, expires_at) values
  ('30000000-0000-0000-0000-0000000000a3', '20000000-0000-0000-0000-0000000000aa', 'old@example.com', 'venue_manager',
   '00000000-0000-0000-0000-0000000000a2', now() - interval '30 days', now() - interval '1 day');

insert into public.shifts (id, venue_id, start_time, end_time, staff_id) values
  ('40000000-0000-0000-0000-0000000000a1', '20000000-0000-0000-0000-0000000000aa',
   now() + interval '1 day', now() + interval '1 day 4 hours', '00000000-0000-0000-0000-0000000000a5'),
  ('40000000-0000-0000-0000-0000000000a2', '20000000-0000-0000-0000-0000000000aa',
   now() + interval '2 days', now() + interval '2 days 4 hours', '00000000-0000-0000-0000-0000000000a5');
-- The swap insert trigger derives requested_by from the caller, so the shift's owner requests them.
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-0000000000a5';
insert into public.shift_swaps (id, shift_id, offered_to) values
  ('41000000-0000-0000-0000-0000000000a1', '40000000-0000-0000-0000-0000000000a1',
   '00000000-0000-0000-0000-0000000000a7'),
  ('41000000-0000-0000-0000-0000000000a2', '40000000-0000-0000-0000-0000000000a2', null);
reset role;

insert into public.crm_beos (id, venue_id, event_name) values
  ('50000000-0000-0000-0000-0000000000a1', '20000000-0000-0000-0000-0000000000aa', 'Private dinner');
insert into public.reservations (id, venue_id, organization_id, guest_name, party_size, reservation_time, beo_id) values
  ('51000000-0000-0000-0000-0000000000a1', '20000000-0000-0000-0000-0000000000aa', '10000000-0000-0000-0000-0000000000aa',
   'Private dinner', 40, now() + interval '7 days', '50000000-0000-0000-0000-0000000000a1');

insert into public.push_tokens (organization_id, venue_id, user_id, token, platform, revocation_secret_hash) values
  ('10000000-0000-0000-0000-0000000000aa', '20000000-0000-0000-0000-0000000000aa',
   '00000000-0000-0000-0000-0000000000a5', 'audit-fix-token', 'ios', 'digest');

-- ---------------------------------------------------------------------------
-- 1. Invites: a venue_manager cannot touch an owner's pending manager invite
-- ---------------------------------------------------------------------------
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-0000000000a4';

select throws_ok(
  $$ select public.prepare_staff_invite('20000000-0000-0000-0000-0000000000aa', 'boss@example.com', 'staff') $$,
  '42501', null,
  'a venue manager cannot downgrade a pending manager invite by re-inviting as staff'
);
select throws_ok(
  $$ select public.revoke_invite('30000000-0000-0000-0000-0000000000a1') $$,
  '42501', null,
  'a venue manager cannot revoke a pending manager invite'
);
select throws_ok(
  $$ update public.invites set status = 'revoked' where id = '30000000-0000-0000-0000-0000000000a1' $$,
  '42501', null,
  'a venue manager cannot revoke a pending manager invite with a direct update either'
);
select lives_ok(
  $$ select public.revoke_invite('30000000-0000-0000-0000-0000000000a2') $$,
  'a venue manager can still revoke a staff invite'
);
select lives_ok(
  $$ select public.prepare_staff_invite('20000000-0000-0000-0000-0000000000aa', 'old@example.com', 'staff') $$,
  'an expired manager invite does not block re-inviting the email as staff'
);

reset role;
select is(
  (select status from public.invites where id = '30000000-0000-0000-0000-0000000000a1'),
  'pending',
  'the owner''s manager invite is still pending after every attempt'
);
select is(
  (select role::text from public.invites where id = '30000000-0000-0000-0000-0000000000a1'),
  'venue_manager',
  'and still grants venue_manager'
);

set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-0000000000a2';
set local "request.jwt.claims" to '{"aal": "aal2"}';
select lives_ok(
  $$ select public.revoke_invite('30000000-0000-0000-0000-0000000000a1') $$,
  'the organization owner can revoke the manager invite'
);

-- ---------------------------------------------------------------------------
-- 2. Shift swaps
-- ---------------------------------------------------------------------------
reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-0000000000a7';
select lives_ok(
  $$ update public.shift_swaps set status = 'declined' where id = '41000000-0000-0000-0000-0000000000a1' $$,
  'the person a swap was offered to can decline it'
);
select throws_ok(
  $$ update public.shift_swaps set status = 'declined' where id = '41000000-0000-0000-0000-0000000000a2' $$,
  '42501', null,
  'nobody can decline an open offer on the requester''s behalf'
);

reset role;
select is(
  (select status from public.shift_swaps where id = '41000000-0000-0000-0000-0000000000a1'),
  'declined',
  'the decline is stored'
);

set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-0000000000a4';
select throws_ok(
  $$ update public.shift_swaps set status = 'accepted', accepted_by = '00000000-0000-0000-0000-0000000000a7'
     where id = '41000000-0000-0000-0000-0000000000a1' $$,
  '42501', null,
  'a manager cannot resurrect a declined swap as accepted'
);
select throws_ok(
  $$ update public.shift_swaps set status = 'accepted' where id = '41000000-0000-0000-0000-0000000000a2' $$,
  '23514', null,
  'an accepted swap must name who accepted it, even for a manager'
);

reset role;
select is(
  (select staff_id from public.shifts where id = '40000000-0000-0000-0000-0000000000a1'),
  '00000000-0000-0000-0000-0000000000a5'::uuid,
  'the shift keeps its original assignee'
);

-- ---------------------------------------------------------------------------
-- 4. AI cost precision
-- ---------------------------------------------------------------------------
insert into public.ai_usage_events (organization_id, task, model, input_tokens, output_tokens, cost_usd)
values ('10000000-0000-0000-0000-0000000000aa', 'chat', 'test-model', 10, 5, 0.00001234);
select is(
  (select cost_usd from public.ai_usage_events where organization_id = '10000000-0000-0000-0000-0000000000aa'),
  0.00001234::numeric,
  'a sub-cent AI call cost is stored, not rounded to zero'
);

-- ---------------------------------------------------------------------------
-- 6. Deleting a guest linked to a closed POS check
-- ---------------------------------------------------------------------------
insert into public.guests (id, venue_id, organization_id, full_name) values
  ('60000000-0000-0000-0000-0000000000a1', '20000000-0000-0000-0000-0000000000aa', '10000000-0000-0000-0000-0000000000aa', 'Gina');
insert into public.pos_checks (id, venue_id, organization_id, provider, external_check_id, opened_at, closed_at,
  subtotal_cents, total_cents, guest_id, status)
values ('61000000-0000-0000-0000-0000000000a1', '20000000-0000-0000-0000-0000000000aa', '10000000-0000-0000-0000-0000000000aa',
  'toast', 'audit-chk-1', now() - interval '2 hours', now() - interval '1 hour', 1000, 1100,
  '60000000-0000-0000-0000-0000000000a1', 'closed');

select lives_ok(
  $$ delete from public.guests where id = '60000000-0000-0000-0000-0000000000a1' $$,
  'a guest linked to a closed POS check can be deleted'
);
select is(
  (select guest_id from public.pos_checks where id = '61000000-0000-0000-0000-0000000000a1'),
  null,
  'the check''s guest link is cleared'
);
select is(
  (select total_cents from public.pos_checks where id = '61000000-0000-0000-0000-0000000000a1'),
  1100,
  'the closed check''s totals are untouched'
);

-- ---------------------------------------------------------------------------
-- a) push_tokens
-- ---------------------------------------------------------------------------
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-0000000000a5';
select throws_ok(
  $$ select revocation_secret_hash from public.push_tokens $$,
  '42501', null,
  'a user cannot read the revocation secret digest of their own token'
);
select throws_ok(
  $$ delete from public.push_tokens $$,
  '42501', null,
  'push tokens cannot be deleted directly'
);

-- ---------------------------------------------------------------------------
-- c) venue_roster for supervisors
-- ---------------------------------------------------------------------------
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-0000000000a8';
select ok(
  (select count(*) from public.venue_roster('20000000-0000-0000-0000-0000000000aa')) >= 4,
  'a supervisor can read the venue roster'
);

-- ---------------------------------------------------------------------------
-- d) private-event reservations
-- ---------------------------------------------------------------------------
select throws_ok(
  $$ update public.reservations set beo_id = null where id = '51000000-0000-0000-0000-0000000000a1' $$,
  '42501', null,
  'a supervisor cannot detach a reservation from its private event'
);
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-0000000000a5';
select throws_ok(
  $$ update public.reservations set status = 'cancelled' where id = '51000000-0000-0000-0000-0000000000a1' $$,
  '42501', null,
  'staff cannot cancel a private-event reservation'
);
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-0000000000a4';
select lives_ok(
  $$ update public.reservations set status = 'cancelled' where id = '51000000-0000-0000-0000-0000000000a1' $$,
  'a manager can cancel a private-event reservation'
);

select * from finish();
rollback;

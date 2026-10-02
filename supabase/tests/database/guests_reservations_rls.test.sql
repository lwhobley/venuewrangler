-- pgTAP authorization and functionality tests for guests and reservations (20261002250000).
-- Fixtures: Org A, Venue A1 (manager 004, staff 005), Org B, Venue B1 (owner 006).

begin;
select plan(16);

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-000000000004', 'venue-a1-manager@example.com'),
  ('00000000-0000-0000-0000-000000000005', 'venue-a1-staff@example.com'),
  ('00000000-0000-0000-0000-000000000006', 'org-b-owner@example.com');

insert into public.organizations (id, name) values
  ('10000000-0000-0000-0000-00000000000a', 'Org A'),
  ('10000000-0000-0000-0000-00000000000b', 'Org B');

insert into public.venues (id, organization_id, name) values
  ('20000000-0000-0000-0000-0000000000a1', '10000000-0000-0000-0000-00000000000a', 'Venue A1'),
  ('20000000-0000-0000-0000-0000000000b1', '10000000-0000-0000-0000-00000000000b', 'Venue B1');

insert into public.memberships (user_id, organization_id, venue_id, role) values
  ('00000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-0000000000a1', 'venue_manager'),
  ('00000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-0000000000a1', 'staff'),
  ('00000000-0000-0000-0000-000000000006', '10000000-0000-0000-0000-00000000000b', null, 'organization_owner');

-- ---------------------------------------------------------------------------
-- 1. Trigger test: inserting guest derives organization_id
-- ---------------------------------------------------------------------------
insert into public.guests (id, venue_id, organization_id, full_name, email)
values (
  '30000000-0000-0000-0000-000000000001',
  '20000000-0000-0000-0000-0000000000a1',
  '10000000-0000-0000-0000-00000000000b', -- wrong org passed in
  'Alice Guest',
  'alice@example.com'
);

select results_eq(
  $$ select organization_id from public.guests where id = '30000000-0000-0000-0000-000000000001' $$,
  $$ values ('10000000-0000-0000-0000-00000000000a'::uuid) $$,
  'guest organization_id is derived from venue_id on insert, ignoring client-provided org'
);

-- ---------------------------------------------------------------------------
-- 2. Trigger test: updating venue_id on guest throws
-- ---------------------------------------------------------------------------
select throws_ok(
  $$ update public.guests set venue_id = '20000000-0000-0000-0000-0000000000b1' where id = '30000000-0000-0000-0000-000000000001' $$,
  '42501',
  null,
  'cannot modify guest venue_id once created'
);

-- ---------------------------------------------------------------------------
-- 3. Trigger test: inserting reservation derives organization_id
-- ---------------------------------------------------------------------------
insert into public.reservations (
  id, venue_id, organization_id, guest_id, guest_name, party_size, reservation_time
) values (
  '40000000-0000-0000-0000-000000000001',
  '20000000-0000-0000-0000-0000000000a1',
  '10000000-0000-0000-0000-00000000000b',
  '30000000-0000-0000-0000-000000000001',
  'Alice Guest',
  4,
  now() + interval '2 hours'
);

select results_eq(
  $$ select organization_id from public.reservations where id = '40000000-0000-0000-0000-000000000001' $$,
  $$ values ('10000000-0000-0000-0000-00000000000a'::uuid) $$,
  'reservation organization_id is derived from venue_id on insert'
);

-- ---------------------------------------------------------------------------
-- 4. Guest household links: same venue succeeds
-- ---------------------------------------------------------------------------
insert into public.guests (id, venue_id, organization_id, full_name, email)
values (
  '30000000-0000-0000-0000-000000000002',
  '20000000-0000-0000-0000-0000000000a1',
  '10000000-0000-0000-0000-00000000000a',
  'Bob Guest',
  'bob@example.com'
);

select lives_ok(
  $$ insert into public.guest_household_links (from_guest_id, to_guest_id, relationship)
     values ('30000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000002', 'spouse') $$,
  'linking two guests in the same venue succeeds'
);

-- ---------------------------------------------------------------------------
-- 5. Guest household links: self-link is forbidden
-- ---------------------------------------------------------------------------
select throws_ok(
  $$ insert into public.guest_household_links (from_guest_id, to_guest_id, relationship)
     values ('30000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001', 'self') $$,
  '23514',
  null,
  'cannot link guest to itself'
);

-- ---------------------------------------------------------------------------
-- 6. Guest household links: cross-venue link is forbidden
-- ---------------------------------------------------------------------------
insert into public.guests (id, venue_id, organization_id, full_name, email)
values (
  '30000000-0000-0000-0000-000000000003',
  '20000000-0000-0000-0000-0000000000b1',
  '10000000-0000-0000-0000-00000000000b',
  'Charlie Guest',
  'charlie@example.com'
);

select throws_ok(
  $$ insert into public.guest_household_links (from_guest_id, to_guest_id, relationship)
     values ('30000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000003', 'partner') $$,
  '42501',
  null,
  'cannot link guests belonging to different venues'
);

-- ---------------------------------------------------------------------------
-- 7 & 8. Webhook replay log: first call records, duplicate call is rejected
-- ---------------------------------------------------------------------------
select is(
  app_hidden.record_and_check_webhook_replay('20000000-0000-0000-0000-0000000000a1', 'whk-unique-12345'),
  true,
  'fresh webhook id is accepted and logged'
);

select is(
  app_hidden.record_and_check_webhook_replay('20000000-0000-0000-0000-0000000000a1', 'whk-unique-12345'),
  false,
  'replayed webhook id is rejected by replay log'
);

-- ---------------------------------------------------------------------------
-- 9 & 10. RLS: Venue staff can insert and select guests in their venue
-- ---------------------------------------------------------------------------
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000005';

select lives_ok(
  $$ insert into public.guests (venue_id, organization_id, full_name, phone)
     values ('20000000-0000-0000-0000-0000000000a1', '10000000-0000-0000-0000-00000000000a', 'Staff Guest', '555-0100') $$,
  'venue staff can insert guest into venue A1'
);

select results_ne(
  $$ select count(*)::int from public.guests where venue_id = '20000000-0000-0000-0000-0000000000a1' $$,
  $$ values (0) $$,
  'venue staff can select guests in their venue'
);

-- ---------------------------------------------------------------------------
-- 11. RLS: Org B owner CANNOT see guests in Venue A1
-- ---------------------------------------------------------------------------
reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000006';

select is_empty(
  $$ select id from public.guests where venue_id = '20000000-0000-0000-0000-0000000000a1' $$,
  'org B user cannot view guests from venue A1 (tenant isolation)'
);

-- ---------------------------------------------------------------------------
-- 12 & 13. RLS: Venue staff can insert and select reservations
-- ---------------------------------------------------------------------------
reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000005';

select lives_ok(
  $$ insert into public.reservations (
       venue_id, organization_id, guest_name, party_size, reservation_time
     ) values (
       '20000000-0000-0000-0000-0000000000a1', '10000000-0000-0000-0000-00000000000a',
       'Dinner Party', 6, now() + interval '1 day'
     ) $$,
  'venue staff can insert a reservation in venue A1'
);

select results_ne(
  $$ select count(*)::int from public.reservations where venue_id = '20000000-0000-0000-0000-0000000000a1' $$,
  $$ values (0) $$,
  'venue staff can select reservations in venue A1'
);

-- ---------------------------------------------------------------------------
-- 14. RLS: Org B user CANNOT see reservations in Venue A1
-- ---------------------------------------------------------------------------
reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000006';

select is_empty(
  $$ select id from public.reservations where venue_id = '20000000-0000-0000-0000-0000000000a1' $$,
  'org B user cannot view reservations from venue A1 (tenant isolation)'
);

-- ---------------------------------------------------------------------------
-- 15. RLS: Staff member cannot delete reservation (managers only)
-- ---------------------------------------------------------------------------
reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000005';

delete from public.reservations where id = '40000000-0000-0000-0000-000000000001';

select isnt_empty(
  $$ select id from public.reservations where id = '40000000-0000-0000-0000-000000000001' $$,
  'reservation delete by staff member is blocked by RLS'
);

-- ---------------------------------------------------------------------------
-- 16. Column Security: Authenticated user cannot select webhook_secret_hash
-- ---------------------------------------------------------------------------
reset role;
insert into public.reservation_connections (
  venue_id, provider, webhook_secret_hash
) values (
  '20000000-0000-0000-0000-0000000000a1',
  'sevenrooms',
  'super-secret-hash-123'
);

set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000004'; -- venue manager

select throws_ok(
  $$ select webhook_secret_hash from public.reservation_connections $$,
  '42501',
  null,
  'authenticated user cannot select webhook_secret_hash from reservation_connections (column grant restricted)'
);

select * from finish();
rollback;

-- pgTAP tests for supabase/migrations/20261013100000_review_fixes_db_part1.sql:
-- floor release (1), walk-in seating (14), stale venue-scope triggers (15) and checkout
-- single-flight (13). Each block names the finding it covers.

begin;
select plan(17);

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000001a1', 'p1-staff@example.com'),
  ('00000000-0000-0000-0000-0000000001a2', 'p1-staff2@example.com'),
  ('00000000-0000-0000-0000-0000000001b1', 'p1-org-b-owner@example.com');

insert into public.organizations (id, name) values
  ('10000000-0000-0000-0000-0000000000a1', 'P1 Org A'),
  ('10000000-0000-0000-0000-0000000000b1', 'P1 Org B');

insert into public.venues (id, organization_id, name) values
  ('20000000-0000-0000-0000-0000000001a1', '10000000-0000-0000-0000-0000000000a1', 'P1 Venue A1'),
  ('20000000-0000-0000-0000-0000000001b1', '10000000-0000-0000-0000-0000000000b1', 'P1 Venue B1');

insert into public.memberships (user_id, organization_id, venue_id, role) values
  ('00000000-0000-0000-0000-0000000001a1', '10000000-0000-0000-0000-0000000000a1', '20000000-0000-0000-0000-0000000001a1', 'staff'),
  ('00000000-0000-0000-0000-0000000001a2', '10000000-0000-0000-0000-0000000000a1', '20000000-0000-0000-0000-0000000001a1', 'staff'),
  ('00000000-0000-0000-0000-0000000001b1', '10000000-0000-0000-0000-0000000000b1', null, 'organization_owner');

insert into public.floor_plans (id, venue_id, organization_id, name) values
  ('30000000-0000-0000-0000-0000000001a1', '20000000-0000-0000-0000-0000000001a1', '10000000-0000-0000-0000-0000000000a1', 'Main');

-- T1 reservable; W1 and W2 non-reservable walk-in tables; D1 non-reservable and dirty.
insert into public.floor_tables (id, floor_plan_id, venue_id, organization_id, label, capacity, is_reservable, status) values
  ('40000000-0000-0000-0000-0000000001a1', '30000000-0000-0000-0000-0000000001a1', '20000000-0000-0000-0000-0000000001a1', '10000000-0000-0000-0000-0000000000a1', 'T1', 4, true, 'available'),
  ('40000000-0000-0000-0000-0000000001a2', '30000000-0000-0000-0000-0000000001a1', '20000000-0000-0000-0000-0000000001a1', '10000000-0000-0000-0000-0000000000a1', 'W1', 4, false, 'available'),
  ('40000000-0000-0000-0000-0000000001a3', '30000000-0000-0000-0000-0000000001a1', '20000000-0000-0000-0000-0000000001a1', '10000000-0000-0000-0000-0000000000a1', 'W2', 4, false, 'available'),
  ('40000000-0000-0000-0000-0000000001a4', '30000000-0000-0000-0000-0000000001a1', '20000000-0000-0000-0000-0000000001a1', '10000000-0000-0000-0000-0000000000a1', 'D1', 4, false, 'dirty');

insert into public.reservations (id, venue_id, organization_id, guest_name, party_size, reservation_time, assigned_to) values
  ('50000000-0000-0000-0000-0000000001a1', '20000000-0000-0000-0000-0000000001a1', '10000000-0000-0000-0000-0000000000a1', 'R1', 2, now(), null),
  ('50000000-0000-0000-0000-0000000001a2', '20000000-0000-0000-0000-0000000001a1', '10000000-0000-0000-0000-0000000000a1', 'R2', 2, now(), null),
  ('50000000-0000-0000-0000-0000000001a3', '20000000-0000-0000-0000-0000000001a1', '10000000-0000-0000-0000-0000000000a1', 'Walk-in', 2, now(), null),
  ('50000000-0000-0000-0000-0000000001a4', '20000000-0000-0000-0000-0000000001a1', '10000000-0000-0000-0000-0000000000a1', 'Walk-in 2', 2, now(), null),
  ('50000000-0000-0000-0000-0000000001a5', '20000000-0000-0000-0000-0000000001a1', '10000000-0000-0000-0000-0000000000a1', 'Scope', 2, now(),
   '00000000-0000-0000-0000-0000000001a2');

-- ---------------------------------------------------------------------------
-- 1. Floor release: seat R1 at T1, release it, then R2 can take T1.
-- ---------------------------------------------------------------------------
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-0000000001a1';

select lives_ok(
  $$ select public.assign_tables_to_reservation(
       '20000000-0000-0000-0000-0000000001a1',
       array['40000000-0000-0000-0000-0000000001a1']::uuid[],
       '50000000-0000-0000-0000-0000000001a1', 'reserved') $$,
  'F1: staff seats R1 at T1'
);

select throws_ok(
  $$ select public.assign_tables_to_reservation(
       '20000000-0000-0000-0000-0000000001a1',
       array['40000000-0000-0000-0000-0000000001a1']::uuid[],
       '50000000-0000-0000-0000-0000000001a2', 'reserved') $$,
  '23P01', null,
  'F1: an overlapping seat of T1 without a release is still rejected'
);

select is(
  public.release_table_assignments(
    '20000000-0000-0000-0000-0000000001a1',
    array['40000000-0000-0000-0000-0000000001a1']::uuid[],
    '50000000-0000-0000-0000-0000000001a1'
  ),
  1,
  'F1: release_table_assignments releases R1 on T1'
);

set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-0000000001b1';
select throws_ok(
  $$ select public.release_table_assignments(
       '20000000-0000-0000-0000-0000000001a1',
       array['40000000-0000-0000-0000-0000000001a1']::uuid[]) $$,
  '42501', null,
  'F1: an organization owner of another venue cannot release assignments here'
);

set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-0000000001a1';
select lives_ok(
  $$ select public.assign_tables_to_reservation(
       '20000000-0000-0000-0000-0000000001a1',
       array['40000000-0000-0000-0000-0000000001a1']::uuid[],
       '50000000-0000-0000-0000-0000000001a2', 'reserved') $$,
  'F1: after release, R2 can be seated at T1'
);

select ok(
  exists (
    select 1 from public.floor_table_assignments
    where reservation_id = '50000000-0000-0000-0000-0000000001a1' and released_at is not null
  ),
  'F1: the R1 assignment carries released_at'
);

-- Completing R2 and moving T1 to available releases its unreleased assignment.
reset role;
update public.reservations set status = 'completed'
  where id = '50000000-0000-0000-0000-0000000001a2';
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-0000000001a1';

select lives_ok(
  $$ select public.update_floor_table_status(
       '20000000-0000-0000-0000-0000000001a1',
       '40000000-0000-0000-0000-0000000001a1', 'available') $$,
  'F1: staff sets T1 to available'
);

select ok(
  exists (
    select 1 from public.floor_table_assignments
    where reservation_id = '50000000-0000-0000-0000-0000000001a2' and released_at is not null
  ),
  'F1: moving a table to available releases the assignment of a completed reservation'
);

-- ---------------------------------------------------------------------------
-- 14. Walk-in seating on non-reservable tables
-- ---------------------------------------------------------------------------
select lives_ok(
  $$ select public.assign_tables_to_reservation(
       '20000000-0000-0000-0000-0000000001a1',
       array['40000000-0000-0000-0000-0000000001a2']::uuid[],
       '50000000-0000-0000-0000-0000000001a3', 'seated') $$,
  'F14: a walk-in can be seated on a non-reservable table'
);

select throws_ok(
  $$ select public.assign_tables_to_reservation(
       '20000000-0000-0000-0000-0000000001a1',
       array['40000000-0000-0000-0000-0000000001a3']::uuid[],
       '50000000-0000-0000-0000-0000000001a4', 'reserved') $$,
  '22023', null,
  'F14: a non-reservable table still cannot be reserved'
);

select throws_ok(
  $$ select public.assign_tables_to_reservation(
       '20000000-0000-0000-0000-0000000001a1',
       array['40000000-0000-0000-0000-0000000001a4']::uuid[],
       '50000000-0000-0000-0000-0000000001a4', 'seated') $$,
  '22023', null,
  'F14: a dirty table cannot be seated even for a walk-in'
);

-- ---------------------------------------------------------------------------
-- 15. Stale venue-scope references do not block unrelated updates
-- ---------------------------------------------------------------------------
reset role;
delete from public.memberships
  where user_id = '00000000-0000-0000-0000-0000000001a2'
    and venue_id = '20000000-0000-0000-0000-0000000001a1';

select lives_ok(
  $$ update public.reservations
     set assigned_to = assigned_to, status = 'confirmed'
     where id = '50000000-0000-0000-0000-0000000001a5' $$,
  'F15: an unchanged stale staff assignment can still be updated'
);

select throws_ok(
  $$ update public.reservations
     set assigned_to = '00000000-0000-0000-0000-0000000001b1'
     where id = '50000000-0000-0000-0000-0000000001a5' $$,
  '23503', null,
  'F15: a changed assignment to a non-member is still rejected'
);

-- ---------------------------------------------------------------------------
-- 13. Checkout single-flight: a forced claim within 10 seconds of a recorded session keeps it.
-- ---------------------------------------------------------------------------
select lives_ok(
  $$ select * from public.claim_subscription_checkout_attempt('10000000-0000-0000-0000-0000000000a1', false) $$,
  'F13: first checkout claim creates an attempt'
);

select lives_ok(
  $$ select public.record_subscription_checkout_session(
       '10000000-0000-0000-0000-0000000000a1',
       (select s.idempotency_key from public.subscription_checkout_attempts s
         where s.organization_id = '10000000-0000-0000-0000-0000000000a1'),
       'cs_p1_recorded', now() + interval '30 minutes') $$,
  'F13: the Stripe session is recorded against the attempt'
);

select is(
  (select c.stripe_session_id from public.claim_subscription_checkout_attempt(
     '10000000-0000-0000-0000-0000000000a1', true) c),
  'cs_p1_recorded',
  'F13: a forced claim within 10 seconds returns the existing session instead of rotating'
);

update public.subscription_checkout_attempts
  set updated_at = now() - interval '1 minute'
  where organization_id = '10000000-0000-0000-0000-0000000000a1';

select is(
  (select c.stripe_session_id from public.claim_subscription_checkout_attempt(
     '10000000-0000-0000-0000-0000000000a1', true) c),
  null::text,
  'F13: a forced claim after the 10 second window rotates the attempt'
);

select * from finish();
rollback;

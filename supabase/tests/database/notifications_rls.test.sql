-- pgTAP authorization and functionality tests for notifications (supabase/migrations/20261002240000).
-- Fixture: org A (owner ...002), venue A1 (manager ...004, staff 1 ...005, staff 2 ...008), org B (owner ...006).

begin;
select plan(16);

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-000000000002', 'org-a-owner@example.com'),
  ('00000000-0000-0000-0000-000000000004', 'venue-a1-manager@example.com'),
  ('00000000-0000-0000-0000-000000000005', 'venue-a1-staff@example.com'),
  ('00000000-0000-0000-0000-000000000006', 'org-b-owner@example.com'),
  ('00000000-0000-0000-0000-000000000008', 'venue-a1-staff-2@example.com');

insert into public.organizations (id, name) values
  ('10000000-0000-0000-0000-00000000000a', 'Org A'),
  ('10000000-0000-0000-0000-00000000000b', 'Org B');

insert into public.venues (id, organization_id, name) values
  ('20000000-0000-0000-0000-0000000000a1', '10000000-0000-0000-0000-00000000000a', 'Venue A1'),
  ('20000000-0000-0000-0000-0000000000b1', '10000000-0000-0000-0000-00000000000b', 'Venue B1');

insert into public.memberships (user_id, organization_id, venue_id, role) values
  ('00000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-00000000000a', null, 'organization_owner'),
  ('00000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-0000000000a1', 'venue_manager'),
  ('00000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-0000000000a1', 'staff'),
  ('00000000-0000-0000-0000-000000000008', '10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-0000000000a1', 'staff'),
  ('00000000-0000-0000-0000-000000000006', '10000000-0000-0000-0000-00000000000b', null, 'organization_owner');

-- ---------------------------------------------------------------------------
-- 1. Push token registration: positive (staff member)
-- ---------------------------------------------------------------------------
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000005';

select lives_ok(
  $$ select public.register_push_token('20000000-0000-0000-0000-0000000000a1', 'fcm-device-token-111', 'android') $$,
  'staff 1 can register device push token for venue A1'
);

-- ---------------------------------------------------------------------------
-- 2. Push token registration: negative (non-member)
-- ---------------------------------------------------------------------------
reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000006';

select throws_ok(
  $$ select public.register_push_token('20000000-0000-0000-0000-0000000000a1', 'fcm-device-token-999', 'android') $$,
  '42501',
  null,
  'non-member cannot register push token for venue A1'
);

-- ---------------------------------------------------------------------------
-- 3. RLS: staff 1 can view own push token
-- ---------------------------------------------------------------------------
reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000005';

select is(
  (select count(*)::integer from public.push_tokens where token = 'fcm-device-token-111'),
  1,
  'staff 1 can view own registered push token'
);

-- ---------------------------------------------------------------------------
-- 4. RLS: staff 2 cannot view staff 1's push token
-- ---------------------------------------------------------------------------
reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000008';

select is(
  (select count(*)::integer from public.push_tokens where token = 'fcm-device-token-111'),
  0,
  'staff 2 cannot view staff 1 registered token'
);

-- ---------------------------------------------------------------------------
-- 5. Anti-hijack: staff 2 claiming existing token at same venue is rejected
-- ---------------------------------------------------------------------------
select throws_ok(
  $$ select public.register_push_token('20000000-0000-0000-0000-0000000000a1', 'fcm-device-token-111', 'android') $$,
  '42501',
  null,
  'different profile claiming same token at same venue is rejected'
);

-- ---------------------------------------------------------------------------
-- 6. Idempotent upsert: staff 1 re-registering updates last_seen_at
-- ---------------------------------------------------------------------------
reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000005';

select lives_ok(
  $$ select public.register_push_token('20000000-0000-0000-0000-0000000000a1', 'fcm-device-token-111', 'android') $$,
  'same profile can re-register token idempotently'
);

-- ---------------------------------------------------------------------------
-- 7. Dead token disabling
-- ---------------------------------------------------------------------------
reset role;

select is(
  app_hidden.disable_push_tokens(array['fcm-device-token-111']),
  1,
  'disable_push_tokens disables matched active token'
);

select is(
  (select enabled from public.push_tokens where token = 'fcm-device-token-111'),
  false,
  'push token enabled flag set to false'
);

-- ---------------------------------------------------------------------------
-- 8 & 9. Notification events: insert and target user visibility
-- ---------------------------------------------------------------------------
insert into public.notification_events (
  id, venue_id, target_user_id, audience, kind, title, body
) values (
  'b0000000-0000-0000-0000-000000000001',
  '20000000-0000-0000-0000-0000000000a1',
  '00000000-0000-0000-0000-000000000005',
  'user',
  'shift_assigned',
  'New Shift Assigned',
  'You have been scheduled for Friday 5 PM.'
);

set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000005';

select is(
  (select count(*)::integer from public.notification_events where id = 'b0000000-0000-0000-0000-000000000001'),
  1,
  'target user can view their user-scoped notification event'
);

-- ---------------------------------------------------------------------------
-- 10. Non-target user cannot view user-scoped notification
-- ---------------------------------------------------------------------------
reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000008';

select is(
  (select count(*)::integer from public.notification_events where id = 'b0000000-0000-0000-0000-000000000001'),
  0,
  'other staff member cannot view target user notification'
);

-- ---------------------------------------------------------------------------
-- 11 & 12. Audience: venue_managers
-- ---------------------------------------------------------------------------
reset role;
insert into public.notification_events (
  id, venue_id, audience, kind, title, body
) values (
  'b0000000-0000-0000-0000-000000000002',
  '20000000-0000-0000-0000-0000000000a1',
  'venue_managers',
  'late_clock_in',
  'Late Clock-in Alert',
  'Staff member has not clocked in 15m after shift start.'
);

-- Venue manager can see manager-audience event
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000004';

select is(
  (select count(*)::integer from public.notification_events where id = 'b0000000-0000-0000-0000-000000000002'),
  1,
  'venue manager can view venue_managers audience event'
);

-- Regular staff cannot see manager-audience event
reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000005';

select is(
  (select count(*)::integer from public.notification_events where id = 'b0000000-0000-0000-0000-000000000002'),
  0,
  'regular staff cannot view venue_managers audience event'
);

-- ---------------------------------------------------------------------------
-- 13. Audience: venue_staff is visible to all venue staff
-- ---------------------------------------------------------------------------
reset role;
insert into public.notification_events (
  id, venue_id, audience, kind, title, body
) values (
  'b0000000-0000-0000-0000-000000000003',
  '20000000-0000-0000-0000-0000000000a1',
  'venue_staff',
  'announcement',
  'Staff Meeting',
  'All-hands meeting tomorrow at 2 PM.'
);

set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000005';

select is(
  (select count(*)::integer from public.notification_events where id = 'b0000000-0000-0000-0000-000000000003'),
  1,
  'venue staff can view venue_staff broadcast event'
);

-- ---------------------------------------------------------------------------
-- 14. Cross-tenant isolation (Org B cannot view Org A notifications)
-- ---------------------------------------------------------------------------
reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000006';

select is(
  (select count(*)::integer from public.notification_events where venue_id = '20000000-0000-0000-0000-0000000000a1'),
  0,
  'org B user cannot view org A venue notifications'
);

-- ---------------------------------------------------------------------------
-- 15. Update: user can mark own notification read
-- ---------------------------------------------------------------------------
reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000005';

select lives_ok(
  $$ update public.notification_events set read_at = now() where id = 'b0000000-0000-0000-0000-000000000001' $$,
  'target user can mark notification as read'
);

select throws_ok(
  $$ update public.notification_events set title = 'forged' where id = 'b0000000-0000-0000-0000-000000000001' $$,
  '42501', null, 'recipient cannot change notification contents'
);

select * from finish();
rollback;

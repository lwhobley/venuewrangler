-- pgTAP tests for the review-fix migration 20261012100000_review_fixes_tenant_integrity.sql.
-- Each block names the finding it covers. Setup runs as the table owner; authorization
-- checks impersonate users with `set local role authenticated` and the JWT sub claim.

begin;
select plan(50);

-- Users
insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000000a1', 'multi-org-owner@example.com'),
  ('00000000-0000-0000-0000-0000000000a4', 'venue-a1-manager@example.com'),
  ('00000000-0000-0000-0000-0000000000a5', 'venue-a1-staff1@example.com'),
  ('00000000-0000-0000-0000-0000000000a8', 'venue-a1-staff2@example.com'),
  ('00000000-0000-0000-0000-0000000000a9', 'venue-a1-staff3@example.com'),
  ('00000000-0000-0000-0000-0000000000a6', 'org-b-owner@example.com');

insert into public.organizations (id, name) values
  ('10000000-0000-0000-0000-00000000000a', 'Org A'),
  ('10000000-0000-0000-0000-00000000000b', 'Org B');

-- Venue A1 at downtown Houston with a 100 m geofence; B1 has no geofence coordinates.
insert into public.venues (id, organization_id, name, latitude, longitude, geofence_radius_m) values
  ('20000000-0000-0000-0000-0000000000a1', '10000000-0000-0000-0000-00000000000a', 'Venue A1', 29.7604, -95.3698, 100),
  ('20000000-0000-0000-0000-0000000000b1', '10000000-0000-0000-0000-00000000000b', 'Venue B1', null, null, 100);

insert into public.memberships (user_id, organization_id, venue_id, role) values
  ('00000000-0000-0000-0000-0000000000a1', '10000000-0000-0000-0000-00000000000a', null, 'organization_owner'),
  ('00000000-0000-0000-0000-0000000000a1', '10000000-0000-0000-0000-00000000000b', null, 'organization_owner'),
  ('00000000-0000-0000-0000-0000000000a6', '10000000-0000-0000-0000-00000000000b', null, 'organization_owner'),
  ('00000000-0000-0000-0000-0000000000a4', '10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-0000000000a1', 'venue_manager'),
  ('00000000-0000-0000-0000-0000000000a5', '10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-0000000000a1', 'staff'),
  ('00000000-0000-0000-0000-0000000000a8', '10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-0000000000a1', 'staff'),
  ('00000000-0000-0000-0000-0000000000a9', '10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-0000000000a1', 'staff');

-- ---------------------------------------------------------------------------
-- F2. Removed staff lose conversation access
-- ---------------------------------------------------------------------------
reset role;
-- Clear the JWT claim left by the F1 block so the owner-side fixture inserts run as no user.
set local "request.jwt.claim.sub" to '';
insert into public.conversations (id, venue_id, type, name) values
  ('b0000000-0000-0000-0000-0000000000d1', '20000000-0000-0000-0000-0000000000a1', 'dm', null);
insert into public.conversation_members (conversation_id, user_id) values
  ('b0000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000a5'),
  ('b0000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000a8');
insert into public.messages (id, conversation_id, sender_id, text, venue_id, organization_id) values
  ('d0000000-0000-0000-0000-0000000000d1', 'b0000000-0000-0000-0000-0000000000d1',
   '00000000-0000-0000-0000-0000000000a8', 'secret', '20000000-0000-0000-0000-0000000000a1',
   '10000000-0000-0000-0000-00000000000a');

set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-0000000000a5';
select is(
  (select count(*)::integer from public.conversations where id = 'b0000000-0000-0000-0000-0000000000d1'),
  1,
  'F2: a DM member can see the DM before removal'
);

-- Membership removal with the cascade trigger in place
reset role;
delete from public.memberships
  where user_id = '00000000-0000-0000-0000-0000000000a5'
    and venue_id = '20000000-0000-0000-0000-0000000000a1';

select is(
  (select count(*)::integer from public.conversation_members
    where user_id = '00000000-0000-0000-0000-0000000000a5'),
  0,
  'F2: removing a venue membership deletes that user''s conversation_members rows'
);

-- Restore S1's membership and DM row, then remove it again with the cascade trigger disabled,
-- so the stale row survives and only the is_conversation_member check can deny access.
insert into public.memberships (user_id, organization_id, venue_id, role) values
  ('00000000-0000-0000-0000-0000000000a5', '10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-0000000000a1', 'staff');
insert into public.conversation_members (conversation_id, user_id) values
  ('b0000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000a5');

alter table public.memberships disable trigger trg_memberships_revoke_conversations;
delete from public.memberships
  where user_id = '00000000-0000-0000-0000-0000000000a5'
    and venue_id = '20000000-0000-0000-0000-0000000000a1';
alter table public.memberships enable trigger trg_memberships_revoke_conversations;

select is(
  app_hidden.is_conversation_member('b0000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000a5'),
  false,
  'F2: is_conversation_member is false for a stale row without live venue membership'
);

select is(
  app_hidden.is_conversation_member('b0000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000a8'),
  true,
  'F2: a remaining member is still a conversation member'
);

set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-0000000000a5';
select is(
  (select count(*)::integer from public.messages where conversation_id = 'b0000000-0000-0000-0000-0000000000d1'),
  0,
  'F2: a removed member cannot read DM messages'
);

-- Fixture restore for later blocks (not a counted test): S1 is a venue staff member again.
reset role;
insert into public.memberships (user_id, organization_id, venue_id, role) values
  ('00000000-0000-0000-0000-0000000000a5', '10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-0000000000a1', 'staff')
  on conflict do nothing;
delete from public.conversation_members
  where user_id = '00000000-0000-0000-0000-0000000000a5';
insert into public.conversation_members (conversation_id, user_id) values
  ('b0000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000a5');

-- ---------------------------------------------------------------------------
-- F3. Clock-out requires device location for staff; managers may close remotely
-- ---------------------------------------------------------------------------
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-0000000000a5';
insert into public.time_entries (id, venue_id, clock_in_lat, clock_in_lng, clock_in_accuracy_m) values
  ('80000000-0000-0000-0000-0000000000e1', '20000000-0000-0000-0000-0000000000a1', 29.76041, -95.36981, 15.0);

select throws_ok(
  $$ update public.time_entries set is_open = false where id = '80000000-0000-0000-0000-0000000000e1' $$,
  '42501',
  'Clock-out location and accuracy are required',
  'F3: staff cannot clock out without a location fix'
);

select lives_ok(
  $$ update public.time_entries
     set is_open = false, clock_out_lat = 29.76041, clock_out_lng = -95.36981,
         clock_out_accuracy_m = 12.0, clock_out_mocked = false
     where id = '80000000-0000-0000-0000-0000000000e1' $$,
  'F3: staff can clock out with a location fix inside the geofence'
);

set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-0000000000a8';
insert into public.time_entries (id, venue_id, clock_in_lat, clock_in_lng, clock_in_accuracy_m) values
  ('80000000-0000-0000-0000-0000000000e2', '20000000-0000-0000-0000-0000000000a1', 29.76041, -95.36981, 15.0);

set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-0000000000a4';
select lives_ok(
  $$ update public.time_entries set is_open = false
     where id = '80000000-0000-0000-0000-0000000000e2' $$,
  'F3: a venue manager can close a team member''s entry remotely'
);

-- ---------------------------------------------------------------------------
-- F4. correct_time_entry: sane clock-out window and no self-correction
-- ---------------------------------------------------------------------------
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-0000000000a9';
insert into public.time_entries (id, venue_id, clock_in_lat, clock_in_lng, clock_in_accuracy_m) values
  ('80000000-0000-0000-0000-0000000000e3', '20000000-0000-0000-0000-0000000000a1', 29.76041, -95.36981, 15.0);

set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-0000000000a4';
select throws_ok(
  $$ select public.correct_time_entry('80000000-0000-0000-0000-0000000000e3',
       (select clock_in_at from public.time_entries where id = '80000000-0000-0000-0000-0000000000e3') - interval '1 hour', null, 'clock-out before clock-in') $$,
  '22023',
  null,
  'F4: a clock-out before clock-in is rejected'
);

select throws_ok(
  $$ select public.correct_time_entry('80000000-0000-0000-0000-0000000000e3', now() + interval '5 minutes', null, 'clock-out in the future') $$,
  '22023',
  null,
  'F4: a clock-out in the future is rejected'
);

-- Manager's own entry
insert into public.time_entries (id, venue_id, clock_in_lat, clock_in_lng, clock_in_accuracy_m) values
  ('80000000-0000-0000-0000-0000000000e4', '20000000-0000-0000-0000-0000000000a1', 29.76041, -95.36981, 15.0);

select throws_ok(
  $$ select public.correct_time_entry('80000000-0000-0000-0000-0000000000e4', now() + interval '1 second', null, 'self') $$,
  '42501',
  'managers cannot correct their own time entries',
  'F4: a manager cannot correct their own time entry'
);

select lives_ok(
  $$ select public.correct_time_entry('80000000-0000-0000-0000-0000000000e3',
       now() + interval '1 second', null, 'valid window') $$,
  'F4: a manager can correct a team member entry to a valid clock-out'
);

-- ---------------------------------------------------------------------------
-- F5. Manager-recorded punches: user and shift must belong to the venue
-- ---------------------------------------------------------------------------
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-0000000000a4';
select throws_ok(
  $$ insert into public.time_entries (venue_id, user_id, clock_in_lat, clock_in_lng, clock_in_accuracy_m)
     values ('20000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a6', 29.76041, -95.36981, 15.0) $$,
  '23503',
  null,
  'F5: a manager cannot punch in a user outside the venue or organization'
);

select lives_ok(
  $$ insert into public.time_entries (venue_id, user_id, clock_in_lat, clock_in_lng, clock_in_accuracy_m)
     values ('20000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a8', 29.76041, -95.36981, 15.0) $$,
  'F5: a manager can punch in a venue team member'
);

reset role;
insert into public.shifts (id, organization_id, venue_id, start_time, end_time) values
  ('e7000000-0000-0000-0000-0000000000b1', '10000000-0000-0000-0000-00000000000b', '20000000-0000-0000-0000-0000000000b1',
   now() + interval '1 day', now() + interval '1 day 8 hours');
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-0000000000a5';
select throws_ok(
  $$ insert into public.time_entries (venue_id, shift_id, clock_in_lat, clock_in_lng, clock_in_accuracy_m)
     values ('20000000-0000-0000-0000-0000000000a1', 'e7000000-0000-0000-0000-0000000000b1', 29.76041, -95.36981, 15.0) $$,
  '23503',
  null,
  'F5: a punch cannot reference a shift from another venue'
);

-- ---------------------------------------------------------------------------
-- F6. reservations.beo_id must reference a BEO in the same venue
-- ---------------------------------------------------------------------------
reset role;
insert into public.crm_beos (id, organization_id, venue_id, event_name) values
  ('c0000000-0000-0000-0000-0000000000b1', '10000000-0000-0000-0000-00000000000b',
   '20000000-0000-0000-0000-0000000000b1', 'B1 gala'),
  ('c0000000-0000-0000-0000-0000000000a1', '10000000-0000-0000-0000-00000000000a',
   '20000000-0000-0000-0000-0000000000a1', 'A1 dinner');

select throws_ok(
  $$ insert into public.reservations (organization_id, venue_id, guest_name, party_size, reservation_time, beo_id)
     values ('10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-0000000000a1',
             'Guest', 2, now() + interval '3 days', 'c0000000-0000-0000-0000-0000000000b1') $$,
  '23503',
  null,
  'F6: a reservation cannot link a BEO from another venue'
);

select lives_ok(
  $$ insert into public.reservations (organization_id, venue_id, guest_name, party_size, reservation_time, beo_id)
     values ('10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-0000000000a1',
             'Guest', 2, now() + interval '4 days', 'c0000000-0000-0000-0000-0000000000a1') $$,
  'F6: a reservation can link a BEO in its own venue'
);

-- ---------------------------------------------------------------------------
-- F7. Two confirmed BEOs may not overlap, even after a hold is cancelled
-- ---------------------------------------------------------------------------
update public.crm_beos set event_date = '2030-06-01 18:00+00', status = 'confirmed'
  where id = 'c0000000-0000-0000-0000-0000000000a1';
-- The BEO-A1 hold is cancelled directly, which previously freed the window.
update public.reservations set status = 'cancelled' where beo_id = 'c0000000-0000-0000-0000-0000000000a1';

insert into public.crm_beos (id, organization_id, venue_id, event_name, event_date, status) values
  ('c0000000-0000-0000-0000-0000000000a2', '10000000-0000-0000-0000-00000000000a',
   '20000000-0000-0000-0000-0000000000a1', 'overlapping', '2030-06-01 19:00+00', 'draft');

select throws_ok(
  $$ update public.crm_beos set status = 'confirmed' where id = 'c0000000-0000-0000-0000-0000000000a2' $$,
  '23505',
  null,
  'F7: a BEO cannot be confirmed over another confirmed BEO even when its hold is cancelled'
);

insert into public.crm_beos (id, organization_id, venue_id, event_name, event_date, status) values
  ('c0000000-0000-0000-0000-0000000000a3', '10000000-0000-0000-0000-00000000000a',
   '20000000-0000-0000-0000-0000000000a1', 'later', '2030-06-01 23:00+00', 'draft');

select lives_ok(
  $$ update public.crm_beos set status = 'confirmed' where id = 'c0000000-0000-0000-0000-0000000000a3' $$,
  'F7: a non-overlapping BEO can still be confirmed'
);

-- ---------------------------------------------------------------------------
-- F8. unregister_push_token only disables the caller's own token
-- ---------------------------------------------------------------------------
reset role;
insert into public.push_tokens (organization_id, venue_id, user_id, token, platform) values
  ('10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-0000000000a1',
   '00000000-0000-0000-0000-0000000000a5', 'fcm-review-token-0001', 'android');

set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-0000000000a8';
select lives_ok(
  $$ select public.unregister_push_token('fcm-review-token-0001') $$,
  'F8: another user can call unregister without an error'
);
reset role;
select is(
  (select enabled from public.push_tokens where token = 'fcm-review-token-0001'),
  true,
  'F8: another user cannot disable a token they do not own'
);

set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-0000000000a5';
select lives_ok(
  $$ select public.unregister_push_token('fcm-review-token-0001') $$,
  'F8: the owner can unregister their own token'
);
reset role;
select is(
  (select enabled from public.push_tokens where token = 'fcm-review-token-0001'),
  false,
  'F8: the owner''s token is disabled'
);

-- ---------------------------------------------------------------------------
-- F10. Expired AI reservations cannot be committed
-- ---------------------------------------------------------------------------
insert into public.ai_budget_reservations (id, organization_id, reserved_usd, status, expires_at) values
  ('a1000000-0000-0000-0000-0000000000e1', '10000000-0000-0000-0000-00000000000a', 0.5, 'pending', now() - interval '1 minute'),
  ('a1000000-0000-0000-0000-0000000000e2', '10000000-0000-0000-0000-00000000000a', 0.5, 'pending', now() + interval '1 hour');

select throws_ok(
  $$ select public.commit_ai_reservation('a1000000-0000-0000-0000-0000000000e1',
       '10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-0000000000a1',
       '00000000-0000-0000-0000-0000000000a5', 'summary', 'model-x', 10, 10, 0.01) $$,
  '22023',
  'AI reservation expired',
  'F10: an expired pending reservation cannot be committed'
);

select lives_ok(
  $$ select public.commit_ai_reservation('a1000000-0000-0000-0000-0000000000e2',
       '10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-0000000000a1',
       '00000000-0000-0000-0000-0000000000a5', 'summary', 'model-x', 10, 10, 0.01) $$,
  'F10: an unexpired pending reservation can be committed'
);

-- ---------------------------------------------------------------------------
-- F11. create_or_get_dm rejects self-DMs and returns the existing DM
-- ---------------------------------------------------------------------------
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-0000000000a5';
select throws_ok(
  $$ select public.create_or_get_dm('20000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a5') $$,
  '22023',
  null,
  'F11: a user cannot open a DM with themselves'
);

select is(
  public.create_or_get_dm('20000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a8'),
  'b0000000-0000-0000-0000-0000000000d1'::uuid,
  'F11: an existing DM for the pair is returned'
);

-- ---------------------------------------------------------------------------
-- F12. Fully signed contracts freeze the remaining terms
-- ---------------------------------------------------------------------------
reset role;
-- Seed a signed contract the way record_contract_signature would (the guard refuses direct writes).
do $$ begin perform set_config('app.contract_signing', 'on', true); end $$;
insert into public.crm_contracts (id, organization_id, venue_id, contract_number, client_signature_name)
  values ('d1000000-0000-0000-0000-0000000000c1', '10000000-0000-0000-0000-00000000000a',
          '20000000-0000-0000-0000-0000000000a1', 'CT-REVIEW-1', 'Pat Client');
update public.crm_contracts set status = 'fully_signed' where id = 'd1000000-0000-0000-0000-0000000000c1';
do $$ begin perform set_config('app.contract_signing', 'off', true); end $$;

select throws_ok(
  $$ update public.crm_contracts set payment_schedule = '[{"amount":1}]'::jsonb
     where id = 'd1000000-0000-0000-0000-0000000000c1' $$,
  '42501',
  null,
  'F12: a fully signed contract''s payment schedule is frozen'
);

select throws_ok(
  $$ update public.crm_contracts set client_signature_name = 'Other Person'
     where id = 'd1000000-0000-0000-0000-0000000000c1' $$,
  '42501',
  null,
  'F12: a fully signed contract''s client signature is frozen'
);

select throws_ok(
  $$ update public.crm_contracts set force_majeure = true
     where id = 'd1000000-0000-0000-0000-0000000000c1' $$,
  '42501',
  null,
  'F12: a fully signed contract''s force majeure term is frozen'
);

-- ---------------------------------------------------------------------------
-- F13. shifts / events / shift_insights / checklist_completions venue_id is immutable
-- ---------------------------------------------------------------------------
insert into public.shifts (id, organization_id, venue_id, start_time, end_time) values
  ('e1000000-0000-0000-0000-0000000000a1', '10000000-0000-0000-0000-00000000000a',
   '20000000-0000-0000-0000-0000000000a1', now() + interval '2 days', now() + interval '2 days 4 hours');
insert into public.events (id, organization_id, venue_id, name, start_time, end_time) values
  ('e2000000-0000-0000-0000-0000000000a1', '10000000-0000-0000-0000-00000000000a',
   '20000000-0000-0000-0000-0000000000a1', 'Quiz', now() + interval '2 days', now() + interval '2 days 2 hours');
insert into public.shift_insights (id, organization_id, venue_id, title, body) values
  ('e3000000-0000-0000-0000-0000000000a1', '10000000-0000-0000-0000-00000000000a',
   '20000000-0000-0000-0000-0000000000a1', 'Insight', 'Body');
insert into public.checklist_templates (id, organization_id, venue_id, title) values
  ('e4000000-0000-0000-0000-0000000000a1', '10000000-0000-0000-0000-00000000000a',
   '20000000-0000-0000-0000-0000000000a1', 'Opening');
insert into public.checklist_completions (id, organization_id, venue_id, template_id) values
  ('e5000000-0000-0000-0000-0000000000a1', '10000000-0000-0000-0000-00000000000a',
   '20000000-0000-0000-0000-0000000000a1', 'e4000000-0000-0000-0000-0000000000a1');

select throws_ok(
  $$ update public.shifts set venue_id = '20000000-0000-0000-0000-0000000000b1'
     where id = 'e1000000-0000-0000-0000-0000000000a1' $$,
  '42501', null, 'F13: a shift cannot move to another venue'
);
select throws_ok(
  $$ update public.events set venue_id = '20000000-0000-0000-0000-0000000000b1'
     where id = 'e2000000-0000-0000-0000-0000000000a1' $$,
  '42501', null, 'F13: an event cannot move to another venue'
);
select throws_ok(
  $$ update public.shift_insights set venue_id = '20000000-0000-0000-0000-0000000000b1'
     where id = 'e3000000-0000-0000-0000-0000000000a1' $$,
  '42501', null, 'F13: a shift insight cannot move to another venue'
);
select throws_ok(
  $$ update public.checklist_completions set venue_id = '20000000-0000-0000-0000-0000000000b1'
     where id = 'e5000000-0000-0000-0000-0000000000a1' $$,
  '42501', null, 'F13: a checklist completion cannot move to another venue'
);

-- ---------------------------------------------------------------------------
-- F14. floor_tables.floor_plan_id must belong to the table's venue
-- ---------------------------------------------------------------------------
insert into public.floor_plans (id, organization_id, venue_id, name) values
  ('f1000000-0000-0000-0000-0000000000a1', '10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-0000000000a1', 'A1 floor'),
  ('f1000000-0000-0000-0000-0000000000b1', '10000000-0000-0000-0000-00000000000b', '20000000-0000-0000-0000-0000000000b1', 'B1 floor');
insert into public.floor_tables (id, organization_id, venue_id, floor_plan_id, label) values
  ('f2000000-0000-0000-0000-0000000000a1', '10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-0000000000a1',
   'f1000000-0000-0000-0000-0000000000a1', 'T1');

select throws_ok(
  $$ update public.floor_tables set floor_plan_id = 'f1000000-0000-0000-0000-0000000000b1'
     where id = 'f2000000-0000-0000-0000-0000000000a1' $$,
  '23503', null,
  'F14: a table cannot move to a floor plan in another venue'
);

select lives_ok(
  $$ insert into public.floor_tables (organization_id, venue_id, floor_plan_id, label)
     values ('10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-0000000000a1',
             'f1000000-0000-0000-0000-0000000000a1', 'T2') $$,
  'F14: a table on its own venue floor plan is accepted'
);

-- ---------------------------------------------------------------------------
-- F15. anon cannot read connection secrets tables
-- ---------------------------------------------------------------------------
set local role anon;
select throws_ok(
  $$ select count(*) from public.payroll_connections $$, '42501', null,
  'F15: anon cannot select payroll_connections'
);
select throws_ok(
  $$ select count(*) from public.pos_connections $$, '42501', null,
  'F15: anon cannot select pos_connections'
);
select throws_ok(
  $$ select count(*) from public.reservation_connections $$, '42501', null,
  'F15: anon cannot select reservation_connections'
);

-- ---------------------------------------------------------------------------
-- F16. Reservation deposit payment state cannot be written by clients
-- ---------------------------------------------------------------------------
reset role;
insert into public.reservations (id, organization_id, venue_id, guest_name, party_size, reservation_time) values
  ('d1600000-0000-0000-0000-0000000000a1', '10000000-0000-0000-0000-00000000000a',
   '20000000-0000-0000-0000-0000000000a1', 'Deposit Guest', 2, now() + interval '5 days');

set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-0000000000a4';
select throws_ok(
  $$ update public.reservations set deposit_status = 'paid'
     where id = 'd1600000-0000-0000-0000-0000000000a1' $$,
  '42501', 'deposit payment state is set by the payment flow only',
  'F16: a client cannot mark a deposit paid'
);
select throws_ok(
  $$ update public.reservations set deposit_paid_at = now()
     where id = 'd1600000-0000-0000-0000-0000000000a1' $$,
  '42501', 'deposit payment state is set by the payment flow only',
  'F16: a client cannot stamp a deposit payment time'
);
select lives_ok(
  $$ update public.reservations set deposit_status = 'required'
     where id = 'd1600000-0000-0000-0000-0000000000a1' $$,
  'F16: a client can still require a deposit'
);

-- ---------------------------------------------------------------------------
-- F17. conversation_reads requires conversation membership; derive covers UPDATE
-- ---------------------------------------------------------------------------
reset role;
insert into public.conversations (id, venue_id, type, name) values
  ('b0000000-0000-0000-0000-0000000000f1', '20000000-0000-0000-0000-0000000000a1', 'group', 'Group A1'),
  ('b0000000-0000-0000-0000-0000000000b1', '20000000-0000-0000-0000-0000000000b1', 'group', 'Group B1');
insert into public.conversation_members (conversation_id, user_id) values
  ('b0000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000a8');

set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-0000000000a5';
select throws_ok(
  $$ insert into public.conversation_reads (conversation_id, user_id)
     values ('b0000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000a5') $$,
  '42501', null,
  'F17: a user cannot record a read on a conversation they are not in'
);
select lives_ok(
  $$ insert into public.conversation_reads (conversation_id, user_id)
     values ('b0000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000a5') $$,
  'F17: a member can record a read on their own conversation'
);

reset role;
update public.conversation_reads
  set conversation_id = 'b0000000-0000-0000-0000-0000000000b1'
  where conversation_id = 'b0000000-0000-0000-0000-0000000000d1'
    and user_id = '00000000-0000-0000-0000-0000000000a5';
select is(
  (select venue_id from public.conversation_reads
    where conversation_id = 'b0000000-0000-0000-0000-0000000000b1'
      and user_id = '00000000-0000-0000-0000-0000000000a5'),
  '20000000-0000-0000-0000-0000000000b1'::uuid,
  'F17: moving a read row re-derives its venue from the new conversation'
);

-- ---------------------------------------------------------------------------
-- F18. Clock-out that appends a break closes it, not reopens it
-- ---------------------------------------------------------------------------
-- correct_time_entry set app.time_entry_correction for this transaction (F4); clear it so the
-- ordinary clock-out path is what gets exercised here.
select set_config('app.time_entry_correction', 'off', true);
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-0000000000a9';
insert into public.time_entries (id, venue_id, clock_in_lat, clock_in_lng, clock_in_accuracy_m) values
  ('80000000-0000-0000-0000-0000000000e5', '20000000-0000-0000-0000-0000000000a1', 29.76041, -95.36981, 15.0);

select lives_ok(
  $$ update public.time_entries
     set is_open = false, clock_out_lat = 29.76041, clock_out_lng = -95.36981,
         clock_out_accuracy_m = 12.0, clock_out_mocked = false,
         breaks = breaks || '[{"type":"unpaid","start_at":"2001-01-01T00:00:00Z","end_at":"2001-01-01T00:30:00Z"}]'::jsonb
     where id = '80000000-0000-0000-0000-0000000000e5' $$,
  'F18: a clock-out can append a break'
);
reset role;
select is(
  (select breaks -> (jsonb_array_length(breaks) - 1) ->> 'end_at' is not null
   from public.time_entries where id = '80000000-0000-0000-0000-0000000000e5'),
  true,
  'F18: the break appended by clock-out is closed, not left open'
);

-- ---------------------------------------------------------------------------
-- F19. Anti-replay uses the venue-local day boundary (America/Los_Angeles)
-- ---------------------------------------------------------------------------
reset role;
update public.venues set timezone = 'America/Los_Angeles'
  where id = '20000000-0000-0000-0000-0000000000a1';
-- Historical punch for S1 at 1 hour before venue-local midnight (inserted with the prepare
-- trigger disabled so clock_in_at can be set).
alter table public.time_entries disable trigger prepare_time_entry_insert;
insert into public.time_entries (
  id, organization_id, venue_id, user_id, clock_in_at, clock_in_lat, clock_in_lng, clock_in_accuracy_m,
  is_open, clock_out_at
) values (
  '80000000-0000-0000-0000-0000000000e6', '10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-0000000000a1',
  '00000000-0000-0000-0000-0000000000a5',
  ((now() at time zone 'America/Los_Angeles')::date)::timestamp at time zone 'America/Los_Angeles' - interval '1 hour',
  29.76041, -95.36981, 15.0, false,
  ((now() at time zone 'America/Los_Angeles')::date)::timestamp at time zone 'America/Los_Angeles'
);
alter table public.time_entries enable trigger prepare_time_entry_insert;

set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-0000000000a5';
select throws_ok(
  $$ insert into public.time_entries (venue_id, clock_in_lat, clock_in_lng, clock_in_accuracy_m)
     values ('20000000-0000-0000-0000-0000000000a1', 29.76041, -95.36981, 5.0) $$,
  '42501', 'This location reading is identical to an earlier punch and reports satellite-grade accuracy',
  'F19: a punch identical to one from an earlier venue-local day is rejected'
);

-- F1 runs last: on the old schema its successful venue move would re-scope later fixtures.
-- ---------------------------------------------------------------------------
-- F1. venues.organization_id is immutable (multi-org owner tries a move)
-- ---------------------------------------------------------------------------
reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-0000000000a1';

select throws_ok(
  $$ update public.venues set organization_id = '10000000-0000-0000-0000-00000000000b'
     where id = '20000000-0000-0000-0000-0000000000a1' $$,
  '42501',
  'a venue cannot be moved to another organization',
  'F1: an org admin cannot move a venue to another organization'
);

select lives_ok(
  $$ update public.venues set name = 'Venue A1 renamed'
     where id = '20000000-0000-0000-0000-0000000000a1' $$,
  'F1: an org admin can still rename a venue'
);

select * from finish();
rollback;

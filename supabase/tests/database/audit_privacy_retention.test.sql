-- pgTAP tests for the audit privacy / retention / evidence / abuse-control changes
-- (20261017100000 and 20261017110000).
-- Fixture: org A venue A1 {manager M ...01, staff T ...02, owner O ...03}; org B owner X ...04.

begin;
select plan(77);

insert into auth.users (id, email) values
  ('c1000000-0000-0000-0000-000000000001', 'm@example.com'),
  ('c1000000-0000-0000-0000-000000000002', 't@example.com'),
  ('c1000000-0000-0000-0000-000000000003', 'o@example.com'),
  ('c1000000-0000-0000-0000-000000000004', 'x@example.com');

insert into public.organizations (id, name) values
  ('c2000000-0000-0000-0000-00000000000a', 'Org A'),
  ('c2000000-0000-0000-0000-00000000000b', 'Org B');

insert into public.venues (id, organization_id, name, latitude, longitude, geofence_radius_m) values
  ('c3000000-0000-0000-0000-0000000000a1', 'c2000000-0000-0000-0000-00000000000a', 'Venue A1', 29.7604, -95.3698, 100),
  ('c3000000-0000-0000-0000-0000000000b1', 'c2000000-0000-0000-0000-00000000000b', 'Venue B1', null, null, 100);

insert into public.memberships (user_id, organization_id, venue_id, role) values
  ('c1000000-0000-0000-0000-000000000001', 'c2000000-0000-0000-0000-00000000000a', 'c3000000-0000-0000-0000-0000000000a1', 'venue_manager'),
  ('c1000000-0000-0000-0000-000000000002', 'c2000000-0000-0000-0000-00000000000a', 'c3000000-0000-0000-0000-0000000000a1', 'staff'),
  ('c1000000-0000-0000-0000-000000000003', 'c2000000-0000-0000-0000-00000000000a', null, 'organization_owner'),
  ('c1000000-0000-0000-0000-000000000004', 'c2000000-0000-0000-0000-00000000000b', null, 'organization_owner');

-- ---------------------------------------------------------------------------
-- A. Time punches: no deletes, audited voids, GPS never copied into the audit log (D-01, P-04)
-- ---------------------------------------------------------------------------
set local role authenticated;
set local "request.jwt.claim.sub" to 'c1000000-0000-0000-0000-000000000002';
insert into public.time_entries (id, venue_id, clock_in_lat, clock_in_lng, clock_in_accuracy_m)
values ('c5000000-0000-0000-0000-000000000001', 'c3000000-0000-0000-0000-0000000000a1', 29.7604, -95.3698, 15.0);

select throws_ok(
  $$ select public.void_time_entry('c5000000-0000-0000-0000-000000000001', 'staff should not void') $$,
  '42501', null, 'staff cannot void a punch');

set local "request.jwt.claim.sub" to 'c1000000-0000-0000-0000-000000000001';
select throws_ok(
  $$ delete from public.time_entries where id = 'c5000000-0000-0000-0000-000000000001' $$,
  '42501', null, 'a manager can no longer hard-delete a punch');
select throws_ok(
  $$ select public.void_time_entry('c5000000-0000-0000-0000-000000000001', 'x') $$,
  '22023', null, 'voiding needs a real reason');
select lives_ok(
  $$ select public.void_time_entry('c5000000-0000-0000-0000-000000000001', 'Duplicate punch entered by mistake') $$,
  'a manager voids a subordinate''s punch with a reason');

reset role;
select is((select count(*)::int from public.time_entries where id = 'c5000000-0000-0000-0000-000000000001'), 0,
  'the voided punch is gone from the live table');
select is((select count(*)::int from public.audit_log where action = 'time_entry.void'
            and target_id = 'c5000000-0000-0000-0000-000000000001'
            and metadata ->> 'reason' = 'Duplicate punch entered by mistake'), 1,
  'the void is audited with its reason');
select ok(
  (select not (metadata -> 'before' ? 'clock_in_lat') and not (metadata -> 'before' ? 'clock_in_lng')
     and (metadata -> 'before' ? 'clock_in_at')
   from public.audit_log where action = 'time_entry.void' and target_id = 'c5000000-0000-0000-0000-000000000001'),
  'the audit record keeps the times but not the raw GPS coordinates');

set local role authenticated;
set local "request.jwt.claim.sub" to 'c1000000-0000-0000-0000-000000000001';
insert into public.time_entries (id, venue_id, clock_in_lat, clock_in_lng, clock_in_accuracy_m)
values ('c5000000-0000-0000-0000-000000000002', 'c3000000-0000-0000-0000-0000000000a1', 29.7604, -95.3698, 15.0);
select throws_ok(
  $$ select public.void_time_entry('c5000000-0000-0000-0000-000000000002', 'voiding my own punch here') $$,
  '42501', null, 'a manager cannot void their own punch');

set local "request.jwt.claim.sub" to 'c1000000-0000-0000-0000-000000000002';
insert into public.time_entries (id, venue_id, clock_in_lat, clock_in_lng, clock_in_accuracy_m)
values ('c5000000-0000-0000-0000-000000000003', 'c3000000-0000-0000-0000-0000000000a1', 29.7604, -95.3698, 15.0);
set local "request.jwt.claim.sub" to 'c1000000-0000-0000-0000-000000000001';
select lives_ok(
  $$ select public.correct_time_entry('c5000000-0000-0000-0000-000000000003', now() + interval '30 seconds', null, 'Forgot to clock out') $$,
  'a manager corrects a subordinate''s punch');
reset role;
select ok(
  (select not (metadata -> 'before' ? 'clock_in_lat') and not (metadata -> 'after' ? 'clock_in_lat')
          and not (metadata -> 'after' ? 'clock_out_lat')
   from public.audit_log where action = 'time_entry.correct' and target_id = 'c5000000-0000-0000-0000-000000000003'),
  'correction audit records carry no GPS coordinates');
select is(current_setting('app.time_entry_correction', true), 'off',
  'the correction bypass flag is reset right after the update');

-- GPS retention purge guard: only GPS columns may change, and only while the purge flag is set.
select throws_ok(
  $$ update public.time_entries set clock_in_lat = null where id = 'c5000000-0000-0000-0000-000000000003' $$,
  '42501', null, 'GPS columns are immutable without the retention flag');
select set_config('app.gps_purge', 'on', true);
select lives_ok(
  $$ update public.time_entries set clock_in_lat = null, clock_in_lng = null, clock_in_accuracy_m = null
       where id = 'c5000000-0000-0000-0000-000000000003' $$,
  'with the retention flag the GPS columns can be nulled');
select throws_ok(
  $$ update public.time_entries set clock_out_at = now() where id = 'c5000000-0000-0000-0000-000000000003' $$,
  '42501', null, 'the retention flag does not let anything but GPS change');
select set_config('app.gps_purge', 'off', true);

-- ---------------------------------------------------------------------------
-- B. Guest erasure (P-03)
-- ---------------------------------------------------------------------------
insert into public.guests (id, venue_id, organization_id, full_name, phone, email) values
  ('c6000000-0000-0000-0000-000000000001', 'c3000000-0000-0000-0000-0000000000a1', 'c2000000-0000-0000-0000-00000000000a', 'Gina Guest', '555-1111', 'gina@example.com'),
  ('c6000000-0000-0000-0000-000000000002', 'c3000000-0000-0000-0000-0000000000a1', 'c2000000-0000-0000-0000-00000000000a', 'Other Guest', '555-2222', 'other@example.com');

insert into public.reservations (id, venue_id, organization_id, guest_id, guest_name, guest_phone, guest_email, party_size, reservation_time) values
  ('c7000000-0000-0000-0000-000000000001', 'c3000000-0000-0000-0000-0000000000a1', 'c2000000-0000-0000-0000-00000000000a', 'c6000000-0000-0000-0000-000000000001', 'Gina Guest', '555-1111', 'gina@example.com', 2, now() + interval '1 day'),
  ('c7000000-0000-0000-0000-000000000002', 'c3000000-0000-0000-0000-0000000000a1', 'c2000000-0000-0000-0000-00000000000a', null, 'G. Guest', null, 'GINA@example.com', 4, now() + interval '2 days'),
  ('c7000000-0000-0000-0000-000000000003', 'c3000000-0000-0000-0000-0000000000a1', 'c2000000-0000-0000-0000-00000000000a', 'c6000000-0000-0000-0000-000000000002', 'Other Guest', '555-2222', 'other@example.com', 2, now() + interval '3 days');

insert into public.crm_leads (id, venue_id, full_name, email, phone, company) values
  ('c8000000-0000-0000-0000-000000000001', 'c3000000-0000-0000-0000-0000000000a1', 'Gina G', 'gina@example.com', null, 'GG Events'),
  ('c8000000-0000-0000-0000-000000000002', 'c3000000-0000-0000-0000-0000000000a1', 'Unrelated Lead', 'lead@example.com', null, null);
insert into public.crm_notes (lead_id, text) values ('c8000000-0000-0000-0000-000000000001', 'Gina prefers the patio');

insert into public.pos_checks (id, venue_id, organization_id, provider, external_check_id, opened_at, subtotal_cents, total_cents, guest_name, raw_payload) values
  ('c9000000-0000-0000-0000-000000000001', 'c3000000-0000-0000-0000-0000000000a1', 'c2000000-0000-0000-0000-00000000000a', 'toast', 'chk-1', now() - interval '1 hour', 1000, 1100, 'Gina Guest', '{"guest":"Gina Guest"}'),
  ('c9000000-0000-0000-0000-000000000002', 'c3000000-0000-0000-0000-0000000000a1', 'c2000000-0000-0000-0000-00000000000a', 'toast', 'chk-2', now() - interval '1 hour', 1000, 1100, 'Other Guest', '{"guest":"Other Guest"}');

set local role authenticated;
set local "request.jwt.claim.sub" to 'c1000000-0000-0000-0000-000000000002';
select throws_ok($$ select public.erase_guest('c6000000-0000-0000-0000-000000000001') $$, '42501', null,
  'staff cannot erase a guest');
set local "request.jwt.claim.sub" to 'c1000000-0000-0000-0000-000000000004';
select throws_ok($$ select public.erase_guest('c6000000-0000-0000-0000-000000000001') $$, '42501', null,
  'another organization''s owner cannot erase this guest');
set local "request.jwt.claim.sub" to 'c1000000-0000-0000-0000-000000000001';
select lives_ok($$ select public.erase_guest('c6000000-0000-0000-0000-000000000001') $$,
  'a manager erases a guest');
reset role;

select is((select count(*)::int from public.guests where id = 'c6000000-0000-0000-0000-000000000001'), 0, 'the guest row is deleted');
select is((select count(*)::int from public.guests where id = 'c6000000-0000-0000-0000-000000000002'), 1, 'other guests are untouched');
select results_eq(
  $$ select guest_name, guest_phone, guest_email from public.reservations where id in
     ('c7000000-0000-0000-0000-000000000001', 'c7000000-0000-0000-0000-000000000002') order by id $$,
  $$ values ('Erased guest'::text, null::text, null::text), ('Erased guest'::text, null::text, null::text) $$,
  'reservations linked by id or by (case-insensitive) email lose the person''s details');
select is((select guest_phone from public.reservations where id = 'c7000000-0000-0000-0000-000000000003'), '555-2222',
  'an unrelated reservation keeps its details');
select results_eq(
  $$ select full_name, email, company, deleted_at is not null from public.crm_leads where id = 'c8000000-0000-0000-0000-000000000001' $$,
  $$ values ('Erased lead'::text, null::text, null::text, true) $$,
  'the matching CRM lead is anonymized and soft-deleted');
select is((select email from public.crm_leads where id = 'c8000000-0000-0000-0000-000000000002'), 'lead@example.com',
  'an unrelated lead is untouched');
select is((select count(*)::int from public.crm_notes where lead_id = 'c8000000-0000-0000-0000-000000000001'), 0,
  'free-text notes on the erased lead are deleted');
select results_eq(
  $$ select guest_name, raw_payload is null from public.pos_checks where id = 'c9000000-0000-0000-0000-000000000001' $$,
  $$ values (null::text, true) $$,
  'POS checks naming the guest lose the name and raw payload (even though the check is closed)');
select is((select raw_payload is not null from public.pos_checks where id = 'c9000000-0000-0000-0000-000000000002'), true,
  'other POS checks keep their payload');
select ok((select count(*) = 1 from public.audit_log where action = 'guest.erase'
            and target_id = 'c6000000-0000-0000-0000-000000000001'
            and not (metadata::text like '%Gina%')),
  'the erasure is audited without the guest''s personal data');

-- ---------------------------------------------------------------------------
-- C. Retention
-- ---------------------------------------------------------------------------
-- created_at is stamped by the insert path, so backdate the row while it is still open, then close it.
insert into public.pos_checks (id, venue_id, organization_id, provider, external_check_id, opened_at, subtotal_cents, total_cents, raw_payload, status) values
  ('c9000000-0000-0000-0000-000000000003', 'c3000000-0000-0000-0000-0000000000a1', 'c2000000-0000-0000-0000-00000000000a', 'toast', 'chk-old', now() - interval '100 days', 1000, 1100, '{"old":true}', 'open');
update public.pos_checks set created_at = now() - interval '100 days' where id = 'c9000000-0000-0000-0000-000000000003';
update public.pos_checks set status = 'closed', closed_at = now() - interval '99 days' where id = 'c9000000-0000-0000-0000-000000000003';

insert into public.reservations (id, venue_id, organization_id, guest_name, guest_phone, guest_email, party_size, reservation_time, status) values
  ('c7000000-0000-0000-0000-000000000010', 'c3000000-0000-0000-0000-0000000000a1', 'c2000000-0000-0000-0000-00000000000a', 'Old Diner', '555-9999', 'old@example.com', 2, now() - interval '25 months', 'completed'),
  ('c7000000-0000-0000-0000-000000000011', 'c3000000-0000-0000-0000-0000000000a1', 'c2000000-0000-0000-0000-00000000000a', 'Recent Diner', '555-8888', 'recent@example.com', 2, now() - interval '2 months', 'completed');

insert into public.invites (id, venue_id, email, role, invited_by, status, created_at, expires_at) values
  ('ca000000-0000-0000-0000-000000000001', 'c3000000-0000-0000-0000-0000000000a1', 'old-revoked@example.com', 'staff', 'c1000000-0000-0000-0000-000000000001', 'revoked', now() - interval '100 days', now() + interval '1 day'),
  ('ca000000-0000-0000-0000-000000000002', 'c3000000-0000-0000-0000-0000000000a1', 'recent-revoked@example.com', 'staff', 'c1000000-0000-0000-0000-000000000001', 'revoked', now() - interval '10 days', now() + interval '1 day');

select lives_ok($$ select * from app_hidden.run_retention_cleanup() $$, 'the retention job runs over the new data');

select is((select raw_payload is null from public.pos_checks where id = 'c9000000-0000-0000-0000-000000000003'), true,
  'raw POS payloads older than 90 days are purged (closed checks included)');
select is((select raw_payload is not null from public.pos_checks where id = 'c9000000-0000-0000-0000-000000000002'), true,
  'recent raw POS payloads are kept');
select is((select total_cents from public.pos_checks where id = 'c9000000-0000-0000-0000-000000000003'), 1100,
  'the purge changed nothing but the payload');
select results_eq(
  $$ select guest_name, guest_phone, guest_email from public.reservations where id = 'c7000000-0000-0000-0000-000000000010' $$,
  $$ values ('Guest'::text, null::text, null::text) $$,
  'finished reservations older than 24 months are anonymized');
select is((select guest_phone from public.reservations where id = 'c7000000-0000-0000-0000-000000000011'), '555-8888',
  'recent reservations keep their details');
select is((select count(*)::int from public.invites where id = 'ca000000-0000-0000-0000-000000000001'), 0,
  'resolved invites older than 90 days are deleted');
select is((select count(*)::int from public.invites where id = 'ca000000-0000-0000-0000-000000000002'), 1,
  'recent resolved invites are kept');

-- ---------------------------------------------------------------------------
-- D. Account deletion keeps only wage-law fields, in a restricted table (P-04)
-- ---------------------------------------------------------------------------
insert into public.employee_hr_profiles (venue_id, user_id, legal_name, employee_number, job_title, hourly_rate_cents, phone, address) values
  ('c3000000-0000-0000-0000-0000000000a1', 'c1000000-0000-0000-0000-000000000002', 'Terry Tester', 'E-17', 'Server', 1800, '555-0100', '1 Main St');

set local role authenticated;
set local "request.jwt.claim.sub" to 'c1000000-0000-0000-0000-000000000002';
select lives_ok($$ select public.request_account_deletion('privacy test') $$, 'staff deletes their account');
reset role;

select results_eq(
  $$ select legal_name, employee_number, hourly_rate_cents from public.retained_wage_profiles $$,
  $$ values ('Terry Tester'::text, 'E-17'::text, 1800) $$,
  'the legal-hold table keeps name, employee number and rate');
select is((select count(*)::int from public.employee_hr_profiles where user_id = 'c1000000-0000-0000-0000-000000000002'), 0,
  'the full HR profile (address, phone, ...) is deleted');
select is((select count(*)::int from public.audit_log
            where action in ('time_entry.void', 'time_entry.correct')
              and (metadata -> 'before' ->> 'user_id' = 'c1000000-0000-0000-0000-000000000002'
                   or metadata -> 'after' ->> 'user_id' = 'c1000000-0000-0000-0000-000000000002')), 0,
  'punch void/correction audit records no longer name the deleted user');
select ok((select count(*) >= 1 from public.audit_log where action = 'time_entry.void'),
  'the void record itself is kept for the wage-record period');

-- ---------------------------------------------------------------------------
-- E. Evidence and storage-deletion jobs survive org deletion (D-04)
-- ---------------------------------------------------------------------------
insert into public.organizations (id, name) values ('c2000000-0000-0000-0000-00000000000c', 'Org C');
insert into public.venues (id, organization_id, name) values
  ('c3000000-0000-0000-0000-0000000000c1', 'c2000000-0000-0000-0000-00000000000c', 'Venue C1');
insert into public.incidents (id, venue_id, title, severity, reported_by) values
  ('cb000000-0000-0000-0000-000000000001', 'c3000000-0000-0000-0000-0000000000c1', 'Slip', 'low', 'c1000000-0000-0000-0000-000000000003');
insert into public.incident_attachments (id, incident_id, storage_path, uploaded_by) values
  ('cc000000-0000-0000-0000-000000000001', 'cb000000-0000-0000-0000-000000000001',
   'c2000000-0000-0000-0000-00000000000c/c3000000-0000-0000-0000-0000000000c1/photo-1.jpg',
   'c1000000-0000-0000-0000-000000000003');

delete from public.incident_attachments where id = 'cc000000-0000-0000-0000-000000000001';
select is((select count(*)::int from public.storage_deletion_jobs
            where bucket_id = 'incident-evidence' and object_path like '%photo-1.jpg'), 1,
  'deleting an incident attachment queues its Storage object for deletion');

insert into public.incident_attachments (id, incident_id, storage_path, uploaded_by) values
  ('cc000000-0000-0000-0000-000000000002', 'cb000000-0000-0000-0000-000000000001',
   'c2000000-0000-0000-0000-00000000000c/c3000000-0000-0000-0000-0000000000c1/photo-2.jpg',
   'c1000000-0000-0000-0000-000000000003');
select lives_ok($$ delete from public.organizations where id = 'c2000000-0000-0000-0000-00000000000c' $$,
  'deleting an organization with evidence attached succeeds');
select is((select count(*)::int from public.storage_deletion_jobs
            where bucket_id = 'incident-evidence' and object_path like '%photo-2.jpg'), 1,
  'the pending Storage deletion survives the organization it belonged to');
select ok((select count(*) >= 1 from public.audit_log where action = 'incident.delete'),
  'incident deletion is audited');

-- ---------------------------------------------------------------------------
-- F. Column privileges, input bounds, token cap
-- ---------------------------------------------------------------------------
set local role authenticated;
set local "request.jwt.claim.sub" to 'c1000000-0000-0000-0000-000000000001';
select throws_ok($$ select raw_payload from public.pos_checks $$, '42501', null,
  'clients cannot select the raw POS payload column');
select throws_ok($$ select * from public.pos_checks $$, '42501', null,
  'select * on pos_checks is refused (clients must list columns)');
select lives_ok($$ select id, status, total_cents, guest_name from public.pos_checks $$,
  'the parsed POS columns remain readable by staff');
reset role;

select throws_ok(
  $$ insert into public.crm_notes (lead_id, text) values ('c8000000-0000-0000-0000-000000000002', repeat('x', 5001)) $$,
  '23514', null, 'free-text columns are length-capped');

insert into public.push_tokens (organization_id, venue_id, user_id, token, platform, enabled)
select 'c2000000-0000-0000-0000-00000000000a', 'c3000000-0000-0000-0000-0000000000a1',
       'c1000000-0000-0000-0000-000000000001', 'cap-token-' || g, 'ios', true
from generate_series(1, 25) g;
select throws_ok(
  $$ insert into public.push_tokens (organization_id, venue_id, user_id, token, platform, enabled)
     values ('c2000000-0000-0000-0000-00000000000a', 'c3000000-0000-0000-0000-0000000000a1',
             'c1000000-0000-0000-0000-000000000001', 'cap-token-26', 'ios', true) $$,
  'P0001', null, 'a user cannot register more than 25 push tokens');

-- ---------------------------------------------------------------------------
-- G. Abuse controls: rate limiter, entitlement, workspace cap, AI opt-in, AI rate limit
-- ---------------------------------------------------------------------------
set local role service_role;
select is((select public.consume_rate_limit('test:key', 2, 3600)), true, 'rate limiter: first hit allowed');
select is((select public.consume_rate_limit('test:key', 2, 3600)), true, 'rate limiter: second hit allowed');
select is((select public.consume_rate_limit('test:key', 2, 3600)), false, 'rate limiter: third hit refused');
select is((select public.consume_rate_limit('test:other', 2, 3600)), true, 'rate limiter: keys are independent');
select throws_ok($$ select public.consume_rate_limit('', 2, 3600) $$, '22023', null, 'rate limiter rejects bad arguments');
reset role;

set local role authenticated;
set local "request.jwt.claim.sub" to 'c1000000-0000-0000-0000-000000000003';
select throws_ok($$ select public.consume_rate_limit('x', 1, 60) $$, '42501', null,
  'clients cannot call the rate limiter');
select throws_ok($$ select public.org_is_entitled('c2000000-0000-0000-0000-00000000000a') $$, '42501', null,
  'clients cannot call the entitlement check');
reset role;

select is((select public.org_is_entitled('c2000000-0000-0000-0000-00000000000a')), true,
  'entitlement: with enforcement off (default) every org is entitled');
update app_hidden.platform_settings set billing_enforcement = true;
update public.organizations set created_at = now() - interval '60 days' where id = 'c2000000-0000-0000-0000-00000000000a';
select is((select public.org_is_entitled('c2000000-0000-0000-0000-00000000000a')), false,
  'entitlement: enforcement on, old org, no subscription -> not entitled');
update public.organizations set created_at = now() - interval '3 days' where id = 'c2000000-0000-0000-0000-00000000000a';
select is((select public.org_is_entitled('c2000000-0000-0000-0000-00000000000a')), true,
  'entitlement: a new org is inside the grace trial');
update public.organizations set created_at = now() - interval '60 days' where id = 'c2000000-0000-0000-0000-00000000000a';
insert into public.subscriptions (organization_id, status) values ('c2000000-0000-0000-0000-00000000000a', 'active');
select is((select public.org_is_entitled('c2000000-0000-0000-0000-00000000000a')), true,
  'entitlement: an active subscription is entitled');
update public.subscriptions set status = 'canceled' where organization_id = 'c2000000-0000-0000-0000-00000000000a';
select is((select public.org_is_entitled('c2000000-0000-0000-0000-00000000000a')), false,
  'entitlement: a canceled subscription is not entitled');
update app_hidden.platform_settings set billing_enforcement = false;

set local role authenticated;
set local "request.jwt.claim.sub" to 'c1000000-0000-0000-0000-000000000004';
select lives_ok($$ select * from public.create_workspace('Sock 1', 'V1') $$, 'workspace 1 of the day');
select lives_ok($$ select * from public.create_workspace('Sock 2', 'V2') $$, 'workspace 2 of the day');
select lives_ok($$ select * from public.create_workspace('Sock 3', 'V3') $$, 'workspace 3 of the day');
select throws_ok($$ select * from public.create_workspace('Sock 4', 'V4') $$, 'P0001', null,
  'the fourth workspace within 24h is refused');
reset role;
select is((select ai_enabled from public.organizations where name = 'Sock 1'), false,
  'new workspaces start with AI disabled until an owner opts in');
select col_has_default('public', 'organizations', 'ai_enabled', 'ai_enabled has a default (false for new orgs; the migration backfilled existing orgs to true)');

set local role authenticated;
set local "request.jwt.claim.sub" to 'c1000000-0000-0000-0000-000000000001';
select throws_ok($$ select public.set_org_ai_enabled('c2000000-0000-0000-0000-00000000000a', false) $$, '42501', null,
  'a venue manager cannot toggle the organization''s AI opt-in');
set local "request.jwt.claim.sub" to 'c1000000-0000-0000-0000-000000000003';
select lives_ok($$ select public.set_org_ai_enabled('c2000000-0000-0000-0000-00000000000a', false) $$,
  'the owner can toggle the AI opt-in');
select throws_ok($$ update public.organizations set ai_enabled = true where id = 'c2000000-0000-0000-0000-00000000000a' $$,
  '42501', null, 'clients cannot flip ai_enabled with a direct update');
reset role;
select is((select ai_enabled from public.organizations where id = 'c2000000-0000-0000-0000-00000000000a'), false,
  'the opt-in change persisted');

-- AI rate limit counts released reservations too (B-03).
set local role service_role;
select lives_ok($$ select public.reserve_ai_budget('c2000000-0000-0000-0000-00000000000a', 'c1000000-0000-0000-0000-000000000003', 0.01, 10, 2, 10, 120) $$,
  'AI reservation 1');
select lives_ok($$ select public.reserve_ai_budget('c2000000-0000-0000-0000-00000000000a', 'c1000000-0000-0000-0000-000000000003', 0.01, 10, 2, 10, 120) $$,
  'AI reservation 2');
reset role;
update public.ai_budget_reservations set status = 'released' where user_id = 'c1000000-0000-0000-0000-000000000003';
set local role service_role;
select throws_ok($$ select public.reserve_ai_budget('c2000000-0000-0000-0000-00000000000a', 'c1000000-0000-0000-0000-000000000003', 0.01, 10, 2, 10, 120) $$,
  'P0001', null, 'released reservations still count toward the per-user rate limit');
reset role;

-- ---------------------------------------------------------------------------
-- H. Ops health report is service-only and surfaces stuck deletion jobs (R-04)
-- ---------------------------------------------------------------------------
set local role authenticated;
set local "request.jwt.claim.sub" to 'c1000000-0000-0000-0000-000000000003';
select throws_ok($$ select * from public.ops_health_report() $$, '42501', null,
  'clients cannot read the ops health report');
reset role;
insert into public.account_deletion_jobs (user_id, status, created_at)
values ('c1000000-0000-0000-0000-000000000004', 'pending', now() - interval '3 days');
set local role service_role;
select lives_ok($$ select * from public.ops_health_report() $$, 'the report runs for the service role');
select ok(
  exists (select 1 from public.ops_health_report() where check_name = 'account_deletion_jobs_stuck' and severity = 'critical'),
  'a deletion job stuck for days is reported as critical');
reset role;

select * from finish();
rollback;

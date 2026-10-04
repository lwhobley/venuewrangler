-- pgTAP authorization and functionality tests for crm module (20261003002000).
-- Fixtures: Org A, Venue A1 (manager 004, staff 005), Org B, Venue B1 (owner 006).

begin;
select plan(28);

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-000000000004', 'venue-a1-manager@example.com'),
  ('00000000-0000-0000-0000-000000000005', 'venue-a1-staff@example.com'),
  ('00000000-0000-0000-0000-000000000006', 'org-b-owner@example.com');

insert into public.organizations (id, name) values
  ('10000000-0000-0000-0000-00000000000a', 'Org A'),
  ('10000000-0000-0000-0000-00000000000b', 'Org B');

insert into public.venues (id, organization_id, name) values
  ('20000000-0000-0000-0000-0000000000a1', '10000000-0000-0000-0000-00000000000a', 'Venue A1'),
  ('20000000-0000-0000-0000-00000000000b', '10000000-0000-0000-0000-00000000000b', 'Venue B1');

insert into public.memberships (user_id, organization_id, venue_id, role) values
  ('00000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-0000000000a1', 'venue_manager'),
  ('00000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-0000000000a1', 'staff'),
  ('00000000-0000-0000-0000-000000000006', '10000000-0000-0000-0000-00000000000b', null, 'organization_owner');

-- ---------------------------------------------------------------------------
-- 1 & 2. Staff cannot read or write leads at all (legacy: canManageVenue gates everything)
-- ---------------------------------------------------------------------------
reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000005'; -- staff

select throws_ok(
  $$ insert into public.crm_leads (venue_id, full_name)
     values ('20000000-0000-0000-0000-0000000000a1', 'Jane Prospect') $$,
  '42501',
  null,
  'staff cannot create a lead'
);

-- ---------------------------------------------------------------------------
-- 3. Manager can create a lead; organization_id is derived
-- ---------------------------------------------------------------------------
reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000004'; -- manager

insert into public.crm_leads (id, venue_id, full_name, email, status, estimated_value_cents)
values ('60000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-0000000000a1', 'Jane Prospect', 'jane@example.com', 'new', 500000);

select is(
  (select organization_id from public.crm_leads where id = '60000000-0000-0000-0000-000000000001'),
  '10000000-0000-0000-0000-00000000000a'::uuid,
  'organization_id is auto-derived from venue_id'
);

-- ---------------------------------------------------------------------------
-- 4. Staff cannot read leads
-- ---------------------------------------------------------------------------
reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000005';

select is(
  (select count(*)::int from public.crm_leads),
  0,
  'staff cannot see any leads (RLS select policy excludes non-managers entirely)'
);

-- ---------------------------------------------------------------------------
-- 5. Org B owner cannot see Org A's lead (cross-tenant isolation)
-- ---------------------------------------------------------------------------
reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000006';

select is(
  (select count(*)::int from public.crm_leads),
  0,
  'org_b_owner cannot see org_a leads'
);

-- ---------------------------------------------------------------------------
-- 6 & 7. Status change is logged to activity automatically (trigger-based)
-- ---------------------------------------------------------------------------
reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000004';

update public.crm_leads set status = 'contacted' where id = '60000000-0000-0000-0000-000000000001';

select is(
  (select count(*)::int from public.crm_activity_log where lead_id = '60000000-0000-0000-0000-000000000001' and kind = 'status_changed'),
  1,
  'status change is automatically logged to crm_activity_log'
);

select is(
  (select detail from public.crm_activity_log where lead_id = '60000000-0000-0000-0000-000000000001' and kind = 'status_changed'),
  'new -> contacted',
  'status change detail records old -> new transition'
);

-- ---------------------------------------------------------------------------
-- 8 & 9. Adding a note bumps last_activity_at and logs activity
-- ---------------------------------------------------------------------------
insert into public.crm_notes (lead_id, text)
values ('60000000-0000-0000-0000-000000000001', 'Called, left voicemail');

select isnt(
  (select last_activity_at from public.crm_leads where id = '60000000-0000-0000-0000-000000000001'),
  null,
  'adding a note bumps last_activity_at'
);

select is(
  (select count(*)::int from public.crm_activity_log where lead_id = '60000000-0000-0000-0000-000000000001' and kind = 'note_added'),
  1,
  'adding a note logs note_added activity'
);

-- ---------------------------------------------------------------------------
-- 10. Notes are immutable (no update policy means a matching-row UPDATE is a silent no-op,
-- not an exception, per Postgres RLS semantics — assert the text is unchanged, don't expect a
-- thrown error).
-- ---------------------------------------------------------------------------
select lives_ok(
  $$ update public.crm_notes set text = 'edited' where lead_id = '60000000-0000-0000-0000-000000000001' $$,
  'updating a note is a silent no-op (no update policy exists), not an error'
);

select is(
  (select text from public.crm_notes where lead_id = '60000000-0000-0000-0000-000000000001'),
  'Called, left voicemail',
  'the note text is actually unchanged after the no-op update'
);

-- ---------------------------------------------------------------------------
-- 11-13. Confirming a BEO with an event_date syncs a real reservation via beo_id FK
-- ---------------------------------------------------------------------------
insert into public.crm_beos (id, venue_id, lead_id, event_name, status)
values ('70000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-0000000000a1', '60000000-0000-0000-0000-000000000001', 'Jane''s Wedding', 'draft');

update public.crm_beos
set status = 'confirmed', event_date = now() + interval '30 days', guest_count = 80
where id = '70000000-0000-0000-0000-000000000001';

select is(
  (select count(*)::int from public.reservations where beo_id = '70000000-0000-0000-0000-000000000001'),
  1,
  'confirming a BEO with an event_date creates exactly one linked reservation'
);

select is(
  (select party_size from public.reservations where beo_id = '70000000-0000-0000-0000-000000000001'),
  80,
  'synced reservation carries the BEO guest_count as party_size'
);

select is(
  (select count(*)::int from public.crm_activity_log where lead_id = '60000000-0000-0000-0000-000000000001' and kind = 'beo_status_changed'),
  1,
  'BEO status change is logged'
);

-- ---------------------------------------------------------------------------
-- 14. A second confirm (no relevant field change) does not create a duplicate reservation
-- ---------------------------------------------------------------------------
update public.crm_beos set internal_notes = 'no-op touch' where id = '70000000-0000-0000-0000-000000000001';

select is(
  (select count(*)::int from public.reservations where beo_id = '70000000-0000-0000-0000-000000000001'),
  1,
  'an unrelated update to an already-confirmed BEO does not create a duplicate reservation'
);

-- ---------------------------------------------------------------------------
-- 15. Confirming a second BEO into an overlapping time window is rejected (hold conflict)
-- ---------------------------------------------------------------------------
insert into public.crm_beos (id, venue_id, event_name, status)
values ('70000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-0000000000a1', 'Overlapping Gala', 'draft');

select throws_ok(
  $$ update public.crm_beos
     set status = 'confirmed', event_date = (select event_date from public.crm_beos where id = '70000000-0000-0000-0000-000000000001')
     where id = '70000000-0000-0000-0000-000000000002' $$,
  '23505',
  null,
  'confirming a BEO into an already-held time window is rejected'
);

-- ---------------------------------------------------------------------------
-- 16. Cancelling a confirmed BEO cancels its reservation
-- ---------------------------------------------------------------------------
update public.crm_beos set status = 'cancelled' where id = '70000000-0000-0000-0000-000000000001';

select is(
  (select status from public.reservations where beo_id = '70000000-0000-0000-0000-000000000001'),
  'cancelled',
  'cancelling a BEO cancels its linked reservation'
);

-- ---------------------------------------------------------------------------
-- 17-19. Fully-signed contract freeze
-- ---------------------------------------------------------------------------
insert into public.crm_contracts (id, venue_id, lead_id, event_name, status)
values ('80000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-0000000000a1', '60000000-0000-0000-0000-000000000001', 'Original Name', 'draft');

select isnt(
  (select contract_number from public.crm_contracts where id = '80000000-0000-0000-0000-000000000001'),
  null,
  'contract_number is auto-generated when not supplied'
);

update public.crm_contracts set status = 'fully_signed' where id = '80000000-0000-0000-0000-000000000001';

select throws_ok(
  $$ update public.crm_contracts set event_name = 'Changed Name' where id = '80000000-0000-0000-0000-000000000001' $$,
  '42501',
  null,
  'a fully signed contract''s content fields cannot be modified'
);

select lives_ok(
  $$ update public.crm_contracts set status = 'cancelled' where id = '80000000-0000-0000-0000-000000000001' $$,
  'a fully signed contract can still be moved to cancelled'
);

-- ---------------------------------------------------------------------------
-- 20 & 21. Idempotent BEO -> contract conversion
-- ---------------------------------------------------------------------------
reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000004';

insert into public.crm_beos (id, venue_id, event_name, status, deposit_cents)
values ('70000000-0000-0000-0000-000000000003', '20000000-0000-0000-0000-0000000000a1', 'Convertible Event', 'confirmed', 0);

select results_eq(
  $$ select already_existed from public.convert_beo_to_contract('70000000-0000-0000-0000-000000000003') $$,
  $$ values (false) $$,
  'first conversion creates a new contract'
);

select results_eq(
  $$ select already_existed from public.convert_beo_to_contract('70000000-0000-0000-0000-000000000003') $$,
  $$ values (true) $$,
  'a second conversion of the same BEO is idempotent, not a duplicate'
);

-- ---------------------------------------------------------------------------
-- 22. Conversion is blocked while a deposit is due and unpaid
-- ---------------------------------------------------------------------------
insert into public.crm_beos (id, venue_id, event_name, status, deposit_cents)
values ('70000000-0000-0000-0000-000000000004', '20000000-0000-0000-0000-0000000000a1', 'Unpaid Deposit Event', 'confirmed', 50000);

select is(
  (select deposit_status from public.crm_beos where id = '70000000-0000-0000-0000-000000000004'),
  'due',
  'new BEO deposits default to due'
);

select throws_ok(
  $$ update public.crm_beos set deposit_status = 'paid' where id = '70000000-0000-0000-0000-000000000004' $$,
  '42501', null, 'manager cannot mark a BEO deposit paid'
);

select throws_ok(
  $$ insert into public.crm_beos (venue_id, event_name, deposit_cents, deposit_status)
     values ('20000000-0000-0000-0000-0000000000a1', 'Forged Paid Event', 50000, 'paid') $$,
  '42501', null, 'manager cannot create a pre-paid BEO'
);

select throws_ok(
  $$ select * from public.convert_beo_to_contract('70000000-0000-0000-0000-000000000004') $$,
  '42501',
  null,
  'conversion is blocked while the BEO deposit is due and unpaid'
);

-- ---------------------------------------------------------------------------
-- 23. Waiving a deposit is conditional on it not already being paid
-- ---------------------------------------------------------------------------
select is(
  (select waive_beo_deposit from public.waive_beo_deposit('70000000-0000-0000-0000-000000000004')),
  true,
  'waiving a due deposit succeeds'
);

reset role;
insert into public.crm_beos (id, venue_id, event_name, status, deposit_cents, deposit_status)
values ('70000000-0000-0000-0000-000000000005', '20000000-0000-0000-0000-0000000000a1', 'Paid Deposit Event', 'confirmed', 50000, 'paid');
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000004';

select is(
  (select waive_beo_deposit from public.waive_beo_deposit('70000000-0000-0000-0000-000000000005')),
  false,
  'waiving an already-paid deposit is a no-op, not an error'
);

-- ---------------------------------------------------------------------------
-- 25. Pipeline forecast RPC returns weighted values per the legacy probability table
-- ---------------------------------------------------------------------------
select is(
  (select weighted_value_cents from public.crm_pipeline_forecast('20000000-0000-0000-0000-0000000000a1') where status = 'contacted'),
  75000::bigint,
  'forecast weights the contacted-stage lead at 15% of its estimated value (500000 * 0.15)'
);

select * from finish();
rollback;

-- pgTAP tests for contract signing evidence (20261017140000_contract_signature_evidence.sql).

begin;
select plan(29);

insert into auth.users (id, email) values
  ('e1000000-0000-0000-0000-000000000001', 'manager@example.com'),
  ('e1000000-0000-0000-0000-000000000002', 'staff@example.com'),
  ('e1000000-0000-0000-0000-000000000003', 'outsider@example.com');
insert into public.organizations (id, name) values
  ('e2000000-0000-0000-0000-00000000000a', 'Org A'),
  ('e2000000-0000-0000-0000-00000000000b', 'Org B');
insert into public.venues (id, organization_id, name) values
  ('e3000000-0000-0000-0000-0000000000a1', 'e2000000-0000-0000-0000-00000000000a', 'Venue A1'),
  ('e3000000-0000-0000-0000-0000000000b1', 'e2000000-0000-0000-0000-00000000000b', 'Venue B1');
insert into public.memberships (user_id, organization_id, venue_id, role) values
  ('e1000000-0000-0000-0000-000000000001', 'e2000000-0000-0000-0000-00000000000a', 'e3000000-0000-0000-0000-0000000000a1', 'venue_manager'),
  ('e1000000-0000-0000-0000-000000000002', 'e2000000-0000-0000-0000-00000000000a', 'e3000000-0000-0000-0000-0000000000a1', 'staff'),
  ('e1000000-0000-0000-0000-000000000003', 'e2000000-0000-0000-0000-00000000000b', null, 'organization_owner');

insert into public.crm_contracts (id, venue_id, contract_number, event_name, guest_count, status) values
  ('e4000000-0000-0000-0000-000000000001', 'e3000000-0000-0000-0000-0000000000a1', 'C-1', 'Gala', 120, 'sent'),
  ('e4000000-0000-0000-0000-000000000002', 'e3000000-0000-0000-0000-0000000000a1', 'C-2', 'Wedding', 80, 'cancelled'),
  ('e4000000-0000-0000-0000-000000000003', 'e3000000-0000-0000-0000-0000000000a1', 'C-3', 'Reunion', 40, 'draft');

-- ---------------------------------------------------------------------------
-- Direct writes to signature state are refused
-- ---------------------------------------------------------------------------
set local role authenticated;
set local "request.jwt.claim.sub" to 'e1000000-0000-0000-0000-000000000001';

select throws_ok(
  $$ update public.crm_contracts set status = 'fully_signed' where id = 'e4000000-0000-0000-0000-000000000001' $$,
  '42501', null, 'a manager cannot mark a contract fully signed with a plain update');
select throws_ok(
  $$ update public.crm_contracts set status = 'partially_signed' where id = 'e4000000-0000-0000-0000-000000000001' $$,
  '42501', null, 'nor partially signed');
select throws_ok(
  $$ update public.crm_contracts set client_signature_name = 'Forged Client' where id = 'e4000000-0000-0000-0000-000000000001' $$,
  '42501', null, 'nor write the signature name');
select throws_ok(
  $$ update public.crm_contracts set client_signature_date = now() where id = 'e4000000-0000-0000-0000-000000000001' $$,
  '42501', null, 'nor the signature date');
select throws_ok(
  $$ insert into public.crm_contracts (venue_id, contract_number, status) values ('e3000000-0000-0000-0000-0000000000a1', 'C-9', 'fully_signed') $$,
  '42501', null, 'nor create a contract that is already signed');
select lives_ok(
  $$ update public.crm_contracts set status = 'viewed' where id = 'e4000000-0000-0000-0000-000000000001' $$,
  'ordinary status changes still work');

-- ---------------------------------------------------------------------------
-- record_contract_signature
-- ---------------------------------------------------------------------------
set local "request.jwt.claim.sub" to 'e1000000-0000-0000-0000-000000000002';
select throws_ok(
  $$ select public.record_contract_signature('e4000000-0000-0000-0000-000000000001', 'Pat Client') $$,
  '42501', null, 'staff cannot record a signature');
set local "request.jwt.claim.sub" to 'e1000000-0000-0000-0000-000000000003';
select throws_ok(
  $$ select public.record_contract_signature('e4000000-0000-0000-0000-000000000001', 'Pat Client') $$,
  '42501', null, 'another organization''s owner cannot record a signature');

set local "request.jwt.claim.sub" to 'e1000000-0000-0000-0000-000000000001';
select throws_ok(
  $$ select public.record_contract_signature('e4000000-0000-0000-0000-000000000001', 'x') $$,
  '22023', null, 'the signer name must be a real name');
select throws_ok(
  $$ select public.record_contract_signature('e4000000-0000-0000-0000-000000000002', 'Pat Client') $$,
  'P0001', null, 'a cancelled contract cannot be signed');
select throws_ok(
  $$ select public.record_contract_signature('e9000000-0000-0000-0000-000000000000', 'Pat Client') $$,
  'P0002', null, 'a missing contract reports not found');

select lives_ok(
  $$ select public.record_contract_signature('e4000000-0000-0000-0000-000000000003', 'Pat Client', false, 'first signer') $$,
  'a manager records a partial signature');
select is((select status from public.crm_contracts where id = 'e4000000-0000-0000-0000-000000000003'), 'partially_signed',
  'the contract is partially signed');
select lives_ok(
  $$ select public.record_contract_signature('e4000000-0000-0000-0000-000000000001', 'Pat Client', true, 'signed in person') $$,
  'a manager records the client''s signature');

reset role;
select results_eq(
  $$ select status, client_signature_name, client_signature_date is not null
     from public.crm_contracts where id = 'e4000000-0000-0000-0000-000000000001' $$,
  $$ values ('fully_signed'::text, 'Pat Client'::text, true) $$,
  'status, signer name and date are set together');
select results_eq(
  $$ select signer_name, resulting_status, method, recorded_by, note, char_length(content_sha256)
     from public.contract_signature_events where contract_id = 'e4000000-0000-0000-0000-000000000001' $$,
  $$ values ('Pat Client'::text, 'fully_signed'::text, 'manager_attested'::text,
             'e1000000-0000-0000-0000-000000000001'::uuid, 'signed in person'::text, 64) $$,
  'an evidence row records who, what, how and a content hash');
select is(
  (select content_sha256 from public.contract_signature_events where contract_id = 'e4000000-0000-0000-0000-000000000001'),
  (select encode(sha256(convert_to((to_jsonb(c) - 'status' - 'updated_at' - 'client_signature_name' - 'client_signature_date')::text, 'UTF8')), 'hex')
     from public.crm_contracts c where c.id = 'e4000000-0000-0000-0000-000000000001'),
  'the stored hash still matches the (frozen) contract terms');
select is((select count(*)::int from public.audit_log where action = 'contract.signature_recorded'
            and target_id = 'e4000000-0000-0000-0000-000000000001'), 1, 'the signature is audited');

-- ---------------------------------------------------------------------------
-- Signed contracts are frozen
-- ---------------------------------------------------------------------------
set local role authenticated;
set local "request.jwt.claim.sub" to 'e1000000-0000-0000-0000-000000000001';
select throws_ok(
  $$ update public.crm_contracts set event_name = 'Renamed' where id = 'e4000000-0000-0000-0000-000000000001' $$,
  '42501', null, 'the terms of a signed contract cannot be edited');
select throws_ok(
  $$ update public.crm_contracts set guest_count = 500 where id = 'e4000000-0000-0000-0000-000000000003' $$,
  '42501', null, 'nor those of a partially signed one');
select throws_ok(
  $$ update public.crm_contracts set status = 'draft' where id = 'e4000000-0000-0000-0000-000000000001' $$,
  '42501', null, 'a fully signed contract cannot be reset to draft');
select throws_ok(
  $$ select public.record_contract_signature('e4000000-0000-0000-0000-000000000001', 'Someone Else') $$,
  'P0001', null, 'a fully signed contract cannot be signed again');
select lives_ok(
  $$ update public.crm_contracts set status = 'disputed' where id = 'e4000000-0000-0000-0000-000000000001' $$,
  'a signed contract can still be marked disputed');

select lives_ok(
  $$ select public.record_contract_signature('e4000000-0000-0000-0000-000000000003', 'Pat Client', true) $$,
  'a partially signed contract can be completed');

-- ---------------------------------------------------------------------------
-- Evidence visibility and immutability
-- ---------------------------------------------------------------------------
select is((select count(*)::int from public.contract_signature_events), 3, 'managers can read the evidence rows');
select throws_ok(
  $$ update public.contract_signature_events set signer_name = 'Edited' $$,
  '42501', null, 'managers cannot edit evidence');
select throws_ok(
  $$ delete from public.contract_signature_events $$,
  '42501', null, 'managers cannot delete evidence');
select throws_ok(
  $$ insert into public.contract_signature_events (contract_id, organization_id, venue_id, signer_name, resulting_status, content_sha256)
     values ('e4000000-0000-0000-0000-000000000001', 'e2000000-0000-0000-0000-00000000000a', 'e3000000-0000-0000-0000-0000000000a1', 'Fake', 'fully_signed', repeat('a', 64)) $$,
  '42501', null, 'clients cannot insert evidence directly');

set local "request.jwt.claim.sub" to 'e1000000-0000-0000-0000-000000000002';
select is((select count(*)::int from public.contract_signature_events), 0, 'staff cannot read the evidence rows');

select * from finish();
rollback;

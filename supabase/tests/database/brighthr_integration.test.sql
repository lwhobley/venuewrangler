-- pgTAP tests for the BrightHR integration (supabase/migrations/20261125100000).
begin;
select plan(18);

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-000000000002', 'org-a-owner@example.com'),
  ('00000000-0000-0000-0000-000000000004', 'venue-a1-manager@example.com'),
  ('00000000-0000-0000-0000-000000000005', 'venue-a1-staff@example.com'),
  ('00000000-0000-0000-0000-000000000006', 'org-b-owner@example.com'),
  ('00000000-0000-0000-0000-000000000007', 'venue-a2-staff@example.com');

insert into public.organizations (id, name) values
  ('10000000-0000-0000-0000-00000000000a', 'Org A'),
  ('10000000-0000-0000-0000-00000000000b', 'Org B');

insert into public.venues (id, organization_id, name) values
  ('20000000-0000-0000-0000-0000000000a1', '10000000-0000-0000-0000-00000000000a', 'Venue A1'),
  ('20000000-0000-0000-0000-0000000000a2', '10000000-0000-0000-0000-00000000000a', 'Venue A2');

insert into public.memberships (user_id, organization_id, venue_id, role) values
  ('00000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-00000000000a', null, 'organization_owner'),
  ('00000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-0000000000a1', 'venue_manager'),
  ('00000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-0000000000a1', 'staff'),
  ('00000000-0000-0000-0000-000000000006', '10000000-0000-0000-0000-00000000000b', null, 'organization_owner'),
  ('00000000-0000-0000-0000-000000000007', '10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-0000000000a2', 'staff');

-- Seeded as the table owner, the way the Edge Function's service-role client writes them.
insert into public.brighthr_connections (id, organization_id, venue_id, client_id, encrypted_client_secret)
values ('30000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-00000000000b',
        '20000000-0000-0000-0000-0000000000a1', 'client-abc', 'v1.iv.ciphertext');

insert into public.brighthr_employees (connection_id, external_employee_id, given_name, family_name) values
  ('30000000-0000-0000-0000-000000000001', 'bhr-1', 'Ada', 'Lovelace'),
  ('30000000-0000-0000-0000-000000000001', 'bhr-2', 'Alan', 'Turing');

insert into public.brighthr_absences
  (connection_id, external_absence_id, external_employee_id, absence_type, start_date, end_date)
values ('30000000-0000-0000-0000-000000000001', 'abs-1', 'bhr-1', 'Holiday', '2026-12-01', '2026-12-03');

select is(
  (select organization_id from public.brighthr_connections where id = '30000000-0000-0000-0000-000000000001'),
  '10000000-0000-0000-0000-00000000000a'::uuid,
  'organization_id is derived from the venue, not trusted from the writer'
);

-- ---------------------------------------------------------------------------
-- Reads
-- ---------------------------------------------------------------------------
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000004';

select is(
  (select client_id from public.brighthr_connections where venue_id = '20000000-0000-0000-0000-0000000000a1'),
  'client-abc',
  'venue manager sees their venue''s BrightHR connection'
);
select throws_ok(
  $$ select encrypted_client_secret from public.brighthr_connections $$,
  '42501', null,
  'venue manager cannot select the encrypted client secret'
);
select is(
  (select count(*)::int from public.brighthr_employees), 2,
  'venue manager sees the imported BrightHR employees'
);
select is(
  (select count(*)::int from public.brighthr_absences), 1,
  'venue manager sees imported absences'
);
select throws_ok(
  $$ insert into public.brighthr_absences (connection_id, external_absence_id, external_employee_id,
       absence_type, start_date, end_date)
     values ('30000000-0000-0000-0000-000000000001', 'x', 'bhr-1', 'Holiday', '2026-01-01', '2026-01-01') $$,
  '42501', null,
  'clients cannot write imported data'
);
select throws_ok(
  $$ update public.brighthr_connections set client_id = 'evil' $$,
  '42501', null,
  'clients cannot modify the connection'
);

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000005';
select is(
  (select count(*)::int from public.brighthr_connections) + (select count(*)::int from public.brighthr_employees)
    + (select count(*)::int from public.brighthr_absences),
  0,
  'staff see no BrightHR data'
);

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000006';
select is(
  (select count(*)::int from public.brighthr_connections) + (select count(*)::int from public.brighthr_employees),
  0,
  'another organization''s owner sees nothing'
);

-- ---------------------------------------------------------------------------
-- link_brighthr_employee
-- ---------------------------------------------------------------------------
select throws_ok(
  $$ select public.link_brighthr_employee('30000000-0000-0000-0000-000000000001', 'bhr-1',
       '00000000-0000-0000-0000-000000000006') $$,
  '42501', null,
  'another organization cannot link employees'
);

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000005';
select throws_ok(
  $$ select public.link_brighthr_employee('30000000-0000-0000-0000-000000000001', 'bhr-1',
       '00000000-0000-0000-0000-000000000005') $$,
  '42501', null,
  'staff cannot link employees'
);

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000004';
select throws_ok(
  $$ select public.link_brighthr_employee('30000000-0000-0000-0000-000000000001', 'bhr-1',
       '00000000-0000-0000-0000-000000000007') $$,
  '22023', null,
  'cannot link a member of a different venue'
);
select throws_ok(
  $$ select public.link_brighthr_employee('30000000-0000-0000-0000-000000000001', 'nope',
       '00000000-0000-0000-0000-000000000005') $$,
  'P0002', null,
  'cannot link an unknown BrightHR employee'
);

select lives_ok(
  $$ select public.link_brighthr_employee('30000000-0000-0000-0000-000000000001', 'bhr-1',
       '00000000-0000-0000-0000-000000000005') $$,
  'manager links a BrightHR employee to a venue member'
);
select is(
  (select linked_by from public.brighthr_employee_mappings where external_employee_id = 'bhr-1'),
  '00000000-0000-0000-0000-000000000004'::uuid,
  'link records who made it'
);

select public.link_brighthr_employee('30000000-0000-0000-0000-000000000001', 'bhr-2',
  '00000000-0000-0000-0000-000000000005');
select is(
  (select array_agg(external_employee_id) from public.brighthr_employee_mappings),
  array['bhr-2'],
  'moving a member to another BrightHR employee replaces the old link'
);

select public.link_brighthr_employee('30000000-0000-0000-0000-000000000001', 'bhr-2', null);
select is(
  (select count(*)::int from public.brighthr_employee_mappings), 0,
  'a null staff id unlinks'
);

-- ---------------------------------------------------------------------------
-- Removing a member drops their link
-- ---------------------------------------------------------------------------
select public.link_brighthr_employee('30000000-0000-0000-0000-000000000001', 'bhr-1',
  '00000000-0000-0000-0000-000000000005');
reset role;
delete from public.memberships
where user_id = '00000000-0000-0000-0000-000000000005'
  and venue_id = '20000000-0000-0000-0000-0000000000a1';
select is(
  (select count(*)::int from public.brighthr_employee_mappings), 0,
  'deleting the membership removes the BrightHR link'
);

select * from finish();
rollback;

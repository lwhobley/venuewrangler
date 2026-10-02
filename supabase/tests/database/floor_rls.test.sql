-- pgTAP authorization and functionality tests for floor module (20261002260000).
-- Fixtures: Org A, Venue A1 (manager 004, staff 005), Org B, Venue B1 (owner 006).

begin;
select plan(15);

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
-- 1. Trigger test: floor_plans derives organization_id
-- ---------------------------------------------------------------------------
insert into public.floor_plans (id, venue_id, organization_id, name)
values (
  '50000000-0000-0000-0000-000000000001',
  '20000000-0000-0000-0000-0000000000a1',
  '10000000-0000-0000-0000-00000000000b',
  'Main Dining'
);

select results_eq(
  $$ select organization_id from public.floor_plans where id = '50000000-0000-0000-0000-000000000001' $$,
  $$ values ('10000000-0000-0000-0000-00000000000a'::uuid) $$,
  'floor plan organization_id is derived from venue_id on insert'
);

-- ---------------------------------------------------------------------------
-- 2. Trigger test: floor_tables derives venue_id and organization_id from plan
-- ---------------------------------------------------------------------------
insert into public.floor_tables (
  id, floor_plan_id, venue_id, organization_id, label, capacity
) values
  ('60000000-0000-0000-0000-000000000001', '50000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-00000000000b', '10000000-0000-0000-0000-00000000000b', 'T1', 4),
  ('60000000-0000-0000-0000-000000000002', '50000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-00000000000b', '10000000-0000-0000-0000-00000000000b', 'T2', 4);

select results_eq(
  $$ select venue_id, organization_id from public.floor_tables where id = '60000000-0000-0000-0000-000000000001' $$,
  $$ values ('20000000-0000-0000-0000-0000000000a1'::uuid, '10000000-0000-0000-0000-00000000000a'::uuid) $$,
  'floor table derives venue_id and organization_id from floor plan'
);

-- ---------------------------------------------------------------------------
-- 3. Trigger test: floor_table_assignments derives venue_id and organization_id
-- ---------------------------------------------------------------------------
insert into public.floor_table_assignments (
  id, table_id, venue_id, organization_id, starts_at, ends_at
) values (
  '70000000-0000-0000-0000-000000000001',
  '60000000-0000-0000-0000-000000000001',
  '20000000-0000-0000-0000-00000000000b',
  '10000000-0000-0000-0000-00000000000b',
  now(),
  now() + interval '2 hours'
);

select results_eq(
  $$ select venue_id, organization_id from public.floor_table_assignments where id = '70000000-0000-0000-0000-000000000001' $$,
  $$ values ('20000000-0000-0000-0000-0000000000a1'::uuid, '10000000-0000-0000-0000-00000000000a'::uuid) $$,
  'floor table assignment derives venue_id and organization_id from table'
);

-- ---------------------------------------------------------------------------
-- 4. Manager can create floor plan
-- ---------------------------------------------------------------------------
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000004'; -- manager

select lives_ok(
  $$ insert into public.floor_plans (venue_id, name)
     values ('20000000-0000-0000-0000-0000000000a1', 'Patio Plan') $$,
  'manager can create floor plan'
);

-- ---------------------------------------------------------------------------
-- 5. Staff cannot create floor plan (manager-only policy)
-- ---------------------------------------------------------------------------
reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000005'; -- staff

select throws_ok(
  $$ insert into public.floor_plans (venue_id, name)
     values ('20000000-0000-0000-0000-0000000000a1', 'Rooftop Plan') $$,
  '42501',
  null,
  'staff cannot create floor plan (manager-write only)'
);

-- ---------------------------------------------------------------------------
-- 6 & 7. Staff can view floor plans; Org B member cannot
-- ---------------------------------------------------------------------------
select results_ne(
  $$ select count(*)::int from public.floor_plans where venue_id = '20000000-0000-0000-0000-0000000000a1' $$,
  $$ values (0) $$,
  'staff can select floor plans for venue A1'
);

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000006'; -- org B

select is_empty(
  $$ select id from public.floor_plans where venue_id = '20000000-0000-0000-0000-0000000000a1' $$,
  'org B user cannot select floor plans from venue A1 (tenant isolation)'
);

-- ---------------------------------------------------------------------------
-- 8 & 9. RPC update_floor_table_status
-- ---------------------------------------------------------------------------
reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000005'; -- staff

select lives_ok(
  $$ select public.update_floor_table_status(
       '20000000-0000-0000-0000-0000000000a1',
       '60000000-0000-0000-0000-000000000001',
       'dirty'
     ) $$,
  'staff can update table status to dirty'
);

select throws_ok(
  $$ select public.update_floor_table_status(
       '20000000-0000-0000-0000-0000000000a1',
       '60000000-0000-0000-0000-000000000001',
       'invalid_status_value'
     ) $$,
  '22023',
  null,
  'invalid table status raises 22023'
);

-- ---------------------------------------------------------------------------
-- 10, 11 & 12. RPC merge_floor_tables and split_floor_tables
-- ---------------------------------------------------------------------------
select throws_ok(
  $$ select public.merge_floor_tables(
       '20000000-0000-0000-0000-0000000000a1',
       array['60000000-0000-0000-0000-000000000001']::uuid[]
     ) $$,
  '22023',
  null,
  'merging fewer than 2 tables raises 22023'
);

select lives_ok(
  $$ select public.merge_floor_tables(
       '20000000-0000-0000-0000-0000000000a1',
       array['60000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000002']::uuid[],
       8
     ) $$,
  'merging two tables succeeds'
);

select lives_ok(
  $$ select public.split_floor_tables(
       '20000000-0000-0000-0000-0000000000a1',
       (select merge_group_id from public.floor_tables where id = '60000000-0000-0000-0000-000000000001')
     ) $$,
  'splitting merged tables succeeds'
);

-- ---------------------------------------------------------------------------
-- 13. RPC assign_tables_to_reservation
-- ---------------------------------------------------------------------------
reset role;
insert into public.reservations (
  id, venue_id, organization_id, guest_name, party_size, reservation_time
) values (
  '40000000-0000-0000-0000-000000000009',
  '20000000-0000-0000-0000-0000000000a1',
  '10000000-0000-0000-0000-00000000000a',
  'VIP Party', 4, now()
);

set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000005'; -- staff

select lives_ok(
  $$ select public.assign_tables_to_reservation(
       '20000000-0000-0000-0000-0000000000a1',
       array['60000000-0000-0000-0000-000000000001']::uuid[],
       '40000000-0000-0000-0000-000000000009',
       'seated'
     ) $$,
  'assigning table to reservation succeeds and updates table state'
);

-- ---------------------------------------------------------------------------
-- 14 & 15. Non-member (Org B) forbidden from RPC and viewing tables
-- ---------------------------------------------------------------------------
reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000006'; -- Org B

select throws_ok(
  $$ select public.merge_floor_tables(
       '20000000-0000-0000-0000-0000000000a1',
       array['60000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000002']::uuid[]
     ) $$,
  '42501',
  null,
  'non-member cannot execute merge_floor_tables'
);

select is_empty(
  $$ select id from public.floor_tables where venue_id = '20000000-0000-0000-0000-0000000000a1' $$,
  'org B user cannot view floor tables from venue A1'
);

select * from finish();
rollback;

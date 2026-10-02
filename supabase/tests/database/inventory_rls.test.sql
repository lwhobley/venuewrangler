-- pgTAP authorization tests for inventory_items (supabase/migrations/20261002110000). Same
-- org/venue/membership fixture shape as operational_tasks_rls.test.sql.

begin;
select plan(11);

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-000000000002', 'org-a-owner@example.com'),
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
  ('00000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-00000000000a', null, 'organization_owner'),
  ('00000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-0000000000a1', 'venue_manager'),
  ('00000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-0000000000a1', 'staff'),
  ('00000000-0000-0000-0000-000000000006', '10000000-0000-0000-0000-00000000000b', null, 'organization_owner');

-- ---------------------------------------------------------------------------
-- insert
-- ---------------------------------------------------------------------------

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000005';

select throws_ok(
  $$ insert into public.inventory_items (venue_id, name, quantity, unit) values ('20000000-0000-0000-0000-0000000000a1', 'Rogue item', 1, 'case') $$,
  '42501',
  null,
  'staff cannot create an inventory item (not venue_manager+)'
);

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000004';

select lives_ok(
  $$ insert into public.inventory_items (id, venue_id, name, quantity, unit, unit_cost_usd)
     values ('30000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-0000000000a1', 'Vodka 1L', 12, 'bottle', 18.50) $$,
  'venue_manager can create an inventory item in their venue'
);

select is(
  (select organization_id from public.inventory_items where id = '30000000-0000-0000-0000-000000000001'),
  '10000000-0000-0000-0000-00000000000a'::uuid,
  'organization_id is auto-derived from venue_id'
);

select is(
  (select updated_by from public.inventory_items where id = '30000000-0000-0000-0000-000000000001'),
  '00000000-0000-0000-0000-000000000004'::uuid,
  'updated_by is always the calling user'
);

-- ---------------------------------------------------------------------------
-- select
-- ---------------------------------------------------------------------------

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000005';

select is(
  (select count(*)::int from public.inventory_items where id = '30000000-0000-0000-0000-000000000001'),
  1,
  'a venue member (not just a manager) can see inventory in their venue'
);

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000006';

select is(
  (select count(*)::int from public.inventory_items),
  0,
  'org_b_owner cannot see org_a''s inventory (cross-tenant)'
);

-- ---------------------------------------------------------------------------
-- update: managers only
-- ---------------------------------------------------------------------------

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000005';

select lives_ok(
  $$ update public.inventory_items set quantity = 0 where id = '30000000-0000-0000-0000-000000000001' $$,
  'a staff member''s update attempt executes without error but matches no rows'
);

select is(
  (select quantity from public.inventory_items where id = '30000000-0000-0000-0000-000000000001'),
  12.00::numeric,
  'the item''s quantity is unchanged by the staff member''s no-op update'
);

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000004';

select lives_ok(
  $$ update public.inventory_items set quantity = 10 where id = '30000000-0000-0000-0000-000000000001' $$,
  'venue_manager can update an inventory item in their venue'
);

select is(
  (select quantity from public.inventory_items where id = '30000000-0000-0000-0000-000000000001'),
  10.00::numeric,
  'the quantity was actually updated'
);

-- ---------------------------------------------------------------------------
-- delete: managers only
-- ---------------------------------------------------------------------------

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000005';

select lives_ok(
  $$ delete from public.inventory_items where id = '30000000-0000-0000-0000-000000000001' $$,
  'a staff member''s delete attempt executes without error (no delete policy covers them)'
);

select * from finish();
rollback;

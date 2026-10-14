-- pgTAP tests for supabase/migrations/20261014090000_floor_plan_studio_objects.sql:
-- the `objects` column defaults to an empty array, must be an array, and follows the
-- existing manager-write / member-read RLS on floor_plan_studio_layouts.

begin;
select plan(9);

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000000f2', 'fps-objects-manager@example.com'),
  ('00000000-0000-0000-0000-0000000000f3', 'fps-objects-staff@example.com'),
  ('00000000-0000-0000-0000-0000000000f4', 'fps-objects-owner@example.com');

insert into public.organizations (id, name) values
  ('10000000-0000-0000-0000-0000000000f1', 'FPS Objects Org');

insert into public.venues (id, organization_id, name) values
  ('20000000-0000-0000-0000-0000000000f1', '10000000-0000-0000-0000-0000000000f1', 'FPS Objects Venue');

insert into public.memberships (user_id, organization_id, venue_id, role) values
  ('00000000-0000-0000-0000-0000000000f4', '10000000-0000-0000-0000-0000000000f1', null, 'organization_owner'),
  ('00000000-0000-0000-0000-0000000000f2', '10000000-0000-0000-0000-0000000000f1', '20000000-0000-0000-0000-0000000000f1', 'venue_manager'),
  ('00000000-0000-0000-0000-0000000000f3', '10000000-0000-0000-0000-0000000000f1', '20000000-0000-0000-0000-0000000000f1', 'staff');

insert into public.floor_plans (id, organization_id, venue_id, name) values
  ('40000000-0000-0000-0000-0000000000f1', '10000000-0000-0000-0000-0000000000f1', '20000000-0000-0000-0000-0000000000f1', 'Ballroom');

-- 1-2. Column shape.
select col_type_is('public', 'floor_plan_studio_layouts', 'objects', 'jsonb', 'objects is jsonb');
select col_has_default('public', 'floor_plan_studio_layouts', 'objects', 'objects has a default');

-- 3. A layout saved without objects (the pre-existing client) gets an empty array.
insert into public.floor_plan_studio_layouts (id, venue_id, floor_plan_id, width_feet, depth_feet)
values ('50000000-0000-0000-0000-0000000000f1', '20000000-0000-0000-0000-0000000000f1', '40000000-0000-0000-0000-0000000000f1', 40, 30);

select is(
  (select objects from public.floor_plan_studio_layouts where id = '50000000-0000-0000-0000-0000000000f1'),
  '[]'::jsonb,
  'a layout saved without objects defaults to an empty array'
);

-- 4. Non-array values are rejected.
select throws_ok(
  $$ update public.floor_plan_studio_layouts set objects = '{"id": "x"}'::jsonb where id = '50000000-0000-0000-0000-0000000000f1' $$,
  '23514',
  null,
  'objects must be a JSON array'
);

-- 5. A venue manager can save objects alongside the tables.
reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-0000000000f2';

select lives_ok(
  $$ update public.floor_plan_studio_layouts
     set objects = '[{"id":"o1","kind":"stage","description":"Stage","x":10,"y":8,"widthFeet":16,"depthFeet":12,"rotationDegrees":0}]'::jsonb
     where id = '50000000-0000-0000-0000-0000000000f1' $$,
  'venue_manager can save objects'
);

-- 6. A venue staff member cannot change objects (RLS filters the row, so nothing changes).
reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-0000000000f3';

update public.floor_plan_studio_layouts
set objects = '[]'::jsonb
where id = '50000000-0000-0000-0000-0000000000f1';

reset role;

select is(
  jsonb_array_length((select objects from public.floor_plan_studio_layouts where id = '50000000-0000-0000-0000-0000000000f1')),
  1,
  'venue staff cannot clear objects (update filtered by RLS)'
);

-- 7. Existing table data is untouched by the objects write.
select is(
  (select layout from public.floor_plan_studio_layouts where id = '50000000-0000-0000-0000-0000000000f1'),
  '[]'::jsonb,
  'the table layout column is unchanged by object writes'
);

-- 8. Non-array values are rejected on insert too.
select throws_ok(
  $$ insert into public.floor_plan_studio_layouts (venue_id, floor_plan_id, width_feet, depth_feet, objects)
     values ('20000000-0000-0000-0000-0000000000f1', '40000000-0000-0000-0000-0000000000f1', 40, 30, 'null'::jsonb) $$,
  '23514',
  null,
  'objects must be a JSON array on insert'
);

-- 9. Member read still works: a staff member sees the layout with its objects.
reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-0000000000f3';

select is(
  (select count(*)::int from public.floor_plan_studio_layouts where id = '50000000-0000-0000-0000-0000000000f1'),
  1,
  'venue staff can still read the layout'
);

select * from finish();
rollback;

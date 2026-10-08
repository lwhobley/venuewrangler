-- pgTAP authorization tests for events (supabase/migrations/20261002180000). Same
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
  $$ insert into public.events (venue_id, name, start_time, end_time) values ('20000000-0000-0000-0000-0000000000a1', 'Rogue event', now(), now() + interval '2 hours') $$,
  '42501',
  null,
  'staff cannot create an event (not venue_manager+)'
);

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000004';

select lives_ok(
  $$ insert into public.events (id, venue_id, name, start_time, end_time)
     values ('30000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-0000000000a1', 'Friday night DJ set', now(), now() + interval '3 hours') $$,
  'venue_manager can create an event in their venue'
);

select is(
  (select organization_id from public.events where id = '30000000-0000-0000-0000-000000000001'),
  '10000000-0000-0000-0000-00000000000a'::uuid,
  'organization_id is auto-derived from venue_id'
);

select is(
  (select created_by from public.events where id = '30000000-0000-0000-0000-000000000001'),
  '00000000-0000-0000-0000-000000000004'::uuid,
  'created_by is always the calling user'
);

select throws_ok(
  $$ insert into public.events (venue_id, name, start_time, end_time) values ('20000000-0000-0000-0000-0000000000a1', 'Backwards event', now(), now() - interval '1 hour') $$,
  '23514',
  null,
  'an event cannot end before it starts (check constraint)'
);

-- ---------------------------------------------------------------------------
-- select
-- ---------------------------------------------------------------------------

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000005';

select is(
  (select count(*)::int from public.events where id = '30000000-0000-0000-0000-000000000001'),
  1,
  'a venue member can see an event in their venue'
);

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000006';

select is(
  (select count(*)::int from public.events),
  0,
  'org_b_owner cannot see org_a''s events (cross-tenant)'
);

-- ---------------------------------------------------------------------------
-- update / delete: managers only
-- ---------------------------------------------------------------------------

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000005';

select lives_ok(
  $$ update public.events set status = 'cancelled' where id = '30000000-0000-0000-0000-000000000001' $$,
  'a staff member''s update attempt executes without error but matches no rows'
);
select is(
  (select status from public.events where id = '30000000-0000-0000-0000-000000000001'),
  'planned',
  'staff cannot change the event status'
);

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000004';

select lives_ok(
  $$ update public.events set status = 'confirmed' where id = '30000000-0000-0000-0000-000000000001' $$,
  'venue_manager can update an event in their venue'
);
select is(
  (select status from public.events where id = '30000000-0000-0000-0000-000000000001'),
  'confirmed',
  'manager update changes the event status'
);

select * from finish();
rollback;

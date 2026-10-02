-- pgTAP authorization tests for operational_tasks (supabase/migrations/20261002010000).
-- Reuses the organization/venue/membership fixtures from foundation_rls.test.sql's cast:
-- org_a (owner=...002, admin=...003), venue A1 (manager=...004, staff=...005), org_b
-- (owner=...006). See that file for the full roster if these ids look unfamiliar.

begin;
select plan(14);

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
-- insert
-- ---------------------------------------------------------------------------

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000005';

select throws_ok(
  $$ insert into public.operational_tasks (venue_id, title) values ('20000000-0000-0000-0000-0000000000a1', 'Rogue task') $$,
  '42501',
  null,
  'staff cannot create a task (not venue_manager+)'
);

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000004';

select lives_ok(
  $$ insert into public.operational_tasks (id, venue_id, title, assigned_to)
     values ('30000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-0000000000a1', 'Restock ice', '00000000-0000-0000-0000-000000000005') $$,
  'venue_manager can create and assign a task in their venue'
);

select is(
  (select organization_id from public.operational_tasks where id = '30000000-0000-0000-0000-000000000001'),
  '10000000-0000-0000-0000-00000000000a'::uuid,
  'organization_id is auto-derived from venue_id, not client-supplied'
);

select is(
  (select created_by from public.operational_tasks where id = '30000000-0000-0000-0000-000000000001'),
  '00000000-0000-0000-0000-000000000004'::uuid,
  'created_by is always the calling user'
);

-- ---------------------------------------------------------------------------
-- select
-- ---------------------------------------------------------------------------

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000005';

select is(
  (select count(*)::int from public.operational_tasks where id = '30000000-0000-0000-0000-000000000001'),
  1,
  'a venue member can see a task in their venue'
);

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000006';

select is(
  (select count(*)::int from public.operational_tasks),
  0,
  'org_b_owner cannot see org_a''s tasks (cross-tenant)'
);

-- ---------------------------------------------------------------------------
-- update: assignee may change status only
-- ---------------------------------------------------------------------------

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000005';

select lives_ok(
  $$ update public.operational_tasks set status = 'completed' where id = '30000000-0000-0000-0000-000000000001' $$,
  'the assignee can mark their own task completed'
);

select is(
  (select completed_at is not null from public.operational_tasks where id = '30000000-0000-0000-0000-000000000001'),
  true,
  'completed_at is auto-set when status moves to completed'
);

select throws_ok(
  $$ update public.operational_tasks set title = 'Hijacked title' where id = '30000000-0000-0000-0000-000000000001' $$,
  '42501',
  null,
  'the assignee cannot change the task''s title (column-level trigger enforcement)'
);

-- ---------------------------------------------------------------------------
-- update: a non-assignee, non-manager staff member cannot touch the task at all
-- ---------------------------------------------------------------------------

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000008';

select lives_ok(
  $$ update public.operational_tasks set status = 'cancelled' where id = '30000000-0000-0000-0000-000000000001' $$,
  'an unrelated staff member''s update attempt executes without error but matches no rows'
);

select is(
  (select status from public.operational_tasks where id = '30000000-0000-0000-0000-000000000001'),
  'completed',
  'the task''s status is unchanged by the unrelated staff member''s no-op update'
);

-- ---------------------------------------------------------------------------
-- delete: managers only
-- ---------------------------------------------------------------------------

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000005';

select lives_ok(
  $$ delete from public.operational_tasks where id = '30000000-0000-0000-0000-000000000001' $$,
  'the assignee''s delete attempt executes without error (no delete policy covers them)'
);

select is(
  (select count(*)::int from public.operational_tasks where id = '30000000-0000-0000-0000-000000000001'),
  1,
  'the task still exists afterward (the assignee has no delete rights)'
);

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000004';

select lives_ok(
  $$ delete from public.operational_tasks where id = '30000000-0000-0000-0000-000000000001' $$,
  'venue_manager can delete a task in their venue'
);

select * from finish();
rollback;

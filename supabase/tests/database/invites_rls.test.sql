-- pgTAP authorization tests for invites (supabase/migrations/20261002100000). Same
-- org/venue/membership fixture shape as operational_tasks_rls.test.sql.

begin;
select plan(13);

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
  $$ insert into public.invites (venue_id, email, role) values ('20000000-0000-0000-0000-0000000000a1', 'new-hire@example.com', 'staff') $$,
  '42501',
  null,
  'staff cannot create an invite (not venue_manager+)'
);

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000004';

select lives_ok(
  $$ insert into public.invites (id, venue_id, email, role)
     values ('30000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-0000000000a1', 'New-Hire@Example.com', 'staff') $$,
  'venue_manager can create an invite for their venue'
);

select is(
  (select organization_id from public.invites where id = '30000000-0000-0000-0000-000000000001'),
  '10000000-0000-0000-0000-00000000000a'::uuid,
  'organization_id is auto-derived from venue_id'
);

select is(
  (select invited_by from public.invites where id = '30000000-0000-0000-0000-000000000001'),
  '00000000-0000-0000-0000-000000000004'::uuid,
  'invited_by is always the calling user'
);

select is(
  (select email from public.invites where id = '30000000-0000-0000-0000-000000000001'),
  'new-hire@example.com',
  'email is normalized to lowercase/trimmed'
);

select throws_ok(
  $$ insert into public.invites (venue_id, email, role) values ('20000000-0000-0000-0000-0000000000a1', 'new-hire@example.com', 'organization_owner') $$,
  '23514',
  null,
  'an invite cannot be created with an org-level role (check constraint)'
);

-- ---------------------------------------------------------------------------
-- select
-- ---------------------------------------------------------------------------

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000005';

select is(
  (select count(*)::int from public.invites),
  0,
  'a non-manager staff member cannot see venue invites (PII, manager-tier only)'
);

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000002';

select is(
  (select count(*)::int from public.invites where id = '30000000-0000-0000-0000-000000000001'),
  1,
  'the org owner can see an invite for a venue in their organization'
);

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000006';

select is(
  (select count(*)::int from public.invites),
  0,
  'org_b_owner cannot see org_a''s invites (cross-tenant)'
);

-- ---------------------------------------------------------------------------
-- update: pending -> revoked only
-- ---------------------------------------------------------------------------

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000004';

select throws_ok(
  $$ update public.invites set role = 'venue_manager' where id = '30000000-0000-0000-0000-000000000001' $$,
  '42501',
  null,
  'a manager cannot change an invite''s role, only revoke it'
);

select lives_ok(
  $$ update public.invites set status = 'revoked' where id = '30000000-0000-0000-0000-000000000001' $$,
  'venue_manager can revoke a pending invite'
);

select is(
  (select status from public.invites where id = '30000000-0000-0000-0000-000000000001'),
  'revoked',
  'the invite is now revoked'
);

select throws_ok(
  $$ update public.invites set status = 'pending' where id = '30000000-0000-0000-0000-000000000001' $$,
  '42501',
  null,
  'a revoked invite cannot be moved back to pending by a client'
);

select * from finish();
rollback;

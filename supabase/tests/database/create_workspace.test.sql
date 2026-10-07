-- pgTAP tests for public.create_workspace (supabase/migrations/*_create_workspace_self_serve_signup).
-- The self-serve "Launch Workspace" signup path: a brand-new authenticated user with no
-- existing memberships creates their own organization + venue + organization_owner membership.

begin;
select plan(9);

insert into auth.users (id, email) values
  ('30000000-0000-0000-0000-000000000001', 'new-owner@example.com');

set local role authenticated;
set local "request.jwt.claim.sub" to '30000000-0000-0000-0000-000000000001';

select lives_ok(
  $$select * from public.create_workspace('Riverside Hospitality', 'Riverside Taphouse', 'America/Chicago')$$,
  'an authenticated user can create a new workspace'
);

select results_eq(
  $$select role::text from public.memberships where user_id = '30000000-0000-0000-0000-000000000001'::uuid$$,
  $$values ('organization_owner')$$,
  'the creator is granted an organization_owner membership'
);

select is(
  (select venue_id from public.memberships where user_id = '30000000-0000-0000-0000-000000000001'::uuid),
  null::uuid,
  'the owner membership is organization-level (venue_id is null)'
);

select is(
  (select count(*)::int from public.organizations
    where created_by = '30000000-0000-0000-0000-000000000001'::uuid and name = 'Riverside Hospitality'),
  1,
  'exactly one organization was created with the given name'
);

select is(
  (select count(*)::int from public.venues v
    join public.organizations o on o.id = v.organization_id
    where o.created_by = '30000000-0000-0000-0000-000000000001'::uuid and v.name = 'Riverside Taphouse'
      and v.timezone = 'America/Chicago'),
  1,
  'exactly one venue was created under that organization with the given timezone'
);

select throws_ok(
  $$select * from public.create_workspace('  ', 'Some Venue')$$,
  '22023', null,
  'a blank organization name is rejected'
);

select throws_ok(
  $$select * from public.create_workspace('Some Org', '')$$,
  '22023', null,
  'a blank venue name is rejected'
);

reset role;
set local role anon;
select throws_ok(
  $$select * from public.create_workspace('Anon Org', 'Anon Venue')$$,
  '42501', null,
  'an unauthenticated caller cannot create a workspace'
);
reset role;

select is(
  (select count(*)::int from public.organizations where name in ('Anon Org', 'Some Org', '  ')),
  0,
  'none of the rejected calls left partial rows behind'
);

select * from finish();
rollback;

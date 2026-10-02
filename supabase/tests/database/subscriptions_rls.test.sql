-- pgTAP authorization tests for subscriptions (supabase/migrations/20261002130000). Reuses
-- the org_a/org_b fixture shape from ai_usage_rls.test.sql.

begin;
select plan(8);

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-000000000002', 'org-a-owner@example.com'),
  ('00000000-0000-0000-0000-000000000004', 'venue-a1-manager@example.com'),
  ('00000000-0000-0000-0000-000000000006', 'org-b-owner@example.com');

insert into public.organizations (id, name) values
  ('10000000-0000-0000-0000-00000000000a', 'Org A'),
  ('10000000-0000-0000-0000-00000000000b', 'Org B');

insert into public.venues (id, organization_id, name) values
  ('20000000-0000-0000-0000-0000000000a1', '10000000-0000-0000-0000-00000000000a', 'Venue A1');

insert into public.memberships (user_id, organization_id, venue_id, role) values
  ('00000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-00000000000a', null, 'organization_owner'),
  ('00000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-0000000000a1', 'venue_manager'),
  ('00000000-0000-0000-0000-000000000006', '10000000-0000-0000-0000-00000000000b', null, 'organization_owner');

-- Seeded as table owner (bypasses RLS), the same way the stripe-webhook Edge Function's
-- service-role client would write this row in production.
insert into public.subscriptions (organization_id, stripe_customer_id, status) values
  ('10000000-0000-0000-0000-00000000000a', 'cus_test123', 'active');

-- ---------------------------------------------------------------------------
-- select
-- ---------------------------------------------------------------------------

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000002';

select is(
  (select status from public.subscriptions where organization_id = '10000000-0000-0000-0000-00000000000a'),
  'active',
  'the org owner can see their organization''s subscription'
);

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000004';

select is(
  (select count(*)::int from public.subscriptions),
  0,
  'a venue_manager (not an org admin/owner) cannot see the organization''s subscription'
);

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000006';

select is(
  (select count(*)::int from public.subscriptions),
  0,
  'org_b_owner cannot see org_a''s subscription (cross-tenant)'
);

-- ---------------------------------------------------------------------------
-- write: service-role only
-- ---------------------------------------------------------------------------

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000002';

select throws_ok(
  $$ insert into public.subscriptions (organization_id, status) values ('10000000-0000-0000-0000-00000000000b', 'active') $$,
  '42501',
  null,
  'a client can never create a subscription row (service-role/webhook only)'
);

-- No update policy exists for `authenticated` at all, so this UPDATE's USING clause matches
-- zero rows and is a silent no-op (Postgres RLS behavior) rather than raising an exception —
-- same pattern documented in operational_tasks_rls.test.sql.
select lives_ok(
  $$ update public.subscriptions set status = 'canceled' where organization_id = '10000000-0000-0000-0000-00000000000a' $$,
  'a client''s update attempt executes without error but matches no rows (no update policy exists)'
);

select is(
  (select status from public.subscriptions where organization_id = '10000000-0000-0000-0000-00000000000a'),
  'active',
  'the subscription status is unchanged by the client''s no-op update'
);

-- ---------------------------------------------------------------------------
-- subscription_is_entitled
-- ---------------------------------------------------------------------------

reset role;

select is(public.subscription_is_entitled('active'), true, 'active is entitled');
select is(public.subscription_is_entitled('past_due'), false, 'past_due is not entitled');

select * from finish();
rollback;

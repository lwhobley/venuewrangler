-- pgTAP authorization tests for ai_usage_events / ai_budget_reservations
-- (supabase/migrations/20261002080000). Reuses the same org/venue/membership roster shape as
-- the other test files.

begin;
select plan(8);

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-000000000002', 'org-a-owner@example.com'),
  ('00000000-0000-0000-0000-000000000006', 'org-b-owner@example.com');

insert into public.organizations (id, name) values
  ('10000000-0000-0000-0000-00000000000a', 'Org A'),
  ('10000000-0000-0000-0000-00000000000b', 'Org B');

insert into public.memberships (user_id, organization_id, venue_id, role) values
  ('00000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-00000000000a', null, 'organization_owner'),
  ('00000000-0000-0000-0000-000000000006', '10000000-0000-0000-0000-00000000000b', null, 'organization_owner');

-- Seeded as table owner (bypasses RLS), the same way the Edge Function's service-role client
-- would write these rows in production.
insert into public.ai_usage_events (organization_id, task, model, input_tokens, output_tokens, cost_usd) values
  ('10000000-0000-0000-0000-00000000000a', 'staff_import_parse', 'llama-3.3-70b-versatile', 500, 200, 0.0021);

insert into public.ai_budget_reservations (organization_id, reserved_usd, status, expires_at) values
  ('10000000-0000-0000-0000-00000000000a', 0.05, 'pending', now() + interval '2 minutes');

-- ---------------------------------------------------------------------------
-- ai_usage_events
-- ---------------------------------------------------------------------------

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000002';

select is(
  (select count(*)::int from public.ai_usage_events),
  1,
  'org_a_owner can see their own organization''s AI usage events'
);

select throws_ok(
  $$ insert into public.ai_usage_events (organization_id, task, model) values ('10000000-0000-0000-0000-00000000000a', 'rogue', 'rogue-model') $$,
  '42501',
  null,
  'a client can never write its own AI usage event (service-role only)'
);

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000006';

select is(
  (select count(*)::int from public.ai_usage_events),
  0,
  'org_b_owner cannot see org_a''s AI usage events (cross-tenant)'
);

-- ---------------------------------------------------------------------------
-- ai_budget_reservations
-- ---------------------------------------------------------------------------

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000002';

select is(
  (select count(*)::int from public.ai_budget_reservations),
  1,
  'org_a_owner can see their own organization''s pending budget reservation'
);

select throws_ok(
  $$ insert into public.ai_budget_reservations (organization_id, reserved_usd, expires_at) values ('10000000-0000-0000-0000-00000000000a', 100, now() + interval '1 minute') $$,
  '42501',
  null,
  'a client can never create its own budget reservation (service-role only)'
);

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000006';

select is(
  (select count(*)::int from public.ai_budget_reservations),
  0,
  'org_b_owner cannot see org_a''s budget reservation (cross-tenant)'
);

-- ---------------------------------------------------------------------------
-- ai_org_spend_this_month
-- ---------------------------------------------------------------------------

reset role;

select is(
  public.ai_org_spend_this_month('10000000-0000-0000-0000-00000000000a'),
  0.0521::numeric,
  'ai_org_spend_this_month sums this month''s committed usage plus pending reservations'
);

select is(
  public.ai_org_spend_this_month('10000000-0000-0000-0000-00000000000b'),
  0::numeric,
  'ai_org_spend_this_month returns zero for an organization with no usage or reservations'
);

select * from finish();
rollback;

-- pgTAP: H9 / M6 AI reservation commit caps + entitlement in reserve_ai_budget
-- (20261123150000_ai_budget_commit_caps_and_entitlement.sql).

begin;
select plan(16);

insert into auth.users (id, email) values
  ('d1000000-0000-0000-0000-000000000001', 'ai-owner@example.com'),
  ('d1000000-0000-0000-0000-000000000002', 'ai-staff@example.com');

insert into public.organizations (id, name, created_at) values
  ('d2000000-0000-0000-0000-00000000000a', 'AI Org', now() - interval '60 days');

insert into public.venues (id, organization_id, name) values
  ('d3000000-0000-0000-0000-0000000000a1', 'd2000000-0000-0000-0000-00000000000a', 'AI Venue');

insert into public.memberships (user_id, organization_id, venue_id, role) values
  ('d1000000-0000-0000-0000-000000000001', 'd2000000-0000-0000-0000-00000000000a', null, 'organization_owner');

-- ---------------------------------------------------------------------------
-- Server-side monthly budget (caller-supplied p_monthly_budget_usd ignored)
-- ---------------------------------------------------------------------------
update app_hidden.platform_settings set ai_monthly_org_budget_usd = 0.05;

set local role service_role;
select lives_ok(
  $$ select public.reserve_ai_budget(
       'd2000000-0000-0000-0000-00000000000a',
       'd1000000-0000-0000-0000-000000000001',
       0.04, 999, 20, 10, 120) $$,
  'reserve under the platform budget succeeds even when the caller passes a huge p_monthly_budget_usd'
);

select throws_ok(
  $$ select public.reserve_ai_budget(
       'd2000000-0000-0000-0000-00000000000a',
       'd1000000-0000-0000-0000-000000000001',
       0.02, 999, 20, 10, 120) $$,
  'P0001',
  null,
  'reserve over the platform budget fails despite a huge caller-supplied monthly budget'
);
reset role;

update public.ai_budget_reservations
set status = 'released'
where organization_id = 'd2000000-0000-0000-0000-00000000000a';
update app_hidden.platform_settings set ai_monthly_org_budget_usd = 10;

-- ---------------------------------------------------------------------------
-- Entitlement gate inside reserve_ai_budget (M6)
-- ---------------------------------------------------------------------------
update app_hidden.platform_settings set billing_enforcement = true;

set local role service_role;
select throws_ok(
  $$ select public.reserve_ai_budget(
       'd2000000-0000-0000-0000-00000000000a',
       'd1000000-0000-0000-0000-000000000001',
       0.01, 10, 20, 10, 120) $$,
  'P0001',
  null,
  'reserve refuses an unentitled org when billing_enforcement is on'
);
reset role;

insert into public.subscriptions (organization_id, status)
values ('d2000000-0000-0000-0000-00000000000a', 'active');

set local role service_role;
select lives_ok(
  $$ select public.reserve_ai_budget(
       'd2000000-0000-0000-0000-00000000000a',
       'd1000000-0000-0000-0000-000000000001',
       0.01, 10, 20, 10, 120) $$,
  'reserve allows an entitled org when billing_enforcement is on'
);
reset role;

update app_hidden.platform_settings set billing_enforcement = false;
update public.ai_budget_reservations
set status = 'released'
where organization_id = 'd2000000-0000-0000-0000-00000000000a'
  and status = 'pending';

-- ---------------------------------------------------------------------------
-- Commit caps cost at reserved_usd (H9)
-- ---------------------------------------------------------------------------
insert into public.ai_budget_reservations (id, organization_id, user_id, reserved_usd, status, expires_at)
values (
  'd4000000-0000-0000-0000-0000000000e1',
  'd2000000-0000-0000-0000-00000000000a',
  'd1000000-0000-0000-0000-000000000001',
  0.01,
  'pending',
  now() + interval '1 hour'
);

set local role service_role;
select lives_ok(
  $$ select public.commit_ai_reservation(
       'd4000000-0000-0000-0000-0000000000e1',
       'd2000000-0000-0000-0000-00000000000a',
       'd3000000-0000-0000-0000-0000000000a1',
       'd1000000-0000-0000-0000-000000000001',
       'summary', 'model-x', 100, 100, 9.99) $$,
  'commit accepts an oversize p_cost_usd by capping, not rejecting'
);
reset role;

select is(
  (select cost_usd::numeric from public.ai_usage_events
    where reservation_id = 'd4000000-0000-0000-0000-0000000000e1'),
  0.01,
  'committed cost is capped at reserved_usd'
);
select is(
  (select status from public.ai_budget_reservations
    where id = 'd4000000-0000-0000-0000-0000000000e1'),
  'committed',
  'reservation is marked committed after a capped commit'
);

-- Under-reservation cost is stored as-is.
insert into public.ai_budget_reservations (id, organization_id, user_id, reserved_usd, status, expires_at)
values (
  'd4000000-0000-0000-0000-0000000000e2',
  'd2000000-0000-0000-0000-00000000000a',
  'd1000000-0000-0000-0000-000000000001',
  0.50,
  'pending',
  now() + interval '1 hour'
);

set local role service_role;
select lives_ok(
  $$ select public.commit_ai_reservation(
       'd4000000-0000-0000-0000-0000000000e2',
       'd2000000-0000-0000-0000-00000000000a',
       'd3000000-0000-0000-0000-0000000000a1',
       'd1000000-0000-0000-0000-000000000001',
       'summary', 'model-x', 10, 10, 0.12) $$,
  'commit stores actual cost when it is under the reservation'
);
reset role;

select is(
  (select cost_usd::numeric from public.ai_usage_events
    where reservation_id = 'd4000000-0000-0000-0000-0000000000e2'),
  0.12,
  'under-reservation cost is stored unchanged'
);

-- ---------------------------------------------------------------------------
-- Per-user monthly budget + in-flight reservation enforcement (AI-04)
-- ---------------------------------------------------------------------------
update app_hidden.platform_settings
set ai_monthly_org_budget_usd = 10,
    ai_monthly_user_budget_usd = 0.05;

-- Clean prior usage/reservations for user 1 so the per-user checks start at 0.
delete from public.ai_usage_events
where organization_id = 'd2000000-0000-0000-0000-00000000000a';
update public.ai_budget_reservations
set status = 'released'
where organization_id = 'd2000000-0000-0000-0000-00000000000a'
  and status = 'pending';

set local role service_role;
select lives_ok(
  $$ select public.reserve_ai_budget(
       'd2000000-0000-0000-0000-00000000000a',
       'd1000000-0000-0000-0000-000000000001',
       0.04, 10, 20, 10, 120) $$,
  'reserve under the per-user monthly budget succeeds'
);

select throws_ok(
  $$ select public.reserve_ai_budget(
       'd2000000-0000-0000-0000-00000000000a',
       'd1000000-0000-0000-0000-000000000001',
       0.02, 10, 20, 10, 120) $$,
  'P0001',
  'monthly_user_budget_exceeded',
  'in-flight pending reservation counts toward the per-user monthly cap'
);

select lives_ok(
  $$ select public.reserve_ai_budget(
       'd2000000-0000-0000-0000-00000000000a',
       'd1000000-0000-0000-0000-000000000002',
       0.04, 10, 20, 10, 120) $$,
  'another user in the same org has an independent per-user monthly cap'
);

select is(
  public.ai_user_spend_this_month(
    'd2000000-0000-0000-0000-00000000000a',
    'd1000000-0000-0000-0000-000000000001'
  ),
  0.04::numeric,
  'ai_user_spend_this_month includes only that user''s live pending reservation'
);
reset role;

update public.ai_budget_reservations
set status = 'released'
where organization_id = 'd2000000-0000-0000-0000-00000000000a'
  and user_id = 'd1000000-0000-0000-0000-000000000001'
  and status = 'pending';

insert into public.ai_budget_reservations (organization_id, user_id, reserved_usd, status, expires_at)
values (
  'd2000000-0000-0000-0000-00000000000a',
  'd1000000-0000-0000-0000-000000000001',
  0.10,
  'pending',
  now() - interval '1 minute'
);

insert into public.ai_usage_events (organization_id, venue_id, user_id, task, model, input_tokens, output_tokens, cost_usd)
values (
  'd2000000-0000-0000-0000-00000000000a',
  'd3000000-0000-0000-0000-0000000000a1',
  'd1000000-0000-0000-0000-000000000001',
  'summary', 'model-x', 10, 10, 0.03
);

set local role service_role;
select is(
  public.ai_user_spend_this_month(
    'd2000000-0000-0000-0000-00000000000a',
    'd1000000-0000-0000-0000-000000000001'
  ),
  0.03::numeric,
  'ai_user_spend_this_month counts committed spend and excludes released and expired reservations'
);
reset role;

update app_hidden.platform_settings set ai_monthly_user_budget_usd = 3;

-- Clients still cannot call the service-only RPCs.
set local role authenticated;
set local "request.jwt.claim.sub" to 'd1000000-0000-0000-0000-000000000001';
select throws_ok(
  $$ select public.reserve_ai_budget(
       'd2000000-0000-0000-0000-00000000000a',
       'd1000000-0000-0000-0000-000000000001',
       0.01, 10, 20, 10, 120) $$,
  '42501',
  null,
  'authenticated clients cannot call reserve_ai_budget'
);
select throws_ok(
  $$ select public.ai_user_spend_this_month(
       'd2000000-0000-0000-0000-00000000000a',
       'd1000000-0000-0000-0000-000000000001') $$,
  '42501',
  null,
  'authenticated clients cannot call ai_user_spend_this_month'
);
reset role;

select * from finish();
rollback;

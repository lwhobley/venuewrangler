-- pgTAP tests for public.apply_stripe_subscription_state (supabase/migrations/*_apply_stripe_
-- subscription_state): the single-statement, order-safe write the stripe-webhook function uses.

begin;
select plan(12);

insert into public.organizations (id, name) values
  ('10000000-0000-0000-0000-00000000000a', 'Org A');

-- Checkout creates the row from Stripe's real status (incomplete here, not assumed active).
select is(
  public.apply_stripe_subscription_state(
    '10000000-0000-0000-0000-00000000000a', 'cus_1', 'sub_1', 'price_1', 'incomplete',
    null, false, 'evt_100', 100),
  true,
  'checkout creates the subscription row'
);
select is(
  (select status from public.subscriptions where stripe_customer_id = 'cus_1'),
  'incomplete',
  'status comes from the argument, not an assumed active'
);

-- A newer subscription event applies.
select is(
  public.apply_stripe_subscription_state(
    null, 'cus_1', 'sub_1', 'price_1', 'active', '2027-01-01T00:00:00Z', false, 'evt_200', 200),
  true,
  'a newer event is applied'
);

-- A late, older event must not overwrite it.
select is(
  public.apply_stripe_subscription_state(
    null, 'cus_1', 'sub_1', 'price_1', 'past_due', null, false, 'evt_150', 150),
  false,
  'an older event is rejected'
);
select is(
  (select status from public.subscriptions where stripe_customer_id = 'cus_1'),
  'active',
  'the newer state survived the stale event'
);

-- Replaying the newest event is harmless (same-second events are allowed through).
select is(
  public.apply_stripe_subscription_state(
    null, 'cus_1', 'sub_1', 'price_1', 'active', '2027-01-01T00:00:00Z', false, 'evt_200', 200),
  true,
  'an event with the same timestamp re-applies authoritative state'
);

-- An older checkout cannot clobber newer subscription state either.
select is(
  public.apply_stripe_subscription_state(
    '10000000-0000-0000-0000-00000000000a', 'cus_1', 'sub_1', 'price_1', 'incomplete',
    null, false, 'evt_120', 120),
  false,
  'a stale checkout event is rejected'
);

-- A newer live subscription takes over the row...
select is(
  public.apply_stripe_subscription_state(
    null, 'cus_1', 'sub_2', 'price_1', 'active', null, false, 'evt_400', 400),
  true,
  'a new live subscription for the customer is applied'
);
-- ...and the old one ending afterwards must not cancel it.
select is(
  public.apply_stripe_subscription_state(
    null, 'cus_1', 'sub_1', 'price_1', 'canceled', null, false, 'evt_500', 500),
  false,
  'the old subscription ending does not overwrite the newer one'
);
select is(
  (select status || ':' || stripe_subscription_id from public.subscriptions where stripe_customer_id = 'cus_1'),
  'active:sub_2',
  'the customer still shows the live subscription'
);

-- A customer this app has no row for (another product on the shared Stripe account).
select is(
  public.apply_stripe_subscription_state(
    null, 'cus_unknown', 'sub_x', 'price_x', 'active', null, false, 'evt_300', 300),
  false,
  'an unlinked customer writes nothing'
);

select is(
  (select count(*)::int from information_schema.routine_privileges
    where routine_name = 'apply_stripe_subscription_state'
      and grantee in ('PUBLIC', 'anon', 'authenticated')),
  0,
  'only the service role can execute it'
);

select * from finish();
rollback;

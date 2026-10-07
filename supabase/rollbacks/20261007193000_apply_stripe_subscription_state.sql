-- Removes the atomic Stripe state function.
drop function if exists public.apply_stripe_subscription_state(uuid, text, text, text, text, timestamptz, boolean, text, bigint);

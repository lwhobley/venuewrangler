-- Fixes a gap from 20261002130000_subscriptions_schema.sql: subscription_is_entitled was
-- missing `set search_path = public`, unlike every other function in this codebase — flagged
-- by the live project's own security advisor (function_search_path_mutable). It doesn't touch
-- any table, so there was no functional bug today, but a mutable search_path is exactly the
-- class of issue 20261002060000_harden_try_cast_uuid_search_path.sql fixed earlier for a
-- function that did touch a table — closing it here before it matters.
create or replace function public.subscription_is_entitled(p_status text)
returns boolean
language sql
immutable
set search_path = public
as $$
  select p_status in ('active', 'trialing');
$$;

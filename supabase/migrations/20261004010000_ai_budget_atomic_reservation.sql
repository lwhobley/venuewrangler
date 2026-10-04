-- Fix MEDIUM: AI budget/rate-limit race — check and reservation must be atomic.
-- Concurrent requests could each see "under budget" and jointly overspend, and the
-- 20-calls/10min limit only counted committed ai_usage_events (in-flight calls invisible).
-- This RPC holds a per-org advisory lock, checks committed spend + live pending
-- reservations + caller-provided estimate against the budget, checks the caller's recent
-- usage count (committed + pending reservations as in-flight), and inserts the
-- reservation — all in one transaction.

create or replace function public.reserve_ai_budget(
  p_org_id uuid,
  p_user_id uuid,
  p_estimated_usd numeric,
  p_monthly_budget_usd numeric,
  p_rate_limit_max integer default 20,
  p_rate_limit_window_minutes integer default 10,
  p_ttl_seconds integer default 120
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_reservation_id uuid;
  v_spend numeric;
  v_recent integer;
begin
  -- Serialize budget decisions per org.
  perform pg_advisory_xact_lock(hashtext('ai_budget:' || p_org_id::text));

  select public.ai_org_spend_this_month(p_org_id) into v_spend;
  if coalesce(v_spend, 0) + p_estimated_usd > p_monthly_budget_usd then
    raise exception 'monthly_budget_exceeded' using errcode = 'P0001';
  end if;

  -- Count committed calls plus in-flight pending reservations by this user in the window.
  select count(*) into v_recent from public.ai_usage_events
  where user_id = p_user_id
    and created_at >= now() - (p_rate_limit_window_minutes || ' minutes')::interval;

  select v_recent + count(*) into v_recent from public.ai_budget_reservations
  where organization_id = p_org_id
    and status = 'pending'
    and expires_at > now()
    and created_at >= now() - (p_rate_limit_window_minutes || ' minutes')::interval;

  -- Attribute reservations to users via a best-effort: reservations don't store user_id
  -- (pre-existing schema), so the second count is org-wide in-flight — stricter than
  -- per-user, fail-closed on abuse. Keep it.
  if v_recent >= p_rate_limit_max then
    raise exception 'rate_limited' using errcode = 'P0001';
  end if;

  insert into public.ai_budget_reservations (organization_id, reserved_usd, status, expires_at)
  values (p_org_id, p_estimated_usd, 'pending', now() + (p_ttl_seconds || ' seconds')::interval)
  returning id into v_reservation_id;

  return v_reservation_id;
end;
$$;

revoke execute on function public.reserve_ai_budget(uuid, uuid, numeric, numeric, integer, integer, integer) from public, anon;
grant execute on function public.reserve_ai_budget(uuid, uuid, numeric, numeric, integer, integer, integer) to authenticated;

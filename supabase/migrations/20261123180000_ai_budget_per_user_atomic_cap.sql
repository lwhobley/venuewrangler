-- Audit AI-04: enforce per-user monthly AI budget (committed spend + live in-flight
-- pending reservations) atomically inside public.reserve_ai_budget under the per-org
-- advisory lock, reading the cap from app_hidden.platform_settings.
--
-- Preserves:
--   * public.ai_budget_reservations.user_id (added in 20261017100000; ensured here)
--   * per-org advisory lock hashtext('ai_budget:' || p_org_id::text)
--   * app_hidden.platform_settings lookup (org + per-user monthly caps)
--   * public.org_is_entitled(p_org_id) entitlement gate
--   * per-user rolling window rate-limit check (reservations + legacy events)
--   * service_role-only execute grants

alter table public.ai_budget_reservations
  add column if not exists user_id uuid references auth.users (id) on delete set null;

create index if not exists ai_budget_reservations_org_user_pending_idx
  on public.ai_budget_reservations (organization_id, user_id)
  where status = 'pending';

create index if not exists ai_budget_reservations_user_created_at_idx
  on public.ai_budget_reservations (user_id, created_at);

alter table app_hidden.platform_settings
  add column if not exists ai_monthly_user_budget_usd numeric(10, 4) not null default 3
    check (ai_monthly_user_budget_usd > 0);

create or replace function public.ai_user_spend_this_month(
  p_org_id uuid,
  p_user_id uuid
)
returns numeric
language sql
stable
set search_path = ''
as $$
  select
    coalesce((
      select sum(cost_usd) from public.ai_usage_events
      where organization_id = p_org_id
        and user_id = p_user_id
        and created_at >= date_trunc('month', now(), 'UTC')
    ), 0)
    + coalesce((
      select sum(reserved_usd) from public.ai_budget_reservations
      where organization_id = p_org_id
        and user_id = p_user_id
        and status = 'pending'
        and expires_at > now()
    ), 0);
$$;

revoke all on function public.ai_user_spend_this_month(uuid, uuid)
  from public, anon, authenticated;
grant execute on function public.ai_user_spend_this_month(uuid, uuid)
  to service_role;

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
set search_path = ''
as $$
declare
  v_reservation_id uuid;
  v_spend numeric;
  v_user_spend numeric;
  v_recent integer;
  v_monthly_budget numeric;
  v_monthly_user_budget numeric;
begin
  if p_org_id is null or p_user_id is null then
    raise exception 'organization and user are required' using errcode = '22023';
  end if;
  if p_estimated_usd is null or p_estimated_usd < 0 then
    raise exception 'invalid AI estimate' using errcode = '22023';
  end if;
  if p_rate_limit_max is null or p_rate_limit_max < 1
     or p_rate_limit_window_minutes is null or p_rate_limit_window_minutes < 1
     or p_ttl_seconds is null or p_ttl_seconds < 1 then
    raise exception 'invalid AI rate-limit parameters' using errcode = '22023';
  end if;

  -- Paywall (M6): billable AI spend requires entitlement when enforcement is on.
  if not public.org_is_entitled(p_org_id) then
    raise exception 'subscription_required' using errcode = 'P0001';
  end if;

  select s.ai_monthly_org_budget_usd, s.ai_monthly_user_budget_usd
    into v_monthly_budget, v_monthly_user_budget
  from app_hidden.platform_settings s;
  if v_monthly_budget is null or v_monthly_budget <= 0
     or v_monthly_user_budget is null or v_monthly_user_budget <= 0 then
    raise exception 'ai_budget_misconfigured' using errcode = 'P0001';
  end if;
  -- p_monthly_budget_usd is retained only for Edge signature compatibility (H9).

  perform pg_advisory_xact_lock(hashtext('ai_budget:' || p_org_id::text));

  select public.ai_org_spend_this_month(p_org_id) into v_spend;
  if coalesce(v_spend, 0) + p_estimated_usd > v_monthly_budget then
    raise exception 'monthly_budget_exceeded' using errcode = 'P0001';
  end if;

  -- Per-user monthly cap (AI-04): includes committed spend and live in-flight reservations
  -- under the same advisory lock so concurrent requests by one user cannot race past the cap.
  select public.ai_user_spend_this_month(p_org_id, p_user_id) into v_user_spend;
  if coalesce(v_user_spend, 0) + p_estimated_usd > v_monthly_user_budget then
    raise exception 'monthly_user_budget_exceeded' using errcode = 'P0001';
  end if;

  select (select count(*) from public.ai_budget_reservations r
          where r.user_id = p_user_id
            and r.created_at >= now() - make_interval(mins => p_rate_limit_window_minutes))
       + (select count(*) from public.ai_usage_events e
          where e.user_id = p_user_id and e.reservation_id is null
            and e.created_at >= now() - make_interval(mins => p_rate_limit_window_minutes))
    into v_recent;

  if v_recent >= p_rate_limit_max then
    raise exception 'rate_limited' using errcode = 'P0001';
  end if;

  insert into public.ai_budget_reservations (organization_id, user_id, reserved_usd, status, expires_at)
  values (
    p_org_id,
    p_user_id,
    p_estimated_usd,
    'pending',
    now() + make_interval(secs => p_ttl_seconds)
  )
  returning id into v_reservation_id;

  return v_reservation_id;
end;
$$;

revoke all on function public.reserve_ai_budget(uuid, uuid, numeric, numeric, integer, integer, integer)
  from public, anon, authenticated;
grant execute on function public.reserve_ai_budget(uuid, uuid, numeric, numeric, integer, integer, integer)
  to service_role;

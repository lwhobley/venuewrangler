-- H9 / M6 (code review 2026-11-23): harden AI billing DEFINER RPCs.
--
--   * commit_ai_reservation caps billed cost at the reservation amount so a buggy or
--     malicious service caller cannot reserve a tiny estimate and commit arbitrary spend.
--   * reserve_ai_budget loads the monthly org budget from app_hidden.platform_settings
--     (not the caller-supplied p_monthly_budget_usd) and refuses unentitled orgs via
--     org_is_entitled when billing_enforcement is on.
--   * p_monthly_budget_usd is retained for signature compatibility with existing Edge
--     callers but is ignored; operators set ai_monthly_org_budget_usd instead.

alter table app_hidden.platform_settings
  add column if not exists ai_monthly_org_budget_usd numeric(10, 4) not null default 10
    check (ai_monthly_org_budget_usd > 0);

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
  v_recent integer;
  v_monthly_budget numeric;
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

  select s.ai_monthly_org_budget_usd into v_monthly_budget
  from app_hidden.platform_settings s;
  if v_monthly_budget is null or v_monthly_budget <= 0 then
    raise exception 'ai_budget_misconfigured' using errcode = 'P0001';
  end if;
  -- p_monthly_budget_usd is retained only for Edge signature compatibility (H9).

  perform pg_advisory_xact_lock(hashtext('ai_budget:' || p_org_id::text));

  select public.ai_org_spend_this_month(p_org_id) into v_spend;
  if coalesce(v_spend, 0) + p_estimated_usd > v_monthly_budget then
    raise exception 'monthly_budget_exceeded' using errcode = 'P0001';
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

create or replace function public.commit_ai_reservation(
  p_reservation_id uuid,
  p_organization_id uuid,
  p_venue_id uuid,
  p_user_id uuid,
  p_task text,
  p_model text,
  p_input_tokens integer,
  p_output_tokens integer,
  p_cost_usd numeric
) returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_reservation public.ai_budget_reservations;
  v_cost numeric;
begin
  perform pg_advisory_xact_lock(hashtext('ai_budget:' || p_organization_id::text));
  select * into v_reservation
  from public.ai_budget_reservations
  where id = p_reservation_id
  for update;

  if not found or v_reservation.organization_id <> p_organization_id then
    raise exception 'AI reservation not found' using errcode = 'P0002';
  end if;
  if exists (select 1 from public.ai_usage_events where reservation_id = p_reservation_id) then
    return;
  end if;
  if v_reservation.status <> 'pending' then
    raise exception 'AI reservation is no longer pending' using errcode = '22023';
  end if;
  if v_reservation.expires_at < now() then
    raise exception 'AI reservation expired' using errcode = '22023';
  end if;
  if p_cost_usd is null or p_cost_usd < 0 or p_input_tokens is null or p_input_tokens < 0
     or p_output_tokens is null or p_output_tokens < 0 then
    raise exception 'invalid AI usage values' using errcode = '22023';
  end if;

  -- Cap billed spend at what was reserved (H9). Rejecting would leave a successful provider
  -- call unmetered; capping preserves the reservation ceiling as a DB invariant.
  if p_cost_usd > v_reservation.reserved_usd then
    v_cost := v_reservation.reserved_usd;
  else
    v_cost := p_cost_usd;
  end if;

  update public.ai_budget_reservations set status = 'committed'
  where id = p_reservation_id;
  insert into public.ai_usage_events (
    organization_id, venue_id, user_id, task, model,
    input_tokens, output_tokens, cost_usd, reservation_id
  ) values (
    p_organization_id, p_venue_id, p_user_id, p_task, p_model,
    p_input_tokens, p_output_tokens, v_cost, p_reservation_id
  );
end;
$$;

revoke all on function public.commit_ai_reservation(uuid, uuid, uuid, uuid, text, text, integer, integer, numeric)
  from public, anon, authenticated;
grant execute on function public.commit_ai_reservation(uuid, uuid, uuid, uuid, text, text, integer, integer, numeric)
  to service_role;

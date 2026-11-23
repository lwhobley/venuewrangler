-- Restore apply_stripe_subscription_state without the stripe_customer_id rebind guard
-- (prior behavior from 20261007201000_review_fixes_stripe_inventory_roster).

create or replace function public.apply_stripe_subscription_state(
  p_organization_id uuid,
  p_customer_id text,
  p_subscription_id text,
  p_price_id text,
  p_status text,
  p_current_period_end timestamptz,
  p_cancel_at_period_end boolean,
  p_event_id text,
  p_event_created bigint
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_rows integer;
begin
  if p_organization_id is not null then
    insert into public.subscriptions as s (
      organization_id, stripe_customer_id, stripe_subscription_id, stripe_price_id, status,
      current_period_end, cancel_at_period_end, last_event_id, last_event_created
    )
    values (
      p_organization_id, p_customer_id, p_subscription_id, p_price_id, p_status,
      p_current_period_end, coalesce(p_cancel_at_period_end, false), p_event_id, p_event_created
    )
    on conflict (organization_id) do update set
      stripe_customer_id = excluded.stripe_customer_id,
      stripe_subscription_id = excluded.stripe_subscription_id,
      stripe_price_id = excluded.stripe_price_id,
      status = excluded.status,
      current_period_end = excluded.current_period_end,
      cancel_at_period_end = excluded.cancel_at_period_end,
      last_event_id = excluded.last_event_id,
      last_event_created = excluded.last_event_created,
      updated_at = now()
    where s.last_event_created is null or s.last_event_created <= excluded.last_event_created;
  else
    update public.subscriptions s set
      stripe_subscription_id = p_subscription_id,
      stripe_price_id = p_price_id,
      status = p_status,
      current_period_end = p_current_period_end,
      cancel_at_period_end = coalesce(p_cancel_at_period_end, false),
      last_event_id = p_event_id,
      last_event_created = p_event_created,
      updated_at = now()
    where s.stripe_customer_id = p_customer_id
      and (s.last_event_created is null or s.last_event_created <= p_event_created)
      and (
        s.stripe_subscription_id is null
        or s.stripe_subscription_id = p_subscription_id
        or p_status not in ('canceled', 'incomplete_expired')
      );
  end if;

  get diagnostics v_rows = row_count;
  return v_rows > 0;
end;
$$;

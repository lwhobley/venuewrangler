-- stripe-webhook used to read last_event_created, compare in the function, then write: two
-- deliveries racing could both pass the check and the older one win. This function does the
-- order check and the write in ONE statement, so a stale event can never overwrite newer state.
-- Called only by the webhook (service role) with state it just retrieved from Stripe.
--
--   * p_organization_id set (checkout.session.completed): create-or-update that organization's row.
--   * otherwise: update the row already linked to p_customer_id.
-- Returns whether a row was written (false = stale event, or a customer this app doesn't know).
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
      and (s.last_event_created is null or s.last_event_created <= p_event_created);
  end if;

  get diagnostics v_rows = row_count;
  return v_rows > 0;
end;
$$;

revoke all on function public.apply_stripe_subscription_state(
  uuid, text, text, text, text, timestamptz, boolean, text, bigint
) from public, anon, authenticated;
grant execute on function public.apply_stripe_subscription_state(
  uuid, text, text, text, text, timestamptz, boolean, text, bigint
) to service_role;

// Price-allowlist decisions for stripe-webhook. This Stripe account is shared with unrelated
// projects, so STRIPE_ALLOWED_PRICE_IDS gates which prices can grant entitlement. Kept free of
// I/O so the rules can be unit-tested (stripe-price_test.ts).

/** The parts of a Stripe subscription item these rules read. */
export interface PricedItem {
  price?: { id?: string | null } | null;
  current_period_end?: number | null;
}

/** The parts of a Stripe subscription these rules read. */
export interface PricedSubscription {
  id: string;
  items: { data: PricedItem[] };
}

/** What public.subscriptions currently holds for the customer, if anything. */
export interface StoredSubscription {
  stripe_subscription_id: string | null;
  stripe_price_id: string | null;
}

/**
 * The item that carries this app's plan: the first item on an allowed price. A subscription can
 * hold several items (an add-on added in the Dashboard) in any order, so never assume item 0.
 * With an empty allowlist (non-production) every price is allowed and item 0 is used.
 */
export function planItem(
  subscription: PricedSubscription | null,
  allowedPriceIds: readonly string[],
): PricedItem | null {
  const items = subscription?.items.data ?? [];
  if (allowedPriceIds.length === 0) return items[0] ?? null;
  return items.find((item) => {
    const priceId = item.price?.id;
    return typeof priceId === "string" && allowedPriceIds.includes(priceId);
  }) ?? null;
}

export type SubscriptionEventAction = "apply" | "cancel" | "skip";

/**
 * How to handle a customer.subscription.* event.
 *
 * - deleted: always "cancel". Ending a subscription can only remove entitlement, and
 *   apply_stripe_subscription_state only lets a canceled status touch the row that already
 *   tracks this subscription.
 * - an item is on an allowed price: "apply" the live state.
 * - no allowed item, but the stored row tracks THIS subscription on a price that is still
 *   allowed: the subscription was moved off the plan, so "cancel".
 * - otherwise "skip": another product's subscription on this shared account, or a legacy price
 *   that was dropped from the allowlist while customers are still billed on it. Dropping a price
 *   from the allowlist must stop new grants, not cancel paying customers.
 */
export function subscriptionEventAction(args: {
  eventType: string;
  subscription: PricedSubscription;
  allowedPriceIds: readonly string[];
  stored: StoredSubscription | null;
}): SubscriptionEventAction {
  const { eventType, subscription, allowedPriceIds, stored } = args;
  if (eventType === "customer.subscription.deleted") return "cancel";
  if (planItem(subscription, allowedPriceIds)) return "apply";
  if (
    stored?.stripe_subscription_id === subscription.id &&
    typeof stored.stripe_price_id === "string" &&
    allowedPriceIds.includes(stored.stripe_price_id)
  ) {
    return "cancel";
  }
  return "skip";
}

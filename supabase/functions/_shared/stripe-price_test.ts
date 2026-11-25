import { planItem, type PricedSubscription, subscriptionEventAction } from "./stripe-price.ts";

function assertEquals(actual: unknown, expected: unknown): void {
  if (actual !== expected) {
    throw new Error(`expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
  }
}

const PLAN = "price_plan";
const LEGACY = "price_legacy";
const ALLOWED = [PLAN];

function sub(id: string, ...priceIds: string[]): PricedSubscription {
  return { id, items: { data: priceIds.map((p) => ({ price: { id: p } })) } };
}

Deno.test("planItem finds the allowed item even when it is not item 0", () => {
  const s = sub("sub_1", "price_addon", PLAN);
  assertEquals(planItem(s, ALLOWED)?.price?.id, PLAN);
  assertEquals(planItem(sub("sub_1", "price_addon"), ALLOWED), null);
  // Empty allowlist (non-production): item 0.
  assertEquals(planItem(s, [])?.price?.id, "price_addon");
});

Deno.test("an add-on item ahead of the plan item does not cancel the subscription", () => {
  assertEquals(
    subscriptionEventAction({
      eventType: "customer.subscription.updated",
      subscription: sub("sub_1", "price_addon", PLAN),
      allowedPriceIds: ALLOWED,
      stored: { stripe_subscription_id: "sub_1", stripe_price_id: PLAN },
    }),
    "apply",
  );
});

Deno.test("a subscription moved off the plan price is cancelled", () => {
  assertEquals(
    subscriptionEventAction({
      eventType: "customer.subscription.updated",
      subscription: sub("sub_1", "price_other_product"),
      allowedPriceIds: ALLOWED,
      stored: { stripe_subscription_id: "sub_1", stripe_price_id: PLAN },
    }),
    "cancel",
  );
});

Deno.test("a legacy price dropped from the allowlist is skipped, not cancelled", () => {
  assertEquals(
    subscriptionEventAction({
      eventType: "customer.subscription.updated",
      subscription: sub("sub_1", LEGACY),
      allowedPriceIds: ALLOWED,
      stored: { stripe_subscription_id: "sub_1", stripe_price_id: LEGACY },
    }),
    "skip",
  );
});

Deno.test("another subscription on a non-allowed price never cancels the tracked one", () => {
  assertEquals(
    subscriptionEventAction({
      eventType: "customer.subscription.updated",
      subscription: sub("sub_2", "price_other_product"),
      allowedPriceIds: ALLOWED,
      stored: { stripe_subscription_id: "sub_1", stripe_price_id: PLAN },
    }),
    "skip",
  );
  assertEquals(
    subscriptionEventAction({
      eventType: "customer.subscription.created",
      subscription: sub("sub_2", "price_other_product"),
      allowedPriceIds: ALLOWED,
      stored: null,
    }),
    "skip",
  );
});

Deno.test("a deletion always cancels, whatever the price", () => {
  for (const s of [sub("sub_1", PLAN), sub("sub_1", LEGACY)]) {
    assertEquals(
      subscriptionEventAction({
        eventType: "customer.subscription.deleted",
        subscription: s,
        allowedPriceIds: ALLOWED,
        stored: { stripe_subscription_id: "sub_1", stripe_price_id: LEGACY },
      }),
      "cancel",
    );
  }
});

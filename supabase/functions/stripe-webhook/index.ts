// Receives Stripe webhook events and is the ONLY writer of public.subscriptions. Deployed
// with verify_jwt=false (Stripe calls this directly with no Supabase user JWT) — signature
// verification via STRIPE_WEBHOOK_SECRET is what authenticates the caller instead. Uses
// `constructEventAsync` (not the sync `constructEvent`) because Deno's edge runtime has no
// Node crypto module; the async variant uses Web Crypto (SubtleCrypto) instead.
//
// Stripe is used only for the platform app-subscription here — never Stripe Connect. There is
// no connected-account flow in this app, so a single webhook secret is all this ever verifies
// against.
import { createServiceClient } from "../_shared/supabase-clients.ts";
import { createStripeClient } from "../_shared/stripe.ts";
import type Stripe from "stripe";
import { initObservability, captureException, flushObservability } from "../_shared/observability.ts";

initObservability();

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return new Response(JSON.stringify({ error: "method_not_allowed" }), { status: 405 });
  }

  const signature = req.headers.get("stripe-signature");
  const webhookSecret = Deno.env.get("STRIPE_WEBHOOK_SECRET");
  if (!signature || !webhookSecret) {
    return new Response(JSON.stringify({ error: "missing_signature_or_secret" }), {
      status: 400,
    });
  }

  const rawBody = await req.text();
  const stripe = createStripeClient();

  let event: Stripe.Event;
  try {
    event = await stripe.webhooks.constructEventAsync(rawBody, signature, webhookSecret);
  } catch (err) {
    console.error("Stripe webhook signature verification failed", err);
    return new Response(JSON.stringify({ error: "invalid_signature" }), { status: 400 });
  }

  const serviceClient = createServiceClient();

  // Idempotency: never apply the same Stripe event twice (retries, redelivery).
  const { data: alreadySeen } = await serviceClient
    .from("stripe_processed_events")
    .select("event_id")
    .eq("event_id", event.id)
    .maybeSingle();
  if (alreadySeen) {
    return new Response(JSON.stringify({ received: true, duplicate: true }), { status: 200 });
  }

  // Applies a subscription's state in ONE atomic statement (public.apply_stripe_subscription_state):
  // the "is this newer than what we have" check and the write cannot be split by a racing
  // delivery. Returns whether a row was written.
  async function applyState(
    organizationId: string | null,
    customerId: string,
    subscription: Stripe.Subscription | null,
    statusOverride?: string,
  ): Promise<boolean> {
    // As of this account's API version, current_period_end lives on each subscription ITEM,
    // not the top-level Subscription — a single-price subscription (the only kind this app
    // creates) has exactly one item.
    const firstItem = subscription?.items.data[0];
    const periodEnd = firstItem?.current_period_end;
    const { data, error } = await serviceClient.rpc("apply_stripe_subscription_state", {
      p_organization_id: organizationId,
      p_customer_id: customerId,
      p_subscription_id: subscription?.id ?? null,
      p_price_id: firstItem?.price?.id ?? null,
      p_status: statusOverride ?? subscription?.status ?? "none",
      p_current_period_end: periodEnd ? new Date(periodEnd * 1000).toISOString() : null,
      p_cancel_at_period_end: subscription?.cancel_at_period_end ?? false,
      p_event_id: event.id,
      p_event_created: event.created,
    });
    if (error) throw error;
    return data === true;
  }

  // The event payload is a snapshot from when it fired; a late or replayed delivery would carry
  // old state. Ask Stripe for the subscription as it is now. A deleted subscription may no
  // longer be retrievable, in which case the event's own copy (status canceled) is the answer.
  async function currentSubscription(
    subscriptionId: string,
    fallback: Stripe.Subscription | null,
  ): Promise<Stripe.Subscription> {
    try {
      return await stripe.subscriptions.retrieve(subscriptionId);
    } catch (err) {
      if (fallback && event.type === "customer.subscription.deleted") return fallback;
      throw err;
    }
  }

  try {
    switch (event.type) {
      case "checkout.session.completed": {
        const session = event.data.object as Stripe.Checkout.Session;

        const organizationId = session.metadata?.organization_id;
        const customerId =
          typeof session.customer === "string" ? session.customer : session.customer?.id;
        const subscriptionId =
          typeof session.subscription === "string"
            ? session.subscription
            : session.subscription?.id;

        if (!organizationId) break; // The platform Stripe account is shared with other projects.
        if (!customerId) throw new Error("subscription checkout missing customer");

        // A completed checkout does not mean the subscription is active (the first payment can
        // still be incomplete or require action), so take the real status from Stripe instead
        // of assuming it. No subscription on the session leaves the row at 'none'.
        const subscription = subscriptionId
          ? await currentSubscription(subscriptionId, null)
          : null;
        await applyState(organizationId, customerId, subscription);
        break;
      }

      case "customer.subscription.created":
      case "customer.subscription.updated":
      case "customer.subscription.deleted": {
        const eventSubscription = event.data.object as Stripe.Subscription;
        const customerId =
          typeof eventSubscription.customer === "string"
            ? eventSubscription.customer
            : eventSubscription.customer.id;

        const subscription = await currentSubscription(eventSubscription.id, eventSubscription);
        const applied = await applyState(
          null,
          customerId,
          subscription,
          event.type === "customer.subscription.deleted" ? "canceled" : undefined,
        );
        if (!applied) {
          // Either a customer from another product on this shared Stripe account, or an event
          // older than the state already stored — both are correct to skip.
          console.warn("subscription event not applied", {
            eventType: event.type,
            eventId: event.id,
            customerId,
          });
        }
        break;
      }

      default:
        // Every other event type is intentionally ignored — only the cases above affect
        // subscription state this app cares about.
        break;
    }

    // Record the event only after it applied cleanly so a failed handler retries.
    const { error: recordError } = await serviceClient
      .from("stripe_processed_events")
      .insert({ event_id: event.id, event_type: event.type });
    // 23505 = a concurrent delivery of this same event already recorded it — fine, the
    // handlers above are idempotent. Anything else must surface so Stripe retries.
    if (recordError && recordError.code !== "23505") throw recordError;
  } catch (err) {
    // Stripe retries on a non-2xx response. Never acknowledge a subscription
    // change until it has actually been persisted.
    console.error("stripe-webhook handler error", err);
    captureException(err, { function: "stripe-webhook", url: req.url, event_type: event.type });
    await flushObservability();
    return new Response(JSON.stringify({ error: "webhook_handler_error" }), { status: 500 });
  }

  return new Response(JSON.stringify({ received: true }), { status: 200 });
});

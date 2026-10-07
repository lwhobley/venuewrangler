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
        if (customerId) {
          const { error } = await serviceClient.from("subscriptions").upsert(
            {
              organization_id: organizationId,
              stripe_customer_id: customerId,
              stripe_subscription_id: subscriptionId ?? null,
              // checkout.session.completed fires when the subscription starts —
              // subsequent subscription events refine this. Never leave it as 'none'
              // after a successful checkout.
              status: subscriptionId ? "active" : "none",
              last_event_id: event.id,
              last_event_created: event.created,
            },
            { onConflict: "organization_id" },
          );
          if (error) throw error;
        } else {
          throw new Error("subscription checkout missing customer");
        }
        break;
      }

      case "customer.subscription.created":
      case "customer.subscription.updated":
      case "customer.subscription.deleted": {
        const subscription = event.data.object as Stripe.Subscription;
        const customerId =
          typeof subscription.customer === "string"
            ? subscription.customer
            : subscription.customer.id;
        // As of this account's API version, current_period_end/start live on each
        // subscription ITEM, not the top-level Subscription object (confirmed via
        // GetSubscriptions' query-param docs: "minimum item current_period_end") — a single-
        // price subscription (the only kind this app creates) has exactly one item.
        const firstItem = subscription.items.data[0];
        const priceId = firstItem?.price?.id ?? null;
        const currentPeriodEnd = firstItem?.current_period_end;
        const status =
          event.type === "customer.subscription.deleted" ? "canceled" : subscription.status;

        // Order-safety: fetch the row's last applied event timestamp first; an older
        // event delivered late must never overwrite newer state.
        const { data: current, error: fetchError } = await serviceClient
          .from("subscriptions")
          .select("id, last_event_created")
          .eq("stripe_customer_id", customerId)
          .maybeSingle();
        if (fetchError) throw fetchError;
        if (!current) {
          // Other products also use this Stripe platform account. Their customers
          // have no subscriptions row in Venue Wrangler.
          console.warn("subscription event for unlinked Stripe customer", { eventType: event.type, customerId });
          break;
        }
        if (
          typeof current.last_event_created === "number" &&
          current.last_event_created >= event.created
        ) {
          console.warn("ignoring out-of-order subscription event", {
            eventId: event.id,
            eventCreated: event.created,
            lastApplied: current.last_event_created,
          });
          break;
        }

        const { error } = await serviceClient
          .from("subscriptions")
          .update({
            stripe_subscription_id: subscription.id,
            stripe_price_id: priceId,
            status,
            current_period_end: currentPeriodEnd
              ? new Date(currentPeriodEnd * 1000).toISOString()
              : null,
            cancel_at_period_end: subscription.cancel_at_period_end,
            last_event_id: event.id,
            last_event_created: event.created,
          })
          .eq("id", current.id);

        if (error) throw error;
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

// Receives Stripe webhook events and is the ONLY writer of public.subscriptions. Deployed
// with verify_jwt=false (Stripe calls this directly with no Supabase user JWT) — signature
// verification via STRIPE_WEBHOOK_SECRET is what authenticates the caller instead. Uses
// `constructEventAsync` (not the sync `constructEvent`) because Deno's edge runtime has no
// Node crypto module; the async variant uses Web Crypto (SubtleCrypto) instead.
import { createServiceClient } from "../_shared/supabase-clients.ts";
import { createStripeClient } from "../_shared/stripe.ts";
import type Stripe from "https://esm.sh/stripe@23.0.0?target=deno";
import { initObservability, captureException, flushObservability } from "../_shared/observability.ts";

initObservability();

// The only writer of crm_beos.deposit_status/deposit_payment_intent_id/deposit_paid_at (see
// crm-create-deposit-checkout's header comment).
async function markBeoDepositPaid(
  serviceClient: ReturnType<typeof createServiceClient>,
  session: Stripe.Checkout.Session,
): Promise<void> {
  const beoId = session.metadata?.beo_id;
  if (!beoId) {
    console.error("beo_deposit session missing beo_id in metadata", session.id);
    return;
  }
  const paymentIntentId =
    typeof session.payment_intent === "string" ? session.payment_intent : session.payment_intent?.id;

  const { data, error } = await serviceClient
    .from("crm_beos")
    .update({
      deposit_status: "paid",
      deposit_payment_intent_id: paymentIntentId ?? null,
      deposit_paid_at: new Date().toISOString(),
    })
    .eq("id", beoId)
    // null means "due" everywhere else in this schema (waive_beo_deposit's coalesce, the
    // Flutter client's depositDueAndUnpaid) — matching only 'due' would silently drop real
    // payments on BEOs whose status was never explicitly set. Excluding 'paid'/'waived' keeps
    // Stripe's redeliveries idempotent and never clobbers a manager's later waive.
    .or("deposit_status.is.null,deposit_status.eq.due")
    .select("id");

  if (error) {
    // Thrown, not just logged: Stripe retries on a 500, which is what a transient DB failure
    // on a real payment needs.
    throw error;
  }
  if (!data || data.length === 0) {
    // Already paid (a redelivery — expected) or waived after checkout began (money was taken
    // anyway and needs a manual refund decision).
    console.warn("beo_deposit payment matched no due/unset BEO; already paid or waived", {
      beoId,
      session: session.id,
      paymentIntentId,
    });
  }
}

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

  try {
    switch (event.type) {
      case "checkout.session.completed": {
        const session = event.data.object as Stripe.Checkout.Session;

        // CRM BEO deposit checkout (crm-create-deposit-checkout) is a one-off "payment" mode
        // session, distinguished from a subscription checkout by this metadata tag — it has no
        // organization_id/customer to upsert into subscriptions, it marks a crm_beos row paid
        // instead. This is the only place deposit_status/deposit_payment_intent_id/
        // deposit_paid_at are ever written, matching that function's own comment that it never
        // marks a deposit paid itself.
        if (session.metadata?.checkout_type === "beo_deposit") {
          // Delayed-notification payment methods (e.g. bank debits) complete the session with
          // payment_status "unpaid" — money hasn't moved yet. Those are settled by
          // checkout.session.async_payment_succeeded below instead.
          if (session.payment_status === "paid") {
            await markBeoDepositPaid(serviceClient, session);
          }
          break;
        }

        const organizationId = session.metadata?.organization_id;
        const customerId =
          typeof session.customer === "string" ? session.customer : session.customer?.id;
        const subscriptionId =
          typeof session.subscription === "string"
            ? session.subscription
            : session.subscription?.id;

        if (organizationId && customerId) {
          const { error } = await serviceClient.from("subscriptions").upsert(
            {
              organization_id: organizationId,
              stripe_customer_id: customerId,
              stripe_subscription_id: subscriptionId ?? null,
            },
            { onConflict: "organization_id" },
          );
          if (error) console.error("checkout.session.completed upsert failed", error);
        } else {
          console.error("checkout.session.completed missing organization_id or customer", {
            organizationId,
            customerId,
          });
        }
        break;
      }

      case "checkout.session.async_payment_succeeded": {
        const session = event.data.object as Stripe.Checkout.Session;
        if (session.metadata?.checkout_type === "beo_deposit") {
          await markBeoDepositPaid(serviceClient, session);
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
          })
          .eq("stripe_customer_id", customerId);

        if (error) {
          console.error(`${event.type} update failed`, error);
        }
        break;
      }

      default:
        // Every other event type is intentionally ignored — only the cases above affect
        // subscription or deposit state this app cares about.
        break;
    }
  } catch (err) {
    // Stripe retries on a non-2xx response; log and still return 200 for a processing error
    // that a retry won't fix (e.g. a row genuinely doesn't exist yet), but let an unexpected
    // throw surface as 500 so Stripe DOES retry a transient failure (a dropped DB connection).
    console.error("stripe-webhook handler error", err);
    captureException(err, { function: "stripe-webhook", url: req.url, event_type: event.type });
    await flushObservability();
    return new Response(JSON.stringify({ error: "webhook_handler_error" }), { status: 500 });
  }

  return new Response(JSON.stringify({ received: true }), { status: 200 });
});

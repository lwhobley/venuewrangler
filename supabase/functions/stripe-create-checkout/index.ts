// Creates a Stripe Checkout Session (hosted) for an organization's subscription. The app
// never embeds a payment form or sees Stripe secret material — it opens the returned `url`
// in an external browser (see apps/mobile/lib/features/billing). Caller must be an
// organization_owner/organization_admin of the target organization; membership is checked via
// the caller's own RLS-respecting client, same "derive, don't trust" discipline as
// ai-assistant.
import { corsHeaders, handleCorsPreflight } from "../_shared/cors.ts";
import { createServiceClient, createUserClient } from "../_shared/supabase-clients.ts";
import { createStripeClient } from "../_shared/stripe.ts";
import { initObservability, captureException, flushObservability } from "../_shared/observability.ts";

initObservability();

function jsonResponse(body: Record<string, unknown>, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

Deno.serve(async (req) => {
  const preflight = handleCorsPreflight(req);
  if (preflight) return preflight;

  try {
    return await handleRequest(req);
  } catch (error) {
    console.error("stripe-create-checkout: unexpected error", error);
    captureException(error, { function: "stripe-create-checkout", url: req.url });
    await flushObservability();
    return jsonResponse({ error: "internal_error" }, 500);
  }
});

async function handleRequest(req: Request): Promise<Response> {
  if (req.method !== "POST") {
    return jsonResponse({ error: "method_not_allowed" }, 405);
  }

  const authHeader = req.headers.get("Authorization");
  if (!authHeader) {
    return jsonResponse({ error: "missing_authorization_header" }, 401);
  }

  let payload: { organization_id?: string };
  try {
    payload = await req.json();
  } catch {
    return jsonResponse({ error: "invalid_json_body" }, 400);
  }

  const organizationId = payload.organization_id;
  if (!organizationId || typeof organizationId !== "string") {
    return jsonResponse({ error: "missing_organization_id" }, 400);
  }

  const userClient = createUserClient(authHeader);
  const { data: userData, error: userError } = await userClient.auth.getUser();
  if (userError || !userData?.user) {
    return jsonResponse({ error: "invalid_or_expired_session" }, 401);
  }

  // Org-level membership (venue_id is null) with an admin-tier role — RLS
  // (memberships_select_self) returns this row only for the caller's own memberships, so a
  // non-empty result IS the authorization check, same pattern as ai-assistant's venue lookup.
  const { data: membership, error: membershipError } = await userClient
    .from("memberships")
    .select("role")
    .eq("organization_id", organizationId)
    .is("venue_id", null)
    .in("role", ["organization_owner", "organization_admin"])
    .maybeSingle();

  if (membershipError) {
    console.error("membership lookup failed", membershipError);
    return jsonResponse({ error: "membership_lookup_failed" }, 500);
  }
  if (!membership) {
    return jsonResponse({ error: "not_an_organization_admin" }, 403);
  }

  const priceId = Deno.env.get("STRIPE_PRICE_ID");
  const successUrl = Deno.env.get("STRIPE_CHECKOUT_SUCCESS_URL");
  const cancelUrl = Deno.env.get("STRIPE_CHECKOUT_CANCEL_URL");
  if (!priceId || !successUrl || !cancelUrl) {
    console.error("Stripe checkout is not fully configured");
    return jsonResponse({ error: "billing_not_configured" }, 500);
  }

  const serviceClient = createServiceClient();
  const stripe = createStripeClient();

  // Reuse an existing Stripe customer for this organization if one was already created by an
  // earlier checkout attempt; otherwise create one now and persist it immediately, so a
  // retried request (or a later portal-session request) finds the same customer rather than
  // creating a duplicate.
  const { data: existing, error: existingError } = await serviceClient
    .from("subscriptions")
    .select("stripe_customer_id")
    .eq("organization_id", organizationId)
    .maybeSingle();

  if (existingError) {
    console.error("subscription lookup failed", existingError);
    return jsonResponse({ error: "subscription_lookup_failed" }, 500);
  }

  let stripeCustomerId = existing?.stripe_customer_id as string | undefined;

  if (!stripeCustomerId) {
    const customer = await stripe.customers.create(
      {
        metadata: { organization_id: organizationId },
      },
      { idempotencyKey: `org-customer:${organizationId}` },
    );
    stripeCustomerId = customer.id;

    const { error: upsertError } = await serviceClient
      .from("subscriptions")
      .upsert(
        { organization_id: organizationId, stripe_customer_id: stripeCustomerId },
        { onConflict: "organization_id" },
      );
    if (upsertError) {
      console.error("failed to persist new Stripe customer", upsertError);
      return jsonResponse({ error: "subscription_upsert_failed" }, 500);
    }
  }

  const session = await stripe.checkout.sessions.create({
    mode: "subscription",
    customer: stripeCustomerId,
    line_items: [{ price: priceId, quantity: 1 }],
    success_url: successUrl,
    cancel_url: cancelUrl,
    metadata: { organization_id: organizationId },
  });

  return jsonResponse({ url: session.url });
}

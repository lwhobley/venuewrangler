// Creates a Stripe Billing Portal Session (hosted) so an org admin can manage/cancel their
// subscription or update a payment method, without the app ever touching card data. Same
// membership-check discipline as stripe-create-checkout.
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
    console.error("stripe-create-portal: unexpected error", error);
    captureException(error, { function: "stripe-create-portal", url: req.url });
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

  const serviceClient = createServiceClient();

  const { data: subscription, error: subscriptionError } = await serviceClient
    .from("subscriptions")
    .select("stripe_customer_id")
    .eq("organization_id", organizationId)
    .maybeSingle();

  if (subscriptionError) {
    console.error("subscription lookup failed", subscriptionError);
    return jsonResponse({ error: "subscription_lookup_failed" }, 500);
  }
  if (!subscription?.stripe_customer_id) {
    return jsonResponse({ error: "no_stripe_customer" }, 404);
  }

  const returnUrl = Deno.env.get("STRIPE_PORTAL_RETURN_URL");
  if (!returnUrl) {
    console.error("STRIPE_PORTAL_RETURN_URL is not configured");
    return jsonResponse({ error: "billing_not_configured" }, 500);
  }

  const stripe = createStripeClient();
  const session = await stripe.billingPortal.sessions.create({
    customer: subscription.stripe_customer_id,
    return_url: returnUrl,
  });

  return jsonResponse({ url: session.url });
}

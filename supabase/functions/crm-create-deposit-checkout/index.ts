// Creates a one-off Stripe Checkout Session (hosted, mode: "payment") for a BEO's deposit.
// Mirrors stripe-create-checkout's pattern (hosted URL only, no payment form embedded, no
// secret material reaches the client) but for a single payment instead of a subscription.
// stripe-webhook's checkout.session.completed handler is the only writer of the resulting
// deposit_status/deposit_payment_intent_id/deposit_paid_at columns — this function only ever
// records the pending checkout session id, never marks a deposit paid itself, since Stripe's
// webhook is the authoritative confirmation that money actually moved.
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
    console.error("crm-create-deposit-checkout: unexpected error", error);
    captureException(error, { function: "crm-create-deposit-checkout", url: req.url });
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

  let payload: { beo_id?: string };
  try {
    payload = await req.json();
  } catch {
    return jsonResponse({ error: "invalid_json_body" }, 400);
  }

  const beoId = payload.beo_id;
  if (!beoId || typeof beoId !== "string") {
    return jsonResponse({ error: "missing_beo_id" }, 400);
  }

  const userClient = createUserClient(authHeader);
  const { data: userData, error: userError } = await userClient.auth.getUser();
  if (userError || !userData?.user) {
    return jsonResponse({ error: "invalid_or_expired_session" }, 401);
  }

  // RLS-respecting read: crm_beos' select policy already scopes this to venues the caller
  // belongs to, so a row coming back at all is part of the authorization check, same pattern
  // as stripe-create-checkout's membership lookup. The manager-role gate below is still needed
  // separately since crm_beos is readable by any venue member, not just managers.
  const { data: beo, error: beoError } = await userClient
    .from("crm_beos")
    .select("id, event_name, deposit_cents, deposit_status, deposit_checkout_session_id, organization_id, venue_id")
    .eq("id", beoId)
    .maybeSingle();

  if (beoError) {
    console.error("beo lookup failed", beoError);
    return jsonResponse({ error: "beo_lookup_failed" }, 500);
  }
  if (!beo) {
    return jsonResponse({ error: "beo_not_found" }, 404);
  }

  const { data: membership, error: membershipError } = await userClient
    .from("memberships")
    .select("role")
    .eq("venue_id", beo.venue_id)
    .in("role", ["venue_manager", "organization_owner", "organization_admin"])
    .maybeSingle();

  if (membershipError) {
    console.error("membership lookup failed", membershipError);
    return jsonResponse({ error: "membership_lookup_failed" }, 500);
  }
  if (!membership) {
    return jsonResponse({ error: "forbidden" }, 403);
  }

  if (!beo.deposit_cents || beo.deposit_cents <= 0) {
    return jsonResponse({ error: "no_deposit_due" }, 400);
  }
  if (beo.deposit_status === "paid") {
    return jsonResponse({ error: "deposit_already_paid" }, 400);
  }
  if (beo.deposit_status === "waived") {
    return jsonResponse({ error: "deposit_waived" }, 400);
  }

  const stripe = createStripeClient();

  // Reuse a still-open session instead of minting a new one per tap: two live checkout links
  // for the same deposit means a customer can pay twice, and the second payment would match
  // no due BEO in stripe-webhook and be silently kept.
  if (beo.deposit_checkout_session_id) {
    try {
      const existing = await stripe.checkout.sessions.retrieve(beo.deposit_checkout_session_id);
      if (existing.status === "open" && existing.url && existing.amount_total === beo.deposit_cents) {
        return jsonResponse({ url: existing.url });
      }
    } catch (err) {
      console.warn("could not retrieve previous deposit checkout session; creating a new one", err);
    }
  }

  const successUrl = Deno.env.get("STRIPE_CRM_DEPOSIT_SUCCESS_URL") ?? Deno.env.get("STRIPE_CHECKOUT_SUCCESS_URL");
  const cancelUrl = Deno.env.get("STRIPE_CRM_DEPOSIT_CANCEL_URL") ?? Deno.env.get("STRIPE_CHECKOUT_CANCEL_URL");
  if (!successUrl || !cancelUrl) {
    console.error("Stripe deposit checkout is not fully configured");
    return jsonResponse({ error: "billing_not_configured" }, 500);
  }

  const session = await stripe.checkout.sessions.create({
    mode: "payment",
    line_items: [
      {
        price_data: {
          currency: "usd",
          unit_amount: beo.deposit_cents,
          product_data: { name: `Event deposit — ${beo.event_name}` },
        },
        quantity: 1,
      },
    ],
    success_url: successUrl,
    cancel_url: cancelUrl,
    metadata: { checkout_type: "beo_deposit", beo_id: beo.id },
  });

  const serviceClient = createServiceClient();
  const { error: updateError } = await serviceClient
    .from("crm_beos")
    .update({ deposit_checkout_session_id: session.id })
    .eq("id", beo.id);
  if (updateError) {
    console.error("failed to persist deposit checkout session id", updateError);
  }

  return jsonResponse({ url: session.url });
}

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
import { getMerchantAccount } from "../_shared/stripe-connect.ts";
import { initObservability, captureException, flushObservability } from "../_shared/observability.ts";

initObservability();

function jsonResponse(body: Record<string, unknown>, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

async function checkoutIdempotencyKey(parts: string[]): Promise<string> {
  const bytes = new TextEncoder().encode(parts.join(":"));
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return "beo-deposit-" + Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("");
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

  const beoId = payload?.beo_id;
  if (!beoId || typeof beoId !== "string" || !/^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(beoId)) {
    return jsonResponse({ error: "missing_beo_id" }, 400);
  }

  const userClient = createUserClient(authHeader);
  const { data: userData, error: userError } = await userClient.auth.getUser();
  if (userError || !userData?.user) {
    return jsonResponse({ error: "invalid_or_expired_session" }, 401);
  }

  // crm_beos' select policy is manager-only, but retain an explicit role check
  // here so the privileged writes below never depend on a client-side gate.
  const { data: beo, error: beoError } = await userClient
    .from("crm_beos")
    .select("id, event_name, deposit_cents, deposit_status, deposit_checkout_session_id, deposit_checkout_account_id, deposit_checkout_nonce, organization_id, venue_id")
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
    .eq("user_id", userData.user.id)
    .or(`venue_id.eq.${beo.venue_id},and(venue_id.is.null,organization_id.eq.${beo.organization_id})`)
    .in("role", ["venue_manager", "organization_owner", "organization_admin"])
    .limit(1);

  if (membershipError) {
    console.error("membership lookup failed", membershipError);
    return jsonResponse({ error: "membership_lookup_failed" }, 500);
  }
  if (!membership || membership.length === 0) {
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

  const serviceClient = createServiceClient();
  const { data: account, error: accountError } = await serviceClient
    .from("organization_stripe_accounts")
    .select("stripe_account_id")
    .eq("organization_id", beo.organization_id)
    .maybeSingle();
  if (accountError) throw accountError;
  if (!account) return jsonResponse({ error: "connect_account_required" }, 409);
  const accountId = account.stripe_account_id;
  const accountStatus = await getMerchantAccount(accountId);
  if (!accountStatus.ready || !accountStatus.payoutsReady) {
    return jsonResponse({ error: "connect_account_not_ready" }, 409);
  }
  if (!Deno.env.get("STRIPE_CONNECT_WEBHOOK_SECRET")) {
    return jsonResponse({ error: "connect_not_configured" }, 503);
  }

  const stripe = createStripeClient();

  // Reuse the still-open direct-charge session. Earlier releases created
  // platform-charge sessions; expire one before issuing a connected-account
  // link so both payment destinations cannot remain payable.
  if (beo.deposit_checkout_session_id) {
    const previousAccount = beo.deposit_checkout_account_id as string | null;
    const options = previousAccount ? { stripeAccount: previousAccount } : undefined;
    const existing = await stripe.checkout.sessions.retrieve(beo.deposit_checkout_session_id, {}, options);
    if (existing.status === "complete") {
      return jsonResponse({ error: "deposit_payment_processing" }, 409);
    }
    if (existing.status === "open" && previousAccount === accountId &&
        existing.url && existing.amount_total === beo.deposit_cents) {
      return jsonResponse({ url: existing.url });
    }
    if (existing.status === "open") {
      await stripe.checkout.sessions.expire(existing.id, {}, options);
    }
  }

  const successUrl = Deno.env.get("STRIPE_CRM_DEPOSIT_SUCCESS_URL") ?? Deno.env.get("STRIPE_CHECKOUT_SUCCESS_URL");
  const cancelUrl = Deno.env.get("STRIPE_CRM_DEPOSIT_CANCEL_URL") ?? Deno.env.get("STRIPE_CHECKOUT_CANCEL_URL");
  if (!successUrl || !cancelUrl) {
    console.error("Stripe deposit checkout is not fully configured");
    return jsonResponse({ error: "billing_not_configured" }, 500);
  }

  // A repeated request (including two concurrent taps) gets the same Stripe
  // session for the BEO, amount, account and previous session generation.
  const idempotencyKey = await checkoutIdempotencyKey([
    beo.id, String(beo.deposit_cents), accountId, beo.deposit_checkout_nonce,
    beo.deposit_checkout_session_id ?? "first",
  ]);
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
    metadata: {
      checkout_type: "beo_deposit",
      beo_id: beo.id,
      organization_id: beo.organization_id,
    },
  }, { stripeAccount: accountId, idempotencyKey });

  let updateQuery = serviceClient
    .from("crm_beos")
    .update({ deposit_checkout_session_id: session.id, deposit_checkout_account_id: accountId })
    .eq("id", beo.id)
    .eq("organization_id", beo.organization_id)
    .eq("deposit_cents", beo.deposit_cents)
    .or("deposit_status.is.null,deposit_status.eq.due");
  updateQuery = beo.deposit_checkout_session_id
    ? updateQuery.eq("deposit_checkout_session_id", beo.deposit_checkout_session_id)
    : updateQuery.is("deposit_checkout_session_id", null);
  const { data: updated, error: updateError } = await updateQuery.select("id");
  if (updateError) throw updateError;
  if (!updated || updated.length === 0) {
    await stripe.checkout.sessions.expire(session.id, {}, { stripeAccount: accountId });
    return jsonResponse({ error: "deposit_changed_during_checkout" }, 409);
  }

  return jsonResponse({ url: session.url });
}

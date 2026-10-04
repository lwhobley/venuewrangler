import { corsHeaders, handleCorsPreflight } from "../_shared/cors.ts";
import {
  createServiceClient,
  createUserClient,
} from "../_shared/supabase-clients.ts";
import {
  createMerchantAccount,
  createMerchantOnboardingLink,
  getMerchantAccount,
  merchantOnboardingRedirectsConfigured,
} from "../_shared/stripe-connect.ts";
import {
  captureException,
  flushObservability,
  initObservability,
} from "../_shared/observability.ts";

initObservability();

function respond(body: Record<string, unknown>, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

Deno.serve(async (req) => {
  const preflight = handleCorsPreflight(req);
  if (preflight) return preflight;
  if (req.method !== "POST") {
    return respond({ error: "method_not_allowed" }, 405);
  }

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
      return respond({ error: "missing_authorization_header" }, 401);
    }
    const userClient = createUserClient(authHeader);
    const { data: userData, error: userError } = await userClient.auth
      .getUser();
    if (userError || !userData.user) {
      return respond({ error: "invalid_or_expired_session" }, 401);
    }

    let input: { organization_id?: string; action?: string; country?: string };
    try {
      input = await req.json();
    } catch {
      return respond({ error: "invalid_json_body" }, 400);
    }
    if (!input || typeof input !== "object") {
      return respond({ error: "invalid_json_body" }, 400);
    }
    if (
      typeof input.organization_id !== "string" ||
      !/^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(
        input.organization_id,
      )
    ) {
      return respond({ error: "invalid_organization_id" }, 400);
    }
    if (input.action !== "status" && input.action !== "onboard") {
      return respond({ error: "invalid_action" }, 400);
    }

    const { data: membership, error: membershipError } = await userClient
      .from("memberships")
      .select("id")
      .eq("user_id", userData.user.id)
      .eq("organization_id", input.organization_id)
      .is("venue_id", null)
      .in("role", ["organization_owner", "organization_admin"])
      .maybeSingle();
    if (membershipError) throw membershipError;
    if (!membership) {
      return respond({ error: "not_an_organization_admin" }, 403);
    }

    const serviceClient = createServiceClient();
    const { data: existing, error: existingError } = await serviceClient
      .from("organization_stripe_accounts")
      .select("stripe_account_id")
      .eq("organization_id", input.organization_id)
      .maybeSingle();
    if (existingError) throw existingError;

    if (input.action === "status") {
      if (!existing) {
        return respond({
          connected: false,
          ready: false,
          payouts_ready: false,
        });
      }
      const status = await getMerchantAccount(existing.stripe_account_id);
      return respond({
        connected: true,
        ready: status.ready,
        payouts_ready: status.payoutsReady,
      });
    }

    if (!merchantOnboardingRedirectsConfigured()) {
      return respond({ error: "connect_not_configured" }, 503);
    }
    let accountId = existing?.stripe_account_id as string | undefined;
    if (!accountId) {
      const country = typeof input.country === "string"
        ? input.country.trim().toUpperCase()
        : undefined;
      if (!country || !/^[A-Z]{2}$/.test(country)) {
        return respond({ error: "invalid_country" }, 400);
      }
      const { data: organization, error: orgError } = await serviceClient
        .from("organizations")
        .select("name")
        .eq("id", input.organization_id)
        .single();
      if (orgError) throw orgError;
      if (!userData.user.email) {
        return respond({ error: "email_required" }, 400);
      }
      accountId = await createMerchantAccount({
        organizationId: input.organization_id,
        name: organization.name,
        email: userData.user.email,
        country,
      });
      const { error: insertError } = await serviceClient
        .from("organization_stripe_accounts")
        .insert({
          organization_id: input.organization_id,
          stripe_account_id: accountId,
        });
      if (insertError) {
        // A simultaneous onboarding request may already have recorded the same
        // Stripe idempotent account. Never replace an existing organization link.
        const { data: current, error: currentError } = await serviceClient
          .from("organization_stripe_accounts")
          .select("stripe_account_id")
          .eq("organization_id", input.organization_id)
          .maybeSingle();
        if (currentError || !current) throw insertError;
        accountId = current.stripe_account_id;
      }
    }

    if (!accountId) {
      throw new Error("stripe_connect_account_missing_after_creation");
    }
    const url = await createMerchantOnboardingLink(accountId);
    return respond({ url });
  } catch (error) {
    console.error("stripe-connect-account failed", error);
    captureException(error, {
      function: "stripe-connect-account",
      url: req.url,
    });
    await flushObservability();
    return respond({ error: "connect_unavailable" }, 503);
  }
});

// Gusto OAuth2 connect/callback/disconnect for payroll push. Same shape as square-oauth and
// quickbooks-oauth.
//
// NOT independently verified against a live Gusto sandbox app (none was available in this
// environment). Endpoint shapes follow Gusto's published OAuth2 docs; confirm against
// https://docs.gusto.com/authentication-authorization/docs/oauth2-overview before relying on
// this in production. GUSTO_API_BASE defaults to the demo/sandbox host, not production,
// mirroring the same safety-first default as SQUARE_API_BASE in supabase/.env.example.
import { corsHeaders, handleCorsPreflight } from "../_shared/cors.ts";
import { createServiceClient, createUserClient } from "../_shared/supabase-clients.ts";
import { encryptToken, signOAuthState, verifyOAuthState } from "../_shared/crypto.ts";
import { initObservability, captureException, flushObservability } from "../_shared/observability.ts";

initObservability();

function jsonResponse(body: Record<string, unknown>, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function redirectResponse(url: string): Response {
  return new Response(null, { status: 302, headers: { ...corsHeaders, Location: url } });
}

async function requireVenueManager(
  authHeader: string | null,
  venueId: string,
): Promise<{ userId: string } | { error: Response }> {
  if (!authHeader) {
    return { error: jsonResponse({ error: "missing_authorization_header" }, 401) };
  }
  const userClient = createUserClient(authHeader);
  const { data: userData, error: userError } = await userClient.auth.getUser();
  if (userError || !userData?.user) {
    return { error: jsonResponse({ error: "invalid_or_expired_session" }, 401) };
  }
  const { data: membership, error: membershipError } = await userClient
    .from("memberships")
    .select("role")
    .eq("venue_id", venueId)
    .in("role", ["venue_manager", "organization_owner", "organization_admin"])
    .maybeSingle();
  if (membershipError) {
    return { error: jsonResponse({ error: "membership_lookup_failed" }, 500) };
  }
  if (!membership) {
    return { error: jsonResponse({ error: "not_a_venue_manager" }, 403) };
  }
  return { userId: userData.user.id };
}

Deno.serve(async (req) => {
  const preflight = handleCorsPreflight(req);
  if (preflight) return preflight;

  try {
    return await handleRequest(req);
  } catch (error) {
    console.error("gusto-oauth: unexpected error", error);
    captureException(error, { function: "gusto-oauth", url: req.url });
    await flushObservability();
    return jsonResponse({ error: "internal_error" }, 500);
  }
});

async function handleRequest(req: Request): Promise<Response> {
  const url = new URL(req.url);
  const encryptionKey = Deno.env.get("PAYROLL_TOKEN_ENCRYPTION_KEY")!;
  const apiBase = Deno.env.get("GUSTO_API_BASE") ?? "https://api.gusto-demo.com";
  const clientId = Deno.env.get("GUSTO_CLIENT_ID")!;
  const clientSecret = Deno.env.get("GUSTO_CLIENT_SECRET")!;
  const redirectUri = Deno.env.get("GUSTO_REDIRECT_URI")!;

  if (url.pathname.endsWith("/connect") && req.method === "POST") {
    let payload: { venue_id?: string };
    try {
      payload = await req.json();
    } catch {
      return jsonResponse({ error: "invalid_json_body" }, 400);
    }
    if (!payload.venue_id) return jsonResponse({ error: "missing_venue_id" }, 400);

    const auth = await requireVenueManager(req.headers.get("Authorization"), payload.venue_id);
    if ("error" in auth) return auth.error;

    const state = await signOAuthState(
      { venue_id: payload.venue_id, user_id: auth.userId },
      encryptionKey,
    );
    const authorizeUrl = new URL(`${apiBase}/oauth/authorize`);
    authorizeUrl.searchParams.set("client_id", clientId);
    authorizeUrl.searchParams.set("redirect_uri", redirectUri);
    authorizeUrl.searchParams.set("response_type", "code");
    authorizeUrl.searchParams.set("state", state);

    return jsonResponse({ url: authorizeUrl.toString() });
  }

  if (url.pathname.endsWith("/callback") && req.method === "GET") {
    const code = url.searchParams.get("code");
    const state = url.searchParams.get("state");
    const errorUrl = Deno.env.get("PAYROLL_OAUTH_ERROR_URL") ?? "venuewrangler://integrations/error";
    const successUrl =
      Deno.env.get("PAYROLL_OAUTH_SUCCESS_URL") ?? "venuewrangler://integrations/connected";

    if (!code || !state) return redirectResponse(`${errorUrl}?provider=gusto&reason=missing_code_or_state`);

    const statePayload = await verifyOAuthState(state, encryptionKey);
    if (!statePayload) return redirectResponse(`${errorUrl}?provider=gusto&reason=invalid_state`);

    const tokenResponse = await fetch(`${apiBase}/oauth/token`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        client_id: clientId,
        client_secret: clientSecret,
        code,
        redirect_uri: redirectUri,
        grant_type: "authorization_code",
      }),
    });

    if (!tokenResponse.ok) {
      console.error("Gusto token exchange failed", await tokenResponse.text());
      return redirectResponse(`${errorUrl}?provider=gusto&reason=token_exchange_failed`);
    }

    const tokenData = await tokenResponse.json();
    const serviceClient = createServiceClient();
    const { error } = await serviceClient.from("payroll_connections").upsert(
      {
        venue_id: statePayload.venue_id,
        provider: "gusto",
        status: "connected",
        // Gusto doesn't return a company/account id on the OAuth callback itself (unlike
        // Square's merchant_id or QuickBooks' realmId) — a follow-up call to Gusto's own API
        // would be needed to populate this; left null until that's built.
        external_account_id: null,
        encrypted_access_token: await encryptToken(tokenData.access_token, encryptionKey),
        encrypted_refresh_token: tokenData.refresh_token
          ? await encryptToken(tokenData.refresh_token, encryptionKey)
          : null,
        token_expires_at: tokenData.expires_in
          ? new Date(Date.now() + tokenData.expires_in * 1000).toISOString()
          : null,
        connected_by: statePayload.user_id,
        last_error: null,
      },
      { onConflict: "venue_id,provider" },
    );

    if (error) {
      console.error("failed to persist Gusto connection", error);
      return redirectResponse(`${errorUrl}?provider=gusto&reason=storage_failed`);
    }

    return redirectResponse(`${successUrl}?provider=gusto`);
  }

  if (url.pathname.endsWith("/disconnect") && req.method === "POST") {
    let payload: { venue_id?: string };
    try {
      payload = await req.json();
    } catch {
      return jsonResponse({ error: "invalid_json_body" }, 400);
    }
    if (!payload.venue_id) return jsonResponse({ error: "missing_venue_id" }, 400);

    const auth = await requireVenueManager(req.headers.get("Authorization"), payload.venue_id);
    if ("error" in auth) return auth.error;

    const serviceClient = createServiceClient();
    const { error } = await serviceClient
      .from("payroll_connections")
      .update({
        status: "disconnected",
        encrypted_access_token: null,
        encrypted_refresh_token: null,
        token_expires_at: null,
      })
      .eq("venue_id", payload.venue_id)
      .eq("provider", "gusto");

    if (error) {
      console.error("failed to disconnect Gusto", error);
      return jsonResponse({ error: "disconnect_failed" }, 500);
    }
    return jsonResponse({ disconnected: true });
  }

  return jsonResponse({ error: "not_found" }, 404);
}

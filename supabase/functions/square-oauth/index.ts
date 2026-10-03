// Square OAuth2 connect/callback/disconnect for payroll push (POS/labor data), per the
// migration plan's "Square/QuickBooks/Gusto payroll push, all OAuth exchange server-side"
// requirement — the Flutter app only ever sees a hosted `authorize_url` to open in a browser,
// never a client secret.
//
// NOT independently verified against a live Square sandbox: the authorize/token endpoint
// shapes below follow Square's published OAuth2 docs, but no real SQUARE_APPLICATION_ID/
// SECRET was available in this environment to exercise an actual code exchange. Confirm
// against https://developer.squareup.com/docs/oauth-api/overview before relying on this in
// production, and adjust SQUARE_OAUTH_SCOPES to exactly what the payroll-push feature needs.
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
    console.error("square-oauth: unexpected error", error);
    captureException(error, { function: "square-oauth", url: req.url });
    await flushObservability();
    return jsonResponse({ error: "internal_error" }, 500);
  }
});

async function handleRequest(req: Request): Promise<Response> {
  const url = new URL(req.url);
  const encryptionKey = Deno.env.get("PAYROLL_TOKEN_ENCRYPTION_KEY")!;
  const apiBase = Deno.env.get("SQUARE_API_BASE") ?? "https://connect.squareupsandbox.com";
  const clientId = Deno.env.get("SQUARE_APPLICATION_ID")!;
  const clientSecret = Deno.env.get("SQUARE_APPLICATION_SECRET")!;
  const redirectUri = Deno.env.get("SQUARE_REDIRECT_URI")!;
  const scopes = Deno.env.get("SQUARE_OAUTH_SCOPES") ??
    "MERCHANT_PROFILE_READ LABOR_READ LABOR_WRITE TIMECARDS_READ TIMECARDS_WRITE";

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
    const authorizeUrl = new URL(`${apiBase}/oauth2/authorize`);
    authorizeUrl.searchParams.set("client_id", clientId);
    authorizeUrl.searchParams.set("redirect_uri", redirectUri);
    authorizeUrl.searchParams.set("scope", scopes);
    authorizeUrl.searchParams.set("session", "false");
    authorizeUrl.searchParams.set("state", state);

    return jsonResponse({ url: authorizeUrl.toString() });
  }

  if (url.pathname.endsWith("/callback") && req.method === "GET") {
    const code = url.searchParams.get("code");
    const state = url.searchParams.get("state");
    const errorUrl = Deno.env.get("PAYROLL_OAUTH_ERROR_URL") ?? "venuewrangler://integrations/error";
    const successUrl =
      Deno.env.get("PAYROLL_OAUTH_SUCCESS_URL") ?? "venuewrangler://integrations/connected";

    if (!code || !state) return redirectResponse(`${errorUrl}?provider=square&reason=missing_code_or_state`);

    const statePayload = await verifyOAuthState(state, encryptionKey);
    if (!statePayload) return redirectResponse(`${errorUrl}?provider=square&reason=invalid_state`);

    const tokenResponse = await fetch(`${apiBase}/oauth2/token`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        client_id: clientId,
        client_secret: clientSecret,
        code,
        grant_type: "authorization_code",
        redirect_uri: redirectUri,
      }),
    });

    if (!tokenResponse.ok) {
      console.error("Square token exchange failed", await tokenResponse.text());
      return redirectResponse(`${errorUrl}?provider=square&reason=token_exchange_failed`);
    }

    const tokenData = await tokenResponse.json();
    const serviceClient = createServiceClient();
    const { error } = await serviceClient.from("payroll_connections").upsert(
      {
        venue_id: statePayload.venue_id,
        provider: "square",
        status: "connected",
        external_account_id: tokenData.merchant_id ?? null,
        encrypted_access_token: await encryptToken(tokenData.access_token, encryptionKey),
        encrypted_refresh_token: tokenData.refresh_token
          ? await encryptToken(tokenData.refresh_token, encryptionKey)
          : null,
        token_expires_at: tokenData.expires_at ?? null,
        connected_by: statePayload.user_id,
        last_error: null,
      },
      { onConflict: "venue_id,provider" },
    );

    if (error) {
      console.error("failed to persist Square connection", error);
      return redirectResponse(`${errorUrl}?provider=square&reason=storage_failed`);
    }

    return redirectResponse(`${successUrl}?provider=square`);
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
      .eq("provider", "square");

    if (error) {
      console.error("failed to disconnect Square", error);
      return jsonResponse({ error: "disconnect_failed" }, 500);
    }
    return jsonResponse({ disconnected: true });
  }

  return jsonResponse({ error: "not_found" }, 404);
}

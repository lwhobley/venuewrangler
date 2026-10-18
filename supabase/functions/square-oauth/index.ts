// Square OAuth2 connect/callback/complete/disconnect for payroll push (POS/labor data), per the
// migration plan's "Square/QuickBooks/Gusto payroll push, all OAuth exchange server-side"
// requirement — the Flutter app only ever sees a hosted `authorize_url` to open in a browser,
// never a client secret.
//
// Connect flow (audit B-04): /connect mints a signed single-use state; /callback exchanges the
// code but does NOT activate anything — it parks the encrypted tokens in
// oauth_pending_connections and redirects the app deep link with a one-time completion nonce;
// POST /complete (authenticated, nonce + same user) is what finally writes payroll_connections.
// See _shared/oauth-connections.ts for why this defeats a forwarded consent link.
//
// NOT independently verified against a live Square sandbox: the authorize/token endpoint
// shapes below follow Square's published OAuth2 docs, but no real SQUARE_APPLICATION_ID/
// SECRET was available in this environment to exercise an actual code exchange. Confirm
// against https://developer.squareup.com/docs/oauth-api/overview before relying on this in
// production, and adjust SQUARE_OAUTH_SCOPES to exactly what the payroll-push feature needs.
import { corsHeaders, handleCorsPreflight } from "../_shared/cors.ts";
import { createServiceClient, createUserClient } from "../_shared/supabase-clients.ts";
import { getCallerVenueRoles, isCurrentVenueManager, isManager, isUuid } from "../_shared/venue-auth.ts";
import { decryptToken, signOAuthState, verifyOAuthState } from "../_shared/crypto.ts";
import {
  handleCompleteRequest,
  OAUTH_FETCH_TIMEOUT_MS,
  oauthJson as jsonResponse,
  storePendingConnection,
  withQuery,
} from "../_shared/oauth-connections.ts";
import { initObservability, captureException, flushObservability } from "../_shared/observability.ts";

initObservability();

// Read-only by default until payroll push ships. Writing labor/timecards needs
// LABOR_WRITE/TIMECARDS_WRITE; add them via SQUARE_OAUTH_SCOPES only when push is released.
const DEFAULT_SCOPES = "MERCHANT_PROFILE_READ LABOR_READ TIMECARDS_READ";

function redirectResponse(url: string): Response {
  return new Response(null, { status: 302, headers: { ...corsHeaders, Location: url } });
}

// Best-effort provider-side revoke of the stored Square access token. Never throws and never
// blocks disconnect: returns false on any failure and the caller reports it as `revoked: false`.
async function postSquareRevoke(
  accessToken: string,
  apiBase: string,
  clientId: string,
  clientSecret: string,
): Promise<boolean> {
  try {
    const response = await fetch(`${apiBase}/oauth2/revoke`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Client ${clientSecret}`,
      },
      body: JSON.stringify({ client_id: clientId, access_token: accessToken }),
      signal: AbortSignal.timeout(OAUTH_FETCH_TIMEOUT_MS),
    });
    if (!response.ok) {
      console.error("Square token revoke failed", response.status, await response.text());
      return false;
    }
    return true;
  } catch (error) {
    console.error("Square token revoke threw", error);
    return false;
  }
}

async function revokeSquareAccessToken(
  serviceClient: ReturnType<typeof createServiceClient>,
  venueId: string,
  encryptionKey: string,
  apiBase: string,
  clientId: string,
  clientSecret: string,
): Promise<boolean> {
  try {
    const { data: connection, error } = await serviceClient
      .from("payroll_connections")
      .select("encrypted_access_token")
      .eq("venue_id", venueId)
      .eq("provider", "square")
      .maybeSingle();
    if (error || !connection?.encrypted_access_token) return false;

    const accessToken = await decryptToken(connection.encrypted_access_token, encryptionKey, {
      venueId,
      provider: "square",
    });
    return await postSquareRevoke(accessToken, apiBase, clientId, clientSecret);
  } catch (error) {
    console.error("Square token revoke threw", error);
    return false;
  }
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
  // Org owners/admins hold org-level memberships (venue_id null) — cover both rows.
  const callerRoles = await getCallerVenueRoles(userClient, userData.user.id, venueId);
  if (!callerRoles) {
    return { error: jsonResponse({ error: "not_a_venue_manager" }, 403) };
  }
  if (!isManager(callerRoles.roles)) {
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
    captureException(error, { function: "square-oauth", path: new URL(req.url).pathname });
    await flushObservability();
    // The browser is waiting on /callback, so send it to the error page rather than JSON.
    const oauthErrorUrl = Deno.env.get("PAYROLL_OAUTH_ERROR_URL");
    if (oauthErrorUrl && new URL(req.url).pathname.endsWith("/callback")) {
      return redirectResponse(`${oauthErrorUrl}?provider=square&reason=internal_error`);
    }
    return jsonResponse({ error: "internal_error" }, 500);
  }
});

async function handleRequest(req: Request): Promise<Response> {
  const url = new URL(req.url);
  const encryptionKey = Deno.env.get("PAYROLL_TOKEN_ENCRYPTION_KEY");
  // Separate HMAC key for OAuth state signing, never the AES-GCM data key. No fallback to
  // PAYROLL_TOKEN_ENCRYPTION_KEY: a missing key fails closed with the not-configured error.
  const stateSigningKey = Deno.env.get("OAUTH_STATE_SIGNING_KEY");
  // No sandbox default: SQUARE_API_BASE must be set explicitly (sandbox or production).
  const apiBase = Deno.env.get("SQUARE_API_BASE");
  const clientId = Deno.env.get("SQUARE_APPLICATION_ID");
  const clientSecret = Deno.env.get("SQUARE_APPLICATION_SECRET");
  const redirectUri = Deno.env.get("SQUARE_REDIRECT_URI");
  const scopes = Deno.env.get("SQUARE_OAUTH_SCOPES") ?? DEFAULT_SCOPES;

  if (!encryptionKey || !stateSigningKey || !apiBase || !clientId || !clientSecret || !redirectUri) {
    console.error("square-oauth is not fully configured");
    // Callbacks must redirect (the browser is waiting), API calls get JSON.
    if (url.pathname.endsWith("/callback")) {
      const errorUrl = Deno.env.get("PAYROLL_OAUTH_ERROR_URL") ?? "venuewrangler://integrations/error";
      return redirectResponse(`${errorUrl}?provider=square&reason=not_configured`);
    }
    return jsonResponse({ error: "billing_not_configured" }, 500);
  }

  if (url.pathname.endsWith("/connect") && req.method === "POST") {
    let payload: { venue_id?: string };
    try {
      payload = await req.json();
    } catch {
      return jsonResponse({ error: "invalid_json_body" }, 400);
    }
    if (!payload.venue_id) return jsonResponse({ error: "missing_venue_id" }, 400);
    if (!isUuid(payload.venue_id)) return jsonResponse({ error: "invalid_venue_id" }, 400);

    const auth = await requireVenueManager(req.headers.get("Authorization"), payload.venue_id);
    if ("error" in auth) return auth.error;

    const state = await signOAuthState(
      { venue_id: payload.venue_id, user_id: auth.userId, aud: "square" },
      stateSigningKey,
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

    const statePayload = await verifyOAuthState(state, stateSigningKey, "square");
    if (!statePayload) return redirectResponse(`${errorUrl}?provider=square&reason=invalid_state`);

    const serviceClient = createServiceClient();
    if (!await isCurrentVenueManager(serviceClient, statePayload.user_id, statePayload.venue_id)) {
      return redirectResponse(`${errorUrl}?provider=square&reason=authorization_revoked`);
    }

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
      signal: AbortSignal.timeout(OAUTH_FETCH_TIMEOUT_MS),
    });

    if (!tokenResponse.ok) {
      console.error("Square token exchange failed", await tokenResponse.text());
      return redirectResponse(`${errorUrl}?provider=square&reason=token_exchange_failed`);
    }

    const tokenData = await tokenResponse.json();
    if (!tokenData?.access_token) {
      console.error("Square token exchange returned no access_token");
      return redirectResponse(`${errorUrl}?provider=square&reason=token_exchange_failed`);
    }
    if (!await isCurrentVenueManager(serviceClient, statePayload.user_id, statePayload.venue_id)) {
      return redirectResponse(`${errorUrl}?provider=square&reason=authorization_revoked`);
    }

    // Park the encrypted tokens; the connection is activated only by POST /complete.
    const stored = await storePendingConnection(serviceClient, {
      provider: "square",
      state: statePayload,
      encryptionKey,
      revokeTokens: ({ accessToken }) => postSquareRevoke(accessToken, apiBase, clientId, clientSecret),
      tokens: {
        accessToken: tokenData.access_token,
        refreshToken: tokenData.refresh_token ?? null,
        tokenExpiresAt: tokenData.expires_at ?? null,
        externalAccountId: tokenData.merchant_id ?? null,
      },
    });
    if (!stored.ok) {
      return redirectResponse(`${errorUrl}?provider=square&reason=${stored.reason}`);
    }

    return redirectResponse(withQuery(successUrl, { provider: "square", nonce: stored.nonce }));
  }

  if (url.pathname.endsWith("/complete") && req.method === "POST") {
    return await handleCompleteRequest({
      req,
      provider: "square",
      serviceClient: createServiceClient(),
      encryptionKey,
      revokePrevious: (venueId) =>
        revokeSquareAccessToken(
          createServiceClient(),
          venueId,
          encryptionKey,
          apiBase,
          clientId,
          clientSecret,
        ),
    });
  }

  if (url.pathname.endsWith("/disconnect") && req.method === "POST") {
    let payload: { venue_id?: string };
    try {
      payload = await req.json();
    } catch {
      return jsonResponse({ error: "invalid_json_body" }, 400);
    }
    if (!payload.venue_id) return jsonResponse({ error: "missing_venue_id" }, 400);
    if (!isUuid(payload.venue_id)) return jsonResponse({ error: "invalid_venue_id" }, 400);

    const auth = await requireVenueManager(req.headers.get("Authorization"), payload.venue_id);
    if ("error" in auth) return auth.error;

    const serviceClient = createServiceClient();
    // Revoke before clearing our copy; a failed revoke still lets the disconnect proceed.
    const revoked = await revokeSquareAccessToken(
      serviceClient,
      payload.venue_id,
      encryptionKey,
      apiBase,
      clientId,
      clientSecret,
    );
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
    return jsonResponse({ disconnected: true, revoked });
  }

  return jsonResponse({ error: "not_found" }, 404);
}

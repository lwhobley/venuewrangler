// Shared two-step payroll OAuth connection flow (audit B-04), used by square-oauth,
// quickbooks-oauth and gusto-oauth.
//
// Step 1 - callback (verify_jwt = false, reached by whichever browser finished consent):
//   exchange the code, then storePendingConnection(): the ENCRYPTED tokens are inserted into
//   public.oauth_pending_connections under a fresh random completion nonce, and the browser is
//   redirected to the app deep link carrying that nonce. The connection is NOT activated.
//
// Step 2 - POST /<provider>-oauth/complete {nonce} with the user's bearer JWT:
//   handleCompleteRequest() atomically consumes the pending row only if auth.uid() equals the
//   row's user_id (the user who started the flow) and it is unexpired/unconsumed, revokes any
//   previous grant for that connection, then upserts payroll_connections.
//
// Why this fixes B-04: an attacker can mint a consent link and forward it to a victim merchant.
// The victim's tokens land in a pending row owned by the attacker's user_id, but the completion
// nonce is generated at callback time and is only ever sent to the browser that finished
// consent (the victim's), never derived from the `state` the attacker holds. The attacker has
// the JWT but not the nonce; the victim has the nonce but not the attacker's JWT.
import type { SupabaseClient } from "@supabase/supabase-js";
import { corsHeaders } from "./cors.ts";
import { createUserClient } from "./supabase-clients.ts";
import {
  decryptToken,
  encryptToken,
  type OAuthProvider,
  type OAuthStatePayload,
} from "./crypto.ts";
import { getCallerVenueRoles, isManager, isUuid } from "./venue-auth.ts";

/** Timeout for every outbound provider call made during connect/disconnect/complete. */
export const OAUTH_FETCH_TIMEOUT_MS = 10_000;

const STALE_PENDING_AFTER_MS = 60 * 60 * 1000;
// A pending row is useless once its 10 minute window has passed; give the app a little grace.
const ABANDONED_PENDING_AFTER_MS = 15 * 60 * 1000;

/** Provider-side revoke of one grant's tokens. Best effort: returns false on any failure. */
export type RevokeTokens = (tokens: {
  accessToken: string;
  refreshToken: string | null;
}) => Promise<boolean>;

/**
 * A consent flow that nobody completed (for example a forwarded consent link) leaves a live grant
 * at the provider. Before such rows are deleted, revoke the grant. Never throws.
 */
async function revokeAbandonedPending(
  serviceClient: SupabaseClient,
  provider: OAuthProvider,
  encryptionKey: string,
  revokeTokens: RevokeTokens,
): Promise<void> {
  try {
    const { data: rows } = await serviceClient
      .from("oauth_pending_connections")
      .select("id, venue_id, encrypted_access_token, encrypted_refresh_token")
      .eq("provider", provider)
      .is("consumed_at", null)
      .lt("created_at", new Date(Date.now() - ABANDONED_PENDING_AFTER_MS).toISOString())
      .limit(20);
    for (const row of rows ?? []) {
      try {
        const context = { venueId: row.venue_id as string, provider };
        const accessToken = await decryptToken(row.encrypted_access_token as string, encryptionKey, context);
        const refreshToken = row.encrypted_refresh_token
          ? await decryptToken(row.encrypted_refresh_token as string, encryptionKey, context)
          : null;
        await revokeTokens({ accessToken, refreshToken });
      } catch (error) {
        console.error("revoking an abandoned pending grant failed", error);
      }
      await serviceClient.from("oauth_pending_connections").delete().eq("id", row.id);
    }
  } catch (error) {
    console.error("abandoned pending grant cleanup failed", error);
  }
}

export function oauthJson(body: Record<string, unknown>, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

/** Appends query parameters to a deep link that may or may not already have a query string. */
export function withQuery(base: string, params: Record<string, string>): string {
  const query = new URLSearchParams(params).toString();
  return `${base}${base.includes("?") ? "&" : "?"}${query}`;
}

export interface ProviderTokens {
  accessToken: string;
  refreshToken: string | null;
  tokenExpiresAt: string | null;
  externalAccountId: string | null;
}

export type StorePendingResult =
  | { ok: true; nonce: string }
  | { ok: false; reason: "state_reused" | "venue_not_found" | "storage_failed" };

/**
 * Callback step: encrypt the freshly exchanged tokens and park them in
 * oauth_pending_connections. Returns the completion nonce to put in the app deep link.
 */
export async function storePendingConnection(
  serviceClient: SupabaseClient,
  args: {
    provider: OAuthProvider;
    state: OAuthStatePayload;
    tokens: ProviderTokens;
    encryptionKey: string;
    /** Revokes grants parked by consent flows nobody completed (see revokeAbandonedPending). */
    revokeTokens?: RevokeTokens;
  },
): Promise<StorePendingResult> {
  const { provider, state, tokens, encryptionKey, revokeTokens } = args;

  if (revokeTokens) {
    await revokeAbandonedPending(serviceClient, provider, encryptionKey, revokeTokens);
  }

  // Opportunistic cleanup (a pg_cron job is the backstop). Never blocks the flow.
  try {
    await serviceClient
      .from("oauth_pending_connections")
      .delete()
      .lt("created_at", new Date(Date.now() - STALE_PENDING_AFTER_MS).toISOString());
  } catch (error) {
    console.error("oauth pending cleanup failed", error);
  }

  const { data: venue, error: venueError } = await serviceClient
    .from("venues")
    .select("organization_id")
    .eq("id", state.venue_id)
    .maybeSingle();
  if (venueError || !venue) return { ok: false, reason: "venue_not_found" };

  const context = { venueId: state.venue_id, provider };
  const nonce = crypto.randomUUID();
  const { error } = await serviceClient.from("oauth_pending_connections").insert({
    id: nonce,
    state_nonce: state.nonce,
    user_id: state.user_id,
    venue_id: state.venue_id,
    organization_id: venue.organization_id,
    provider,
    external_account_id: tokens.externalAccountId,
    encrypted_access_token: await encryptToken(tokens.accessToken, encryptionKey, context),
    encrypted_refresh_token: tokens.refreshToken
      ? await encryptToken(tokens.refreshToken, encryptionKey, context)
      : null,
    token_expires_at: tokens.tokenExpiresAt,
  });
  if (error) {
    // 23505 on state_nonce: this signed state was already redeemed once.
    if (error.code === "23505") return { ok: false, reason: "state_reused" };
    console.error("failed to store pending OAuth connection", error);
    return { ok: false, reason: "storage_failed" };
  }
  return { ok: true, nonce };
}

/**
 * POST /<provider>-oauth/complete handler.
 *
 * `revokePrevious(venueId)` is the provider's own best-effort revoke of whatever grant
 * payroll_connections currently holds for that venue; it must never throw.
 */
export async function handleCompleteRequest(args: {
  req: Request;
  provider: OAuthProvider;
  serviceClient: SupabaseClient;
  encryptionKey: string;
  revokePrevious: (venueId: string) => Promise<boolean>;
}): Promise<Response> {
  const { req, provider, serviceClient, encryptionKey, revokePrevious } = args;

  const authHeader = req.headers.get("Authorization");
  if (!authHeader) return oauthJson({ error: "missing_authorization_header" }, 401);
  const userClient = createUserClient(authHeader);
  const { data: userData, error: userError } = await userClient.auth.getUser();
  if (userError || !userData?.user) {
    return oauthJson({ error: "invalid_or_expired_session" }, 401);
  }
  const userId = userData.user.id;

  let payload: { nonce?: unknown };
  try {
    payload = await req.json();
  } catch {
    return oauthJson({ error: "invalid_json_body" }, 400);
  }
  if (!payload || !isUuid(payload.nonce)) return oauthJson({ error: "invalid_nonce" }, 400);
  const nonce = payload.nonce;

  // Look the row up first so the caller's manager role can be checked on ITS venue (never a
  // venue taken from the request). Unknown nonce, another user's nonce and another provider's
  // nonce all answer the same 404 so the endpoint is not an oracle.
  const { data: pending, error: pendingError } = await serviceClient
    .from("oauth_pending_connections")
    .select("venue_id, user_id, provider")
    .eq("id", nonce)
    .maybeSingle();
  if (pendingError) {
    console.error("pending OAuth connection lookup failed", pendingError);
    return oauthJson({ error: "completion_failed" }, 500);
  }
  if (!pending || pending.user_id !== userId || pending.provider !== provider) {
    return oauthJson({ error: "pending_connection_not_found" }, 404);
  }

  const callerRoles = await getCallerVenueRoles(userClient, userId, pending.venue_id as string);
  if (!callerRoles || !isManager(callerRoles.roles)) {
    return oauthJson({ error: "not_a_venue_manager" }, 403);
  }

  // Atomic single-statement consume: succeeds for exactly one caller, only while the row is
  // unconsumed, unexpired, and owned by the authenticated user.
  const { data: consumed, error: consumeError } = await serviceClient
    .from("oauth_pending_connections")
    .update({ consumed_at: new Date().toISOString() })
    .eq("id", nonce)
    .eq("user_id", userId)
    .eq("provider", provider)
    .is("consumed_at", null)
    .gt("expires_at", new Date().toISOString())
    .select(
      "venue_id, external_account_id, encrypted_access_token, encrypted_refresh_token, token_expires_at",
    );
  if (consumeError) {
    console.error("failed to consume pending OAuth connection", consumeError);
    return oauthJson({ error: "completion_failed" }, 500);
  }
  if (!consumed || consumed.length === 0) {
    return oauthJson({ error: "pending_connection_expired_or_used" }, 410);
  }
  const row = consumed[0];
  const venueId = row.venue_id as string;

  // Revoke the previous grant for this connection first, so a replaced grant does not stay
  // live at the provider. Skipped when the provider handed back the identical token (same
  // grant re-issued), because revoking it would kill the grant we are about to store.
  if (await previousGrantDiffers(serviceClient, venueId, provider, row, encryptionKey)) {
    await revokePrevious(venueId);
  }

  const { error: upsertError } = await serviceClient.from("payroll_connections").upsert(
    {
      venue_id: venueId,
      provider,
      status: "connected",
      external_account_id: row.external_account_id,
      encrypted_access_token: row.encrypted_access_token,
      encrypted_refresh_token: row.encrypted_refresh_token,
      token_expires_at: row.token_expires_at,
      connected_by: userId,
      last_error: null,
    },
    { onConflict: "venue_id,provider" },
  );
  if (upsertError) {
    console.error(`failed to persist ${provider} connection`, upsertError);
    // Give the user a retry instead of burning the nonce.
    await serviceClient
      .from("oauth_pending_connections")
      .update({ consumed_at: null })
      .eq("id", nonce)
      .then(({ error }) => {
        if (error) console.error("failed to un-consume pending OAuth connection", error);
      });
    return oauthJson({ error: "storage_failed" }, 500);
  }

  // The tokens now live in payroll_connections; drop the pending copy.
  const { error: deleteError } = await serviceClient
    .from("oauth_pending_connections")
    .delete()
    .eq("id", nonce);
  if (deleteError) console.error("failed to delete consumed pending OAuth connection", deleteError);

  return oauthJson({ ok: true });
}

async function previousGrantDiffers(
  serviceClient: SupabaseClient,
  venueId: string,
  provider: OAuthProvider,
  next: { encrypted_access_token: string; encrypted_refresh_token: string | null },
  encryptionKey: string,
): Promise<boolean> {
  try {
    const { data: previous, error } = await serviceClient
      .from("payroll_connections")
      .select("encrypted_access_token, encrypted_refresh_token")
      .eq("venue_id", venueId)
      .eq("provider", provider)
      .maybeSingle();
    if (error || !previous?.encrypted_access_token) return false; // nothing to revoke

    const context = { venueId, provider };
    const [oldAccess, newAccess] = await Promise.all([
      decryptToken(previous.encrypted_access_token, encryptionKey, context),
      decryptToken(next.encrypted_access_token, encryptionKey, context),
    ]);
    if (oldAccess === newAccess) return false;
    if (previous.encrypted_refresh_token && next.encrypted_refresh_token) {
      const [oldRefresh, newRefresh] = await Promise.all([
        decryptToken(previous.encrypted_refresh_token, encryptionKey, context),
        decryptToken(next.encrypted_refresh_token, encryptionKey, context),
      ]);
      if (oldRefresh === newRefresh) return false;
    }
    return true;
  } catch (error) {
    // Undecryptable previous row (e.g. key rotation): revoke is best-effort and will no-op too.
    console.error("could not compare previous grant", error);
    return true;
  }
}

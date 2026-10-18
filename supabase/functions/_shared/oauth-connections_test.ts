import type { SupabaseClient } from "@supabase/supabase-js";
import { decryptToken, encryptToken, signOAuthState, verifyOAuthState } from "./crypto.ts";
import { storePendingConnection, withQuery } from "./oauth-connections.ts";
import { isUuid } from "./venue-auth.ts";

const encryptionKey = btoa("e".repeat(32));
const signingKey = btoa("s".repeat(32));
const VENUE = "11111111-1111-1111-1111-111111111111";
const USER = "22222222-2222-2222-2222-222222222222";
const ORG = "33333333-3333-3333-3333-333333333333";

Deno.test("withQuery appends to links with and without an existing query", () => {
  if (withQuery("venuewrangler://integrations/connected", { provider: "square", nonce: "n" }) !==
    "venuewrangler://integrations/connected?provider=square&nonce=n") throw new Error("plain");
  if (withQuery("https://x.test/p?a=1", { nonce: "n" }) !== "https://x.test/p?a=1&nonce=n") {
    throw new Error("existing query");
  }
});

Deno.test("isUuid accepts only canonical uuids", () => {
  if (!isUuid(VENUE)) throw new Error("valid uuid rejected");
  for (const bad of ["", "x", `${VENUE},venue_id.is.null`, `${VENUE})`, null, undefined, 5]) {
    if (isUuid(bad)) throw new Error(`accepted ${String(bad)}`);
  }
});

// Minimal fake of the PostgREST calls storePendingConnection makes.
function fakeServiceClient(insertError: { code?: string } | null) {
  const inserted: Record<string, unknown>[] = [];
  const client = {
    from(table: string) {
      return {
        delete() {
          return { lt: () => Promise.resolve({ error: null }) };
        },
        select() {
          return {
            eq: () => ({
              maybeSingle: () => Promise.resolve({ data: { organization_id: ORG }, error: null }),
            }),
          };
        },
        insert(row: Record<string, unknown>) {
          if (table === "oauth_pending_connections") inserted.push(row);
          return Promise.resolve({ error: insertError });
        },
      };
    },
  } as unknown as SupabaseClient;
  return { client, inserted };
}

Deno.test("storePendingConnection stores encrypted tokens under a completion nonce distinct from the state nonce", async () => {
  const stateToken = await signOAuthState({ venue_id: VENUE, user_id: USER, aud: "square" }, signingKey);
  const state = (await verifyOAuthState(stateToken, signingKey, "square"))!;
  const { client, inserted } = fakeServiceClient(null);

  const result = await storePendingConnection(client, {
    provider: "square",
    state,
    encryptionKey,
    tokens: {
      accessToken: "access-123",
      refreshToken: "refresh-456",
      tokenExpiresAt: null,
      externalAccountId: "merchant-1",
    },
  });
  if (!result.ok) throw new Error(`store failed: ${result.reason}`);

  // The nonce handed to the browser must not be derivable from anything in the signed state,
  // which the (possibly malicious) flow initiator also holds.
  if (result.nonce === state.nonce) throw new Error("completion nonce equals the state nonce");

  const row = inserted[0];
  if (row.id !== result.nonce || row.state_nonce !== state.nonce) throw new Error("wrong ids");
  if (row.user_id !== USER || row.venue_id !== VENUE || row.organization_id !== ORG) {
    throw new Error("wrong ownership columns");
  }
  const access = row.encrypted_access_token as string;
  if (access.includes("access-123") || !access.startsWith("v1.")) throw new Error("not encrypted v1");
  const context = { venueId: VENUE, provider: "square" } as const;
  if (await decryptToken(access, encryptionKey, context) !== "access-123") throw new Error("access");
  if (await decryptToken(row.encrypted_refresh_token as string, encryptionKey, context) !== "refresh-456") {
    throw new Error("refresh");
  }
});

Deno.test("storePendingConnection reports a replayed state (unique violation)", async () => {
  const stateToken = await signOAuthState({ venue_id: VENUE, user_id: USER, aud: "gusto" }, signingKey);
  const state = (await verifyOAuthState(stateToken, signingKey, "gusto"))!;
  const { client } = fakeServiceClient({ code: "23505" });
  const result = await storePendingConnection(client, {
    provider: "gusto",
    state,
    encryptionKey,
    tokens: { accessToken: "a", refreshToken: null, tokenExpiresAt: null, externalAccountId: null },
  });
  if (result.ok || result.reason !== "state_reused") throw new Error("replay not detected");
});

// A consent flow nobody completed leaves a live grant at the provider: it is revoked, then deleted.
Deno.test("storePendingConnection revokes abandoned pending grants before deleting them", async () => {
  const context = { venueId: VENUE, provider: "square" as const };
  const staleRow = {
    id: "stale-row-1",
    venue_id: VENUE,
    encrypted_access_token: await encryptToken("stale-access", encryptionKey, context),
    encrypted_refresh_token: await encryptToken("stale-refresh", encryptionKey, context),
  };
  const deletedIds: string[] = [];
  const inserted: Record<string, unknown>[] = [];
  const client = {
    from(table: string) {
      return {
        select(columns: string) {
          if (columns.includes("encrypted_access_token")) {
            // revokeAbandonedPending: select(...).eq().is().lt().limit()
            const chain = {
              eq: () => chain,
              is: () => chain,
              lt: () => chain,
              limit: () => Promise.resolve({ data: [staleRow], error: null }),
            };
            return chain;
          }
          return {
            eq: () => ({
              maybeSingle: () => Promise.resolve({ data: { organization_id: ORG }, error: null }),
            }),
          };
        },
        delete() {
          return {
            lt: () => Promise.resolve({ error: null }),
            eq: (_column: string, id: string) => {
              deletedIds.push(id);
              return Promise.resolve({ error: null });
            },
          };
        },
        insert(row: Record<string, unknown>) {
          if (table === "oauth_pending_connections") inserted.push(row);
          return Promise.resolve({ error: null });
        },
      };
    },
  } as unknown as SupabaseClient;

  const stateToken = await signOAuthState({ venue_id: VENUE, user_id: USER, aud: "square" }, signingKey);
  const state = (await verifyOAuthState(stateToken, signingKey, "square"))!;
  const revoked: Array<{ accessToken: string; refreshToken: string | null }> = [];

  const result = await storePendingConnection(client, {
    provider: "square",
    state,
    encryptionKey,
    revokeTokens: (tokens) => {
      revoked.push(tokens);
      return Promise.resolve(true);
    },
    tokens: { accessToken: "fresh", refreshToken: null, tokenExpiresAt: null, externalAccountId: null },
  });

  if (!result.ok) throw new Error("store failed");
  if (revoked.length !== 1 || revoked[0].accessToken !== "stale-access" || revoked[0].refreshToken !== "stale-refresh") {
    throw new Error("the abandoned grant was not revoked with its decrypted tokens");
  }
  if (deletedIds.join() !== "stale-row-1") throw new Error("the abandoned row was not deleted");
  if (inserted.length !== 1) throw new Error("the new pending row was not stored");
});

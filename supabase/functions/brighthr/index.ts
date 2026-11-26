// BrightHR Customer API integration (employees, approved absences, Blip clock-ins).
//
// Routes (all POST):
//   /connect    {venue_id, client_id, client_secret}  manager JWT. Verifies the credentials
//               against BrightHR, stores the secret encrypted, starts the first sync.
//   /sync       {venue_id}                             manager JWT. Starts a sync now.
//   /link       {venue_id, external_employee_id, staff_id|null}  manager JWT. Links/unlinks a
//               BrightHR employee to a team member (public.link_brighthr_employee enforces the
//               rules), then writes the member id to BrightHR as the employee's externalReference.
//   /disconnect {venue_id}                             manager JWT. Deletes the connection and
//               every imported row. BrightHR has no revoke endpoint for client credentials, so the
//               app tells the manager to delete the API application in BrightHR as well.
//   /dispatch   {}                                     x-dispatch-secret (pg_cron). Syncs due
//               connections.
//
// verify_jwt = false in config.toml because /dispatch is called by pg_net with a shared secret;
// every other route validates the caller's JWT itself.
//
// Env: PAYROLL_TOKEN_ENCRYPTION_KEY (shared AES key, secrets are bound to venue:brighthr),
// BRIGHTHR_SYNC_DISPATCH_SECRET (>= 32 chars), optional BRIGHTHR_TOKEN_URL / BRIGHTHR_API_BASE.
import { handleCorsPreflight, serveWithCors } from "../_shared/cors.ts";
import { createServiceClient, createUserClient } from "../_shared/supabase-clients.ts";
import { getCallerVenueRoles, isManager, isUuid } from "../_shared/venue-auth.ts";
import { decryptToken, encryptToken } from "../_shared/crypto.ts";
import { oauthJson as jsonResponse } from "../_shared/oauth-connections.ts";
import { captureException, flushObservability, initObservability } from "../_shared/observability.ts";
import { enforceRateLimit } from "../_shared/rate-limit.ts";
import { requireCallerMfa } from "../_shared/mfa.ts";
import { BrightHrClient, BrightHrError } from "../_shared/brighthr.ts";
import { syncConnection } from "./sync.ts";

initObservability();

const DISPATCH_BATCH = 5;
const DISPATCH_TIME_BUDGET_MS = 120_000;

type Admin = ReturnType<typeof createServiceClient>;

function clientOptions() {
  return {
    tokenUrl: Deno.env.get("BRIGHTHR_TOKEN_URL") || undefined,
    apiBase: Deno.env.get("BRIGHTHR_API_BASE") || undefined,
  };
}

function syncOptions(encryptionKey: string) {
  return { encryptionKey, clientOptions: clientOptions() };
}

function constantTimeEqual(a: string, b: string): boolean {
  const x = new TextEncoder().encode(a);
  const y = new TextEncoder().encode(b);
  let difference = x.length ^ y.length;
  for (let i = 0; i < Math.max(x.length, y.length); i++) difference |= (x[i] ?? 0) ^ (y[i] ?? 0);
  return difference === 0;
}

/** Runs work after the response when the edge runtime supports it, otherwise inline. */
async function runInBackground(work: Promise<unknown>): Promise<boolean> {
  const runtime = (globalThis as { EdgeRuntime?: { waitUntil?: (p: Promise<unknown>) => void } })
    .EdgeRuntime;
  const guarded = work.catch((error) => {
    console.error("brighthr: background sync failed", error);
    captureException(error, { function: "brighthr", phase: "background" });
  });
  if (runtime?.waitUntil) {
    runtime.waitUntil(guarded);
    return true;
  }
  await guarded;
  return false;
}

async function readJson(req: Request): Promise<Record<string, unknown> | null> {
  const parsed: unknown = await req.json().catch(() => null);
  return parsed && typeof parsed === "object" && !Array.isArray(parsed)
    ? parsed as Record<string, unknown>
    : null;
}

async function requireVenueManager(
  authHeader: string | null,
  venueId: string,
): Promise<{ userId: string; authHeader: string } | { error: Response }> {
  if (!authHeader) return { error: jsonResponse({ error: "missing_authorization_header" }, 401) };
  const userClient = createUserClient(authHeader);
  const { data: userData, error: userError } = await userClient.auth.getUser();
  if (userError || !userData?.user) {
    return { error: jsonResponse({ error: "invalid_or_expired_session" }, 401) };
  }
  const callerRoles = await getCallerVenueRoles(userClient, userData.user.id, venueId);
  if (!callerRoles || !isManager(callerRoles.roles)) {
    return { error: jsonResponse({ error: "not_a_venue_manager" }, 403) };
  }
  return { userId: userData.user.id, authHeader };
}

async function connectionForVenue(admin: Admin, venueId: string) {
  const { data, error } = await admin
    .from("brighthr_connections")
    .select("id, client_id")
    .eq("venue_id", venueId)
    .maybeSingle();
  if (error) throw error;
  return data as { id: string; client_id: string } | null;
}

/** Leases the connection so a manual sync never overlaps a scheduled one. */
async function leaseConnection(admin: Admin, connectionId: string): Promise<boolean> {
  const nowIso = new Date().toISOString();
  const { data, error } = await admin
    .from("brighthr_connections")
    .update({ sync_lease_until: new Date(Date.now() + 10 * 60 * 1000).toISOString() })
    .eq("id", connectionId)
    .or(`sync_lease_until.is.null,sync_lease_until.lt.${nowIso}`)
    .select("id")
    .maybeSingle();
  if (error) throw error;
  return data !== null;
}

serveWithCors(async (req) => {
  const preflight = handleCorsPreflight(req);
  if (preflight) return preflight;
  try {
    return await handleRequest(req);
  } catch (error) {
    console.error("brighthr: unexpected error", error);
    captureException(error, { function: "brighthr", path: new URL(req.url).pathname });
    await flushObservability();
    return jsonResponse({ error: "internal_error" }, 500);
  }
});

async function handleRequest(req: Request): Promise<Response> {
  if (req.method !== "POST") return jsonResponse({ error: "method_not_allowed" }, 405);
  const path = new URL(req.url).pathname;
  const encryptionKey = Deno.env.get("PAYROLL_TOKEN_ENCRYPTION_KEY");
  if (!encryptionKey) {
    console.error("brighthr is not configured: PAYROLL_TOKEN_ENCRYPTION_KEY missing");
    return jsonResponse({ error: "integration_not_configured" }, 500);
  }
  const admin = createServiceClient();

  if (path.endsWith("/dispatch")) return await handleDispatch(req, admin, encryptionKey);

  const body = await readJson(req);
  if (!body) return jsonResponse({ error: "invalid_json_body" }, 400);
  const venueId = body.venue_id;
  if (!isUuid(venueId)) return jsonResponse({ error: "invalid_venue_id" }, 400);

  const auth = await requireVenueManager(req.headers.get("Authorization"), venueId);
  if ("error" in auth) return auth.error;

  // MFA step-up for connecting/disconnecting the HR integration (audit F04), after the manager
  // check. /sync and /link are routine operations and stay ungated.
  if (path.endsWith("/connect") || path.endsWith("/disconnect")) {
    const mfaBlocked = await requireCallerMfa(createUserClient(auth.authHeader));
    if (mfaBlocked) return mfaBlocked;
  }

  if (path.endsWith("/connect")) return await handleConnect(body, venueId, auth.userId, admin, encryptionKey);
  if (path.endsWith("/sync")) return await handleSync(venueId, admin, encryptionKey);
  if (path.endsWith("/link")) return await handleLink(body, venueId, auth.userId, auth.authHeader, admin, encryptionKey);
  if (path.endsWith("/disconnect")) return await handleDisconnect(venueId, admin);
  return jsonResponse({ error: "not_found" }, 404);
}

async function handleConnect(
  body: Record<string, unknown>,
  venueId: string,
  userId: string,
  admin: Admin,
  encryptionKey: string,
): Promise<Response> {
  const clientId = typeof body.client_id === "string" ? body.client_id.trim() : "";
  const clientSecret = typeof body.client_secret === "string" ? body.client_secret.trim() : "";
  if (!clientId || clientId.length > 200 || !clientSecret || clientSecret.length > 500) {
    return jsonResponse({ error: "invalid_credentials_format" }, 400);
  }

  // Each attempt is a credential check against BrightHR: keep it slow enough to be useless for
  // guessing and polite to their token endpoint.
  const limited = await enforceRateLimit(admin, `brighthr-connect:user:${userId}`, 10, 3600);
  if (limited) return limited;

  try {
    await new BrightHrClient({ ...clientOptions(), clientId, clientSecret }).verifyAccess();
  } catch (error) {
    if (error instanceof BrightHrError) {
      if (error.code === "invalid_credentials") return jsonResponse({ error: "brighthr_invalid_credentials" }, 400);
      if (error.code === "forbidden") return jsonResponse({ error: "brighthr_forbidden" }, 400);
      return jsonResponse({ error: "brighthr_unavailable" }, 502);
    }
    throw error;
  }

  const encryptedSecret = await encryptToken(clientSecret, encryptionKey, { venueId, provider: "brighthr" });
  const existing = await connectionForVenue(admin, venueId);
  // Different credentials may belong to a different BrightHR company: start clean so no employee
  // link or imported record from the old account survives.
  if (existing && existing.client_id !== clientId) {
    const { error } = await admin.from("brighthr_connections").delete().eq("id", existing.id);
    if (error) throw error;
  }

  const { data: saved, error: saveError } = await admin
    .from("brighthr_connections")
    .upsert({
      venue_id: venueId,
      client_id: clientId,
      encrypted_client_secret: encryptedSecret,
      status: "connected",
      last_error: null,
      next_sync_at: new Date().toISOString(),
      connected_by: userId,
    }, { onConflict: "venue_id" })
    .select("id")
    .single();
  if (saveError) throw saveError;

  await leaseConnection(admin, saved.id);
  await runInBackground(syncConnection(admin, saved.id, "connect", syncOptions(encryptionKey)));
  return jsonResponse({ connected: true });
}

async function handleSync(venueId: string, admin: Admin, encryptionKey: string): Promise<Response> {
  const limited = await enforceRateLimit(admin, `brighthr-sync:venue:${venueId}`, 6, 3600, { failOpen: true });
  if (limited) return limited;
  const connection = await connectionForVenue(admin, venueId);
  if (!connection) return jsonResponse({ error: "not_connected" }, 404);
  if (!await leaseConnection(admin, connection.id)) return jsonResponse({ error: "sync_in_progress" }, 409);
  await runInBackground(syncConnection(admin, connection.id, "manual", syncOptions(encryptionKey)));
  return jsonResponse({ started: true }, 202);
}

async function handleLink(
  body: Record<string, unknown>,
  venueId: string,
  userId: string,
  authHeader: string,
  admin: Admin,
  encryptionKey: string,
): Promise<Response> {
  const externalEmployeeId = typeof body.external_employee_id === "string" ? body.external_employee_id : "";
  const staffId = body.staff_id ?? null;
  if (!externalEmployeeId || externalEmployeeId.length > 100) {
    return jsonResponse({ error: "invalid_external_employee_id" }, 400);
  }
  if (staffId !== null && !isUuid(staffId)) return jsonResponse({ error: "invalid_staff_id" }, 400);

  const limited = await enforceRateLimit(admin, `brighthr-link:user:${userId}`, 200, 3600, { failOpen: true });
  if (limited) return limited;

  const connection = await connectionForVenue(admin, venueId);
  if (!connection) return jsonResponse({ error: "not_connected" }, 404);

  // The caller's own JWT: the database, not this function, decides whether the link is allowed.
  const { error: linkError } = await createUserClient(authHeader).rpc("link_brighthr_employee", {
    p_connection_id: connection.id,
    p_external_employee_id: externalEmployeeId,
    p_staff_id: staffId,
  });
  if (linkError) {
    if (linkError.code === "42501") return jsonResponse({ error: "not_a_venue_manager" }, 403);
    if (linkError.code === "P0002") return jsonResponse({ error: "unknown_brighthr_employee" }, 404);
    if (linkError.code === "22023") return jsonResponse({ error: "not_a_venue_member" }, 400);
    throw linkError;
  }
  if (staffId === null) return jsonResponse({ linked: false });

  // Best effort: a failure here is retried by the next sync.
  let referenceWritten = false;
  try {
    const { data: secretRow } = await admin
      .from("brighthr_connections")
      .select("client_id, encrypted_client_secret")
      .eq("id", connection.id)
      .single();
    const clientSecret = await decryptToken(
      secretRow!.encrypted_client_secret as string,
      encryptionKey,
      { venueId, provider: "brighthr" },
    );
    await new BrightHrClient({ ...clientOptions(), clientId: secretRow!.client_id as string, clientSecret })
      .setExternalReference(externalEmployeeId, staffId);
    const nowIso = new Date().toISOString();
    await admin.from("brighthr_employee_mappings")
      .update({ external_reference_synced_at: nowIso })
      .eq("connection_id", connection.id).eq("external_employee_id", externalEmployeeId).eq("staff_id", staffId);
    await admin.from("brighthr_employees")
      .update({ external_reference: staffId })
      .eq("connection_id", connection.id).eq("external_employee_id", externalEmployeeId);
    referenceWritten = true;
  } catch (error) {
    console.error("brighthr: external reference write failed", error instanceof BrightHrError ? error.code : error);
  }
  // Pull this employee's absences and clockings on the next scheduled pass.
  await admin.from("brighthr_connections").update({ next_sync_at: new Date().toISOString() })
    .eq("id", connection.id);
  return jsonResponse({ linked: true, external_reference_written: referenceWritten });
}

async function handleDisconnect(venueId: string, admin: Admin): Promise<Response> {
  const { error } = await admin.from("brighthr_connections").delete().eq("venue_id", venueId);
  if (error) throw error;
  return jsonResponse({ disconnected: true });
}

async function handleDispatch(req: Request, admin: Admin, encryptionKey: string): Promise<Response> {
  const expected = Deno.env.get("BRIGHTHR_SYNC_DISPATCH_SECRET");
  const supplied = req.headers.get("x-dispatch-secret") ?? "";
  if (!expected || expected.length < 32 || !constantTimeEqual(supplied, expected)) {
    return jsonResponse({ error: "unauthorized" }, 401);
  }

  const { data: claimed, error } = await admin.rpc("claim_brighthr_sync", { p_limit: DISPATCH_BATCH });
  if (error) {
    console.error("brighthr: claim failed", error.code);
    return jsonResponse({ error: "claim_failed" }, 500);
  }
  const connections = (claimed ?? []) as { connection_id: string }[];
  const work = (async () => {
    const started = Date.now();
    for (const { connection_id } of connections) {
      const remaining = DISPATCH_TIME_BUDGET_MS - (Date.now() - started);
      if (remaining < 15_000) {
        // Release the lease so the next dispatch picks it up straight away.
        await admin.from("brighthr_connections").update({ sync_lease_until: null }).eq("id", connection_id);
        continue;
      }
      await syncConnection(admin, connection_id, "scheduled", {
        ...syncOptions(encryptionKey),
        timeBudgetMs: remaining - 10_000,
      });
    }
  })();
  await runInBackground(work);
  return jsonResponse({ claimed: connections.length }, 202);
}

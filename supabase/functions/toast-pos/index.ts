// supabase/functions/toast-pos/index.ts
// Legacy gateway check ingestion. This uses a custom gateway secret, not a
// verified native Toast webhook signature. Outbound menu commands are disabled
// until a provider-approved adapter and delivery worker exist.
//
// Authentication has two modes (audit B-07):
//  - Signed (preferred): headers X-Signature and X-Timestamp. X-Signature is the hex
//    HMAC-SHA256 over `${X-Timestamp}.${raw request body}`, and |now - X-Timestamp| must be
//    <= 300 seconds (unix seconds or milliseconds), which bounds replay. The plaintext gateway
//    secret is deliberately never stored, so the HMAC key is the lowercase hex SHA-256 of the
//    provisioned secret, i.e. the value kept in pos_connections.webhook_secret_hash. The
//    gateway computes it as sha256Hex(secret) and keeps it private.
//  - Legacy: the static X-Venue-Webhook-Secret header. Still accepted unless
//    POS_WEBHOOK_REQUIRE_SIGNATURE=true, so gateways can migrate without a flag day.

import { corsHeaders, handleCorsPreflight } from "../_shared/cors.ts";
import { createServiceClient } from "../_shared/supabase-clients.ts";
import { initObservability, captureException, flushObservability } from "../_shared/observability.ts";
import { sha256Hex } from "../_shared/crypto.ts";
import { enforceRateLimit } from "../_shared/rate-limit.ts";

initObservability();

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const MAX_WEBHOOK_BYTES = 256 * 1024;
const SIGNATURE_MAX_SKEW_SECONDS = 300;
const MAX_FREE_TEXT_CHARS = 200;
const PER_VENUE_LIMIT_PER_MINUTE = 600;

function constantTimeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let mismatch = 0;
  for (let i = 0; i < a.length; i++) mismatch |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return mismatch === 0;
}

async function hmacSha256Hex(key: string, message: string): Promise<string> {
  const cryptoKey = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(key),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign("HMAC", cryptoKey, new TextEncoder().encode(message));
  return Array.from(new Uint8Array(signature))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

// A free-text field must be absent, null, or a string of at most MAX_FREE_TEXT_CHARS after
// trimming. Returns undefined for "absent" (leave the stored value alone), null to clear, the
// trimmed string, or "invalid" for anything else.
function freeText(value: unknown): string | null | undefined | "invalid" {
  if (value === undefined) return undefined;
  if (value === null) return null;
  if (typeof value !== "string") return "invalid";
  const trimmed = value.trim();
  if (trimmed.length > MAX_FREE_TEXT_CHARS) return "invalid";
  return trimmed.length === 0 ? null : trimmed;
}

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
    console.error("toast-pos: unexpected error", error);
    captureException(error, { function: "toast-pos", path: new URL(req.url).pathname });
    await flushObservability();
    return jsonResponse({ error: "internal_error" }, 500);
  }
});

async function handleRequest(req: Request): Promise<Response> {
  const url = new URL(req.url);
  const action = url.pathname.split("/").pop();

  // Inbound Webhook Ingestion (/toast-pos/webhook)
  if (req.method === "POST" && action === "webhook") {
    // The webhook endpoint has no user JWT. Require a per-venue, high-entropy secret
    // provisioned by the POS gateway and stored only as a SHA-256 hash. Fail closed
    // for venues that have not configured one.
    const signatureHeader = req.headers.get("X-Signature");
    const timestampHeader = req.headers.get("X-Timestamp");
    const signedMode = signatureHeader !== null || timestampHeader !== null;
    const suppliedSecret = req.headers.get("X-Venue-Webhook-Secret");
    if (signedMode) {
      // Both headers or neither: a half-signed request is never downgraded to the legacy path.
      if (!signatureHeader || !timestampHeader || !/^[0-9a-f]{64}$/i.test(signatureHeader)) {
        return jsonResponse({ error: "unauthorized_webhook" }, 401);
      }
    } else {
      if (Deno.env.get("POS_WEBHOOK_REQUIRE_SIGNATURE") === "true") {
        return jsonResponse({ error: "signature_required" }, 401);
      }
      if (!suppliedSecret || suppliedSecret.length < 32 || suppliedSecret.length > 512) {
        return jsonResponse({ error: "unauthorized_webhook" }, 401);
      }
    }
    const contentLength = Number(req.headers.get("content-length") ?? "0");
    if (contentLength > MAX_WEBHOOK_BYTES) {
      return jsonResponse({ error: "payload_too_large" }, 413);
    }
    let payload: Record<string, unknown>;
    let rawBody: string;
    try {
      rawBody = await req.text();
      if (rawBody.length > MAX_WEBHOOK_BYTES) {
        return jsonResponse({ error: "payload_too_large" }, 413);
      }
      payload = JSON.parse(rawBody);
    } catch {
      return jsonResponse({ error: "invalid_json_body" }, 400);
    }
    if (payload === null || typeof payload !== "object" || Array.isArray(payload)) {
      return jsonResponse({ error: "invalid_json_body" }, 400);
    }

    const venueId = payload.venue_id;
    const externalCheckId = payload.external_check_id || payload.check_guid;

    if (typeof venueId !== "string" || !UUID_PATTERN.test(venueId) ||
        typeof externalCheckId !== "string" || externalCheckId.length === 0 ||
        externalCheckId.length > 256) {
      return jsonResponse({ error: "missing_required_fields" }, 400);
    }

    const serviceClient = createServiceClient();
    const { data: connection, error: connectionError } = await serviceClient
      .from("pos_connections")
      .select("webhook_secret_hash")
      .eq("venue_id", venueId)
      .eq("provider", "toast")
      .eq("status", "active")
      .maybeSingle();
    if (connectionError || !connection?.webhook_secret_hash) {
      return jsonResponse({ error: "unauthorized_webhook" }, 401);
    }
    const expectedHash = connection.webhook_secret_hash.toLowerCase();
    if (!/^[0-9a-f]{64}$/.test(expectedHash)) {
      return jsonResponse({ error: "unauthorized_webhook" }, 401);
    }
    if (signedMode) {
      // Accept unix seconds or milliseconds; the timestamp is signed exactly as sent.
      const timestampNumber = Number(timestampHeader);
      if (!Number.isFinite(timestampNumber) || timestampNumber <= 0) {
        return jsonResponse({ error: "unauthorized_webhook" }, 401);
      }
      const timestampSeconds = timestampNumber > 1e12 ? timestampNumber / 1000 : timestampNumber;
      if (Math.abs(Date.now() / 1000 - timestampSeconds) > SIGNATURE_MAX_SKEW_SECONDS) {
        return jsonResponse({ error: "unauthorized_webhook" }, 401);
      }
      const expectedSignature = await hmacSha256Hex(expectedHash, `${timestampHeader}.${rawBody}`);
      if (!constantTimeEqual(expectedSignature, signatureHeader!.toLowerCase())) {
        return jsonResponse({ error: "unauthorized_webhook" }, 401);
      }
    } else {
      const suppliedHash = await sha256Hex(new TextEncoder().encode(suppliedSecret!));
      if (!constantTimeEqual(suppliedHash, expectedHash)) {
        return jsonResponse({ error: "unauthorized_webhook" }, 401);
      }
    }

    // Per-venue ingest ceiling, charged only after authentication so unauthenticated traffic
    // cannot burn a venue's budget. Fails open: a limiter outage must not drop POS checks.
    const limited = await enforceRateLimit(
      serviceClient,
      `toast-pos:venue:${venueId}`,
      PER_VENUE_LIMIT_PER_MINUTE,
      60,
      { failOpen: true },
    );
    if (limited) return limited;

    // Amounts are whole cents; reject anything else rather than letting a malformed or
    // hostile payload write negative/fractional/absurd money into revenue reporting.
    const cents = (value: unknown): number | null => {
      if (value === undefined || value === null) return 0;
      return typeof value === "number" && Number.isInteger(value) && value >= 0 &&
          value <= 100_000_000
        ? value
        : null;
    };
    const subtotal = cents(payload.subtotal_cents);
    const tax = cents(payload.tax_cents);
    const tip = cents(payload.tip_cents);
    const total = cents(payload.total_cents);
    const incomingStatus = (payload.status as string | undefined) ?? "closed";
    const status = incomingStatus === "paid" ? "closed" :
      incomingStatus === "void" ? "voided" : incomingStatus;
    // Timestamps and shapes are checked here so a bad value is a 400 the gateway does not
    // retry, not a Postgres type error surfacing as a 500.
    const isIsoTimestamp = (value: unknown): value is string =>
      typeof value === "string" && /^\d{4}-\d{2}-\d{2}/.test(value) && !Number.isNaN(Date.parse(value));
    const guestCount = payload.guest_count ?? 1;
    const openedAt = payload.opened_at || new Date().toISOString();
    const closedAtInput = payload.closed_at ?? null;
    const menuItems = payload.menu_items ?? [];
    const tableLabel = freeText(payload.table_label);
    const serverName = freeText(payload.server_name);
    const guestName = freeText(payload.guest_name);
    if (tableLabel === "invalid" || serverName === "invalid" || guestName === "invalid") {
      return jsonResponse({ error: "invalid_check_fields" }, 400);
    }
    if (
      subtotal === null || tax === null || tip === null || total === null ||
      !["open", "closed", "voided"].includes(status) ||
      typeof guestCount !== "number" || !Number.isInteger(guestCount) || guestCount < 0 || guestCount > 100_000 ||
      !isIsoTimestamp(openedAt) ||
      (closedAtInput !== null && !isIsoTimestamp(closedAtInput)) ||
      !Array.isArray(menuItems)
    ) {
      return jsonResponse({ error: "invalid_check_fields" }, 400);
    }

    // A closed/paid check is final: a replayed or late webhook must not rewrite its totals.
    // Redelivery of the same close event is expected, so acknowledge it instead of erroring.
    const { data: existingCheck, error: existingError } = await serviceClient
      .from("pos_checks")
      .select("status, closed_at")
      .eq("venue_id", venueId)
      .eq("provider", "toast")
      .eq("external_check_id", externalCheckId)
      .maybeSingle();
    if (existingError) {
      return jsonResponse({ error: "failed_to_read_check" }, 500);
    }
    // A void that arrives after the close is honoured: it is the refund/cancel of a closed check.
    const isVoidAfterClose = status === "voided" && existingCheck?.status === "closed";
    if (existingCheck && existingCheck.closed_at && existingCheck.status !== "open" && !isVoidAfterClose) {
      return jsonResponse({ ok: true, external_check_id: externalCheckId, ignored: "check_already_closed" });
    }

    // A closed or voided check must carry a close time. Fall back to the stored one (a void
    // may omit it) so a null closed_at is never written for a final check.
    const closedAt = (closedAtInput as string | null) ?? existingCheck?.closed_at ?? null;
    if (status !== "open" && !closedAt) {
      return jsonResponse({ error: "missing_closed_at" }, 400);
    }

    // Idempotent upsert of the check into pos_checks
    const { error: upsertError } = await serviceClient.from("pos_checks").upsert(
      {
        venue_id: venueId,
        provider: "toast",
        external_check_id: externalCheckId,
        table_label: tableLabel,
        server_name: serverName,
        guest_name: guestName,
        guest_count: guestCount,
        opened_at: openedAt,
        closed_at: closedAt,
        subtotal_cents: subtotal,
        tax_cents: tax,
        tip_cents: tip,
        total_cents: total,
        status,
        menu_items: menuItems,
        raw_payload: payload,
        updated_at: new Date().toISOString(),
      },
      { onConflict: "venue_id,provider,external_check_id" }
    );

    if (upsertError) {
      console.error("toast-pos: pos_checks upsert failed", upsertError);
      return jsonResponse({ error: "failed_to_upsert_check" }, 500);
    }

    return jsonResponse({ ok: true, external_check_id: externalCheckId });
  }

  // No verified Toast delivery worker exists for legacy menu commands.
  if (req.method === "POST" && action === "outbound-command") {
    return jsonResponse({ error: "unsupported_capability" }, 501);
  }

  return jsonResponse({ error: "not_found" }, 404);
}

// supabase/functions/toast-pos/index.ts
// Legacy gateway check ingestion. This uses a custom gateway secret, not a
// verified native Toast webhook signature. Outbound menu commands are disabled
// until a provider-approved adapter and delivery worker exist.

import { corsHeaders, handleCorsPreflight } from "../_shared/cors.ts";
import { createServiceClient } from "../_shared/supabase-clients.ts";
import { initObservability, captureException, flushObservability } from "../_shared/observability.ts";
import { sha256Hex } from "../_shared/crypto.ts";

initObservability();

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const MAX_WEBHOOK_BYTES = 256 * 1024;

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
    captureException(error, { function: "toast-pos", url: req.url });
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
    const suppliedSecret = req.headers.get("X-Venue-Webhook-Secret");
    if (!suppliedSecret || suppliedSecret.length < 32 || suppliedSecret.length > 512) {
      return jsonResponse({ error: "unauthorized_webhook" }, 401);
    }
    const contentLength = Number(req.headers.get("content-length") ?? "0");
    if (contentLength > MAX_WEBHOOK_BYTES) {
      return jsonResponse({ error: "payload_too_large" }, 413);
    }
    let payload: Record<string, unknown>;
    try {
      const text = await req.text();
      if (text.length > MAX_WEBHOOK_BYTES) {
        return jsonResponse({ error: "payload_too_large" }, 413);
      }
      payload = JSON.parse(text);
    } catch {
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
    const suppliedHash = await sha256Hex(new TextEncoder().encode(suppliedSecret));
    const expectedHash = connection.webhook_secret_hash.toLowerCase();
    if (!/^[0-9a-f]{64}$/.test(expectedHash)) {
      return jsonResponse({ error: "unauthorized_webhook" }, 401);
    }
    let mismatch = 0;
    for (let i = 0; i < 64; i++) {
      mismatch |= suppliedHash.charCodeAt(i) ^ expectedHash.charCodeAt(i);
    }
    if (mismatch !== 0) {
      return jsonResponse({ error: "unauthorized_webhook" }, 401);
    }

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
    const status = (payload.status as string | undefined) ?? "closed";
    if (
      subtotal === null || tax === null || tip === null || total === null ||
      !["open", "paid", "closed", "void"].includes(status)
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
    if (existingCheck && existingCheck.closed_at && existingCheck.status !== "open") {
      return jsonResponse({ ok: true, external_check_id: externalCheckId, ignored: "check_already_closed" });
    }

    // Idempotent upsert of the check into pos_checks
    const { error: upsertError } = await serviceClient.from("pos_checks").upsert(
      {
        venue_id: venueId,
        provider: "toast",
        external_check_id: externalCheckId,
        table_label: payload.table_label as string | null,
        server_name: payload.server_name as string | null,
        guest_name: payload.guest_name as string | null,
        guest_count: (payload.guest_count as number) ?? 1,
        opened_at: (payload.opened_at as string) || new Date().toISOString(),
        closed_at: payload.closed_at as string | null,
        subtotal_cents: subtotal,
        tax_cents: tax,
        tip_cents: tip,
        total_cents: total,
        status,
        menu_items: payload.menu_items || [],
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

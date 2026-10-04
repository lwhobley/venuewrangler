// supabase/functions/toast-pos/index.ts
// Handles bidirectional Toast POS integration:
// 1. Inbound webhook ingestion: receives POS checks, validates signature/secret, and upserts idempotently.
// 2. Outbound commands: pushes 86'd out-of-stock items, menu item updates, or item voids to Toast POS API.

import { corsHeaders, handleCorsPreflight } from "../_shared/cors.ts";
import { createServiceClient, createUserClient } from "../_shared/supabase-clients.ts";
import { initObservability, captureException, flushObservability } from "../_shared/observability.ts";
import { sha256Hex } from "../_shared/crypto.ts";

initObservability();

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

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
    let payload: Record<string, unknown>;
    try {
      payload = await req.json();
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
        subtotal_cents: (payload.subtotal_cents as number) ?? 0,
        tax_cents: (payload.tax_cents as number) ?? 0,
        tip_cents: (payload.tip_cents as number) ?? 0,
        total_cents: (payload.total_cents as number) ?? 0,
        status: (payload.status as string) || "closed",
        menu_items: payload.menu_items || [],
        raw_payload: payload,
        updated_at: new Date().toISOString(),
      },
      { onConflict: "venue_id,provider,external_check_id" }
    );

    if (upsertError) {
      return jsonResponse({ error: "failed_to_upsert_check", detail: upsertError.message }, 500);
    }

    return jsonResponse({ ok: true, external_check_id: externalCheckId });
  }

  // Outbound 86 item / Command Execution (/toast-pos/outbound-command)
  if (req.method === "POST" && action === "outbound-command") {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
      return jsonResponse({ error: "missing_authorization_header" }, 401);
    }

    let body: {
      venue_id?: string;
      command_type?: string;
      payload?: Record<string, unknown>;
    };

    try {
      body = await req.json();
    } catch {
      return jsonResponse({ error: "invalid_json_body" }, 400);
    }

    const { venue_id, command_type, payload } = body;
    if (!venue_id || !command_type || !payload) {
      return jsonResponse({ error: "missing_required_parameters" }, 400);
    }

    // Verify user authorization with RLS-respecting user client
    const userClient = createUserClient(authHeader);
    const { data: userData, error: userError } = await userClient.auth.getUser();
    if (userError || !userData?.user) {
      return jsonResponse({ error: "invalid_session" }, 401);
    }

    const { data: membership, error: membershipError } = await userClient
      .from("memberships")
      .select("role")
      .eq("venue_id", venue_id)
      .in("role", ["venue_manager", "organization_owner", "organization_admin"])
      .maybeSingle();

    if (membershipError || !membership) {
      return jsonResponse({ error: "forbidden_manager_role_required" }, 403);
    }

    const serviceClient = createServiceClient();

    // Find the active Toast connection for this venue
    const { data: connection, error: connError } = await serviceClient
      .from("pos_connections")
      .select("id, status, credentials_encrypted")
      .eq("venue_id", venue_id)
      .eq("provider", "toast")
      .maybeSingle();

    if (connError || !connection) {
      return jsonResponse({ error: "no_toast_pos_connection_found" }, 404);
    }

    // Enqueue command into pos_outbound_commands queue table
    const { data: queuedCommand, error: queueError } = await serviceClient
      .from("pos_outbound_commands")
      .insert({
        venue_id,
        pos_connection_id: connection.id,
        provider: "toast",
        command_type,
        payload,
        status: "pending",
      })
      .select()
      .single();

    if (queueError) {
      return jsonResponse({ error: "failed_to_queue_command", detail: queueError.message }, 500);
    }

    return jsonResponse({
      ok: true,
      message: "outbound_command_queued",
      command: queuedCommand,
    });
  }

  return jsonResponse({ error: "not_found" }, 404);
}

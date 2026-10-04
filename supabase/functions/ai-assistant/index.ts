// AI assistant Edge Function (Groq-backed). Covers staff_import_parse, inventory_parse,
// scheduling_suggestion, and wrangler_ask (see prompts.ts). Every request is scoped to a
// venue the caller is actually a member of (checked via the caller's own RLS-respecting
// client — never trusted from the request body), budget-gated against a per-organization
// monthly cap using a reserve/commit/release pattern so concurrent requests can't jointly
// overspend, and logged to ai_usage_events for audit.
import { corsHeaders, handleCorsPreflight } from "../_shared/cors.ts";
import { createServiceClient, createUserClient } from "../_shared/supabase-clients.ts";
import { callGroqJson, estimateInputTokens, pricingFor } from "../_shared/groq.ts";
import { systemPromptFor, TASK_TYPES, type TaskType } from "./prompts.ts";
import { initObservability, captureException, flushObservability } from "../_shared/observability.ts";

initObservability();

const MAX_INPUT_CHARS = 20_000;
const RATE_LIMIT_MAX_CALLS = 20;
const RATE_LIMIT_WINDOW_MINUTES = 10;

Deno.serve(async (req) => {
  const preflight = handleCorsPreflight(req);
  if (preflight) return preflight;

  // Echoed back on every response (and included in server-side logs) so a client-side trace
  // can be joined with this function's logs for one request, per the convention noted in
  // apps/mobile/lib/core/errors/error_reporter.dart's newCorrelationId(). The client always
  // sends one; a fallback is generated here only for calls made outside the app (curl, etc).
  const correlationId = req.headers.get("X-Correlation-Id") ?? crypto.randomUUID();

  function jsonResponse(body: Record<string, unknown>, status = 200): Response {
    return new Response(JSON.stringify({ ...body, correlation_id: correlationId }), {
      status,
      headers: {
        ...corsHeaders,
        "Content-Type": "application/json",
        "X-Correlation-Id": correlationId,
      },
    });
  }

  try {
    return await handleRequest(req, jsonResponse, correlationId);
  } catch (error) {
    console.error(`[${correlationId}]`, "unexpected error", error);
    captureException(error, { function: "ai-assistant", url: req.url, correlation_id: correlationId });
    await flushObservability();
    return jsonResponse({ error: "internal_error" }, 500);
  }
});

async function handleRequest(
  req: Request,
  jsonResponse: (body: Record<string, unknown>, status?: number) => Response,
  correlationId: string,
): Promise<Response> {
  if (req.method !== "POST") {
    return jsonResponse({ error: "method_not_allowed" }, 405);
  }

  const authHeader = req.headers.get("Authorization");
  if (!authHeader) {
    return jsonResponse({ error: "missing_authorization_header" }, 401);
  }

  let payload: {
    task?: string;
    venue_id?: string;
    input?: string;
    max_output_tokens?: number;
  };
  try {
    payload = await req.json();
  } catch {
    return jsonResponse({ error: "invalid_json_body" }, 400);
  }

  const { task, venue_id, input } = payload;

  if (!task || !TASK_TYPES.includes(task as TaskType)) {
    return jsonResponse(
      { error: "invalid_task", allowed_tasks: TASK_TYPES },
      400,
    );
  }
  if (!venue_id || typeof venue_id !== "string") {
    return jsonResponse({ error: "missing_venue_id" }, 400);
  }
  if (!input || typeof input !== "string" || input.trim().length === 0) {
    return jsonResponse({ error: "missing_input" }, 400);
  }
  if (input.length > MAX_INPUT_CHARS) {
    return jsonResponse(
      { error: "input_too_large", max_chars: MAX_INPUT_CHARS },
      400,
    );
  }

  const userClient = createUserClient(authHeader);
  const { data: userData, error: userError } = await userClient.auth.getUser();
  if (userError || !userData?.user) {
    return jsonResponse({ error: "invalid_or_expired_session" }, 401);
  }
  const userId = userData.user.id;

  // Derive organization_id from the venue the caller actually belongs to — RLS
  // (venues_select_members) returns this row only if the caller has a membership on it, so a
  // non-empty result IS the membership check. The client-supplied venue_id is never trusted
  // beyond "which row to look up."
  const { data: venue, error: venueError } = await userClient
    .from("venues")
    .select("id, organization_id")
    .eq("id", venue_id)
    .maybeSingle();

  if (venueError) {
    console.error(`[${correlationId}]`, "venue lookup failed", venueError);
    return jsonResponse({ error: "venue_lookup_failed" }, 500);
  }
  if (!venue) {
    return jsonResponse({ error: "venue_not_found_or_not_a_member" }, 403);
  }
  const organizationId = venue.organization_id as string;

  const serviceClient = createServiceClient();

  const model = Deno.env.get("GROQ_MODEL") ?? "openai/gpt-oss-120b";
  const apiKey = Deno.env.get("GROQ_API_KEY");
  if (!apiKey) {
    console.error(`[${correlationId}]`, "GROQ_API_KEY is not configured");
    return jsonResponse({ error: "ai_provider_not_configured" }, 500);
  }
  const pricing = pricingFor(model);

  const configuredMaxOutputTokens = parseInt(
    Deno.env.get("AI_MAX_OUTPUT_TOKENS") ?? "2048",
    10,
  );
  const maxOutputTokens = Math.min(
    payload.max_output_tokens && payload.max_output_tokens > 0
      ? payload.max_output_tokens
      : configuredMaxOutputTokens,
    configuredMaxOutputTokens,
  );

  const systemPrompt = systemPromptFor(task as TaskType);
  const estimatedInputTokens = estimateInputTokens(systemPrompt + input);
  const estimatedCost =
    estimatedInputTokens * pricing.input + maxOutputTokens * pricing.output;

  const monthlyBudget = parseFloat(
    Deno.env.get("AI_MONTHLY_ORG_BUDGET_USD") ?? "10",
  );
  const reservationTtlSeconds = parseInt(
    Deno.env.get("AI_BUDGET_RESERVATION_TTL_SECONDS") ?? "120",
    10,
  );
  // Atomic check-and-reserve: one RPC holds a per-org advisory lock, verifies budget
  // + rate limit (including in-flight reservations), and inserts the reservation.
  // Never check-then-insert in two round trips — concurrent requests would overspend.
  const { data: reservationId, error: reservationError } = await serviceClient.rpc(
    "reserve_ai_budget",
    {
      p_org_id: organizationId,
      p_user_id: userId,
      p_estimated_usd: estimatedCost,
      p_monthly_budget_usd: monthlyBudget,
      p_rate_limit_max: RATE_LIMIT_MAX_CALLS,
      p_rate_limit_window_minutes: RATE_LIMIT_WINDOW_MINUTES,
      p_ttl_seconds: reservationTtlSeconds,
    },
  );

  if (reservationError) {
    const msg = (reservationError as { message?: string }).message ?? "";
    if (msg.includes("monthly_budget_exceeded")) {
      const { data: currentSpend } = await serviceClient.rpc(
        "ai_org_spend_this_month",
        { p_org_id: organizationId },
      );
      return jsonResponse(
        {
          error: "monthly_budget_exceeded",
          monthly_budget_usd: monthlyBudget,
          current_spend_usd: currentSpend ?? 0,
        },
        402,
      );
    }
    if (msg.includes("rate_limited")) {
      return jsonResponse(
        {
          error: "rate_limited",
          max_calls: RATE_LIMIT_MAX_CALLS,
          window_minutes: RATE_LIMIT_WINDOW_MINUTES,
        },
        429,
      );
    }
    console.error(`[${correlationId}]`, "reservation failed", reservationError);
    return jsonResponse({ error: "budget_reservation_failed" }, 500);
  }

  async function releaseReservation() {
    const { error } = await serviceClient
      .from("ai_budget_reservations")
      .update({ status: "released" })
      .eq("id", reservationId);
    if (error) console.error(`[${correlationId}]`, "failed to release reservation", error);
  }

  let groqResult;
  try {
    groqResult = await callGroqJson({
      apiKey,
      model,
      systemPrompt,
      userPrompt: input,
      maxOutputTokens,
    });
  } catch (err) {
    console.error(`[${correlationId}]`, "Groq call failed", err);
    await releaseReservation();
    return jsonResponse({ error: "ai_provider_call_failed" }, 502);
  }

  let parsedResult: unknown;
  try {
    parsedResult = JSON.parse(groqResult.content);
  } catch (err) {
    console.error(`[${correlationId}]`, "Groq response was not valid JSON", err, groqResult.content);
    await releaseReservation();
    return jsonResponse({ error: "ai_response_not_valid_json" }, 502);
  }

  const actualCost =
    groqResult.promptTokens * pricing.input +
    groqResult.completionTokens * pricing.output;

  const { error: commitError } = await serviceClient
    .from("ai_budget_reservations")
    .update({ status: "committed" })
    .eq("id", reservationId);
  if (commitError) console.error(`[${correlationId}]`, "failed to commit reservation", commitError);

  const { error: usageInsertError } = await serviceClient
    .from("ai_usage_events")
    .insert({
      organization_id: organizationId,
      venue_id: venue_id,
      user_id: userId,
      task,
      model,
      input_tokens: groqResult.promptTokens,
      output_tokens: groqResult.completionTokens,
      cost_usd: actualCost,
    });
  if (usageInsertError) {
    console.error(`[${correlationId}]`, "failed to record usage event", usageInsertError);
  }

  return jsonResponse({
    task,
    result: parsedResult,
    usage: {
      input_tokens: groqResult.promptTokens,
      output_tokens: groqResult.completionTokens,
    },
    cost_usd: actualCost,
  });
}

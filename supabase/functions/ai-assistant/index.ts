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

const MAX_INPUT_CHARS = 20_000;
const RATE_LIMIT_MAX_CALLS = 20;
const RATE_LIMIT_WINDOW_MINUTES = 10;

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

Deno.serve(async (req) => {
  const preflight = handleCorsPreflight(req);
  if (preflight) return preflight;

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
    console.error("venue lookup failed", venueError);
    return jsonResponse({ error: "venue_lookup_failed" }, 500);
  }
  if (!venue) {
    return jsonResponse({ error: "venue_not_found_or_not_a_member" }, 403);
  }
  const organizationId = venue.organization_id as string;

  const serviceClient = createServiceClient();

  const windowStart = new Date(
    Date.now() - RATE_LIMIT_WINDOW_MINUTES * 60_000,
  ).toISOString();
  const { count: recentCallCount, error: rateLimitError } = await serviceClient
    .from("ai_usage_events")
    .select("id", { count: "exact", head: true })
    .eq("user_id", userId)
    .gte("created_at", windowStart);

  if (rateLimitError) {
    console.error("rate limit check failed", rateLimitError);
    return jsonResponse({ error: "rate_limit_check_failed" }, 500);
  }
  if ((recentCallCount ?? 0) >= RATE_LIMIT_MAX_CALLS) {
    return jsonResponse(
      {
        error: "rate_limited",
        max_calls: RATE_LIMIT_MAX_CALLS,
        window_minutes: RATE_LIMIT_WINDOW_MINUTES,
      },
      429,
    );
  }

  const model = Deno.env.get("GROQ_MODEL") ?? "openai/gpt-oss-120b";
  const apiKey = Deno.env.get("GROQ_API_KEY");
  if (!apiKey) {
    console.error("GROQ_API_KEY is not configured");
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
  const { data: currentSpend, error: spendError } = await serviceClient.rpc(
    "ai_org_spend_this_month",
    { p_org_id: organizationId },
  );
  if (spendError) {
    console.error("spend lookup failed", spendError);
    return jsonResponse({ error: "budget_check_failed" }, 500);
  }
  if ((currentSpend ?? 0) + estimatedCost > monthlyBudget) {
    return jsonResponse(
      {
        error: "monthly_budget_exceeded",
        monthly_budget_usd: monthlyBudget,
        current_spend_usd: currentSpend,
      },
      402,
    );
  }

  const reservationTtlSeconds = parseInt(
    Deno.env.get("AI_BUDGET_RESERVATION_TTL_SECONDS") ?? "120",
    10,
  );
  const { data: reservation, error: reservationError } = await serviceClient
    .from("ai_budget_reservations")
    .insert({
      organization_id: organizationId,
      reserved_usd: estimatedCost,
      status: "pending",
      expires_at: new Date(
        Date.now() + reservationTtlSeconds * 1000,
      ).toISOString(),
    })
    .select("id")
    .single();

  if (reservationError || !reservation) {
    console.error("reservation insert failed", reservationError);
    return jsonResponse({ error: "budget_reservation_failed" }, 500);
  }
  const reservationId = reservation.id as string;

  async function releaseReservation() {
    const { error } = await serviceClient
      .from("ai_budget_reservations")
      .update({ status: "released" })
      .eq("id", reservationId);
    if (error) console.error("failed to release reservation", error);
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
    console.error("Groq call failed", err);
    await releaseReservation();
    return jsonResponse({ error: "ai_provider_call_failed" }, 502);
  }

  let parsedResult: unknown;
  try {
    parsedResult = JSON.parse(groqResult.content);
  } catch (err) {
    console.error("Groq response was not valid JSON", err, groqResult.content);
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
  if (commitError) console.error("failed to commit reservation", commitError);

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
    console.error("failed to record usage event", usageInsertError);
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
});

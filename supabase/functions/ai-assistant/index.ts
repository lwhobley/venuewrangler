// AI assistant Edge Function (Groq-backed). Covers staff_import_parse, inventory_parse,
// scheduling_suggestion, and wrangler_ask (see prompts.ts). Every request is scoped to a
// venue the caller is actually a member of (checked via the caller's own RLS-respecting
// client — never trusted from the request body), budget-gated against a per-organization
// monthly cap using a reserve/commit/release pattern so concurrent requests can't jointly
// overspend, and logged to ai_usage_events for audit.
import { corsHeaders, handleCorsPreflight } from "../_shared/cors.ts";
import { createServiceClient, createUserClient } from "../_shared/supabase-clients.ts";
import {
  callGroqJson,
  DEFAULT_GROQ_TIMEOUT_MS,
  estimateInputTokens,
  GroqCallError,
  pricingFor,
} from "../_shared/groq.ts";
import { checkEntitlement } from "../_shared/rate-limit.ts";
import { systemPromptFor, TASK_TYPES, type TaskType } from "./prompts.ts";
import { initObservability, captureException, flushObservability } from "../_shared/observability.ts";

initObservability();

const MAX_INPUT_CHARS = 20_000;
const RATE_LIMIT_MAX_CALLS = 20;
const RATE_LIMIT_WINDOW_MINUTES = 10;
// Headroom between the Groq timeout and the reservation TTL: the provider call must always
// finish (or abort) before its budget reservation expires.
const RESERVATION_TTL_MARGIN_MS = 10_000;

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
    captureException(error, { function: "ai-assistant", path: new URL(req.url).pathname, correlation_id: correlationId });
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

  // Global kill switch (audit AI-01): set AI_DISABLED=true to stop all AI spend instantly.
  if ((Deno.env.get("AI_DISABLED") ?? "").trim().toLowerCase() === "true") {
    return jsonResponse({ error: "ai_unavailable" }, 503);
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
  if (!venue_id || typeof venue_id !== "string" ||
    !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(venue_id)) {
    return jsonResponse({ error: "invalid_venue_id" }, 400);
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

  // These actions lead to manager-only writes or operate on manager-only
  // roster/inventory data. Reject before reserving and spending AI budget.
  if (task !== "wrangler_ask") {
    const { data: memberships, error: membershipError } = await userClient
      .from("memberships")
      .select("venue_id,role")
      .eq("user_id", userId)
      .eq("organization_id", organizationId);
    if (membershipError) {
      return jsonResponse({ error: "membership_lookup_failed" }, 500);
    }
    const canManage = (memberships ?? []).some((membership) =>
      (membership.venue_id === venue_id && membership.role === "venue_manager") ||
      (membership.venue_id === null &&
        ["organization_owner", "organization_admin"].includes(membership.role))
    );
    if (!canManage) {
      return jsonResponse({ error: "manager_permission_required" }, 403);
    }
  }

  const serviceClient = createServiceClient();

  // Org-level AI opt-in (audit AI-02). Read with the service client; fails closed if the
  // setting cannot be read.
  const { data: orgSettings, error: orgSettingsError } = await serviceClient
    .from("organizations")
    .select("ai_enabled")
    .eq("id", organizationId)
    .maybeSingle();
  if (orgSettingsError || !orgSettings) {
    console.error(`[${correlationId}]`, "organization AI settings lookup failed", orgSettingsError);
    return jsonResponse({ error: "ai_settings_unavailable" }, 503);
  }
  if (orgSettings.ai_enabled !== true) {
    return jsonResponse({ error: "ai_disabled_for_org" }, 403);
  }

  // Paywall enforcement (audit B-02): unentitled organizations get no AI spend.
  const entitlement = await checkEntitlement(serviceClient, organizationId);
  if (entitlement === "not_entitled") {
    return jsonResponse({ error: "subscription_required" }, 402);
  }
  if (entitlement === "unavailable") {
    return jsonResponse({ error: "entitlement_check_failed" }, 503);
  }

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
  // Token limits must be whole numbers in [1, configured cap]; a fractional or out-of-range
  // value is rejected here, before any budget reservation is taken.
  const requestedMaxOutputTokens = payload.max_output_tokens;
  if (
    requestedMaxOutputTokens !== undefined && requestedMaxOutputTokens !== null &&
    (!Number.isInteger(requestedMaxOutputTokens) || requestedMaxOutputTokens < 1 ||
      requestedMaxOutputTokens > configuredMaxOutputTokens)
  ) {
    return jsonResponse({ error: "invalid_max_output_tokens" }, 400);
  }
  const maxOutputTokens = requestedMaxOutputTokens ?? configuredMaxOutputTokens;

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
  // Provider timeout: GROQ_TIMEOUT_MS (default 60s), always clamped below the reservation TTL.
  const configuredTimeoutMs = parseInt(Deno.env.get("GROQ_TIMEOUT_MS") ?? "", 10);
  const requestedTimeoutMs = Number.isFinite(configuredTimeoutMs) && configuredTimeoutMs > 0
    ? configuredTimeoutMs
    : DEFAULT_GROQ_TIMEOUT_MS;
  const groqTimeoutMs = Math.max(
    1_000,
    Math.min(requestedTimeoutMs, reservationTtlSeconds * 1000 - RESERVATION_TTL_MARGIN_MS),
  );

  // Per-user monthly cap (audit AI-04): one staff member cannot exhaust the org's budget.
  // Counts this user's committed spend in this org for the current UTC month
  // (ai_usage_events.user_id exists, see 20261002171532_ai_usage.sql).
  const monthlyUserBudget = parseFloat(Deno.env.get("AI_MONTHLY_USER_BUDGET_USD") ?? "3");
  if (Number.isFinite(monthlyUserBudget) && monthlyUserBudget > 0) {
    const now = new Date();
    const monthStart = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), 1)).toISOString();
    let userSpend = 0;
    const pageSize = 1000;
    for (let page = 0; page < 20; page++) {
      const { data: rows, error: spendError } = await serviceClient
        .from("ai_usage_events")
        .select("cost_usd")
        .eq("organization_id", organizationId)
        .eq("user_id", userId)
        .gte("created_at", monthStart)
        .order("created_at", { ascending: true })
        .range(page * pageSize, page * pageSize + pageSize - 1);
      if (spendError) {
        console.error(`[${correlationId}]`, "user spend lookup failed", spendError);
        return jsonResponse({ error: "budget_reservation_failed" }, 500);
      }
      for (const row of rows ?? []) userSpend += Number(row.cost_usd) || 0;
      if (!rows || rows.length < pageSize) break;
    }
    if (userSpend + estimatedCost > monthlyUserBudget) {
      return jsonResponse(
        {
          error: "monthly_user_budget_exceeded",
          monthly_user_budget_usd: monthlyUserBudget,
          current_user_spend_usd: userSpend,
        },
        402,
      );
    }
  }
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

  // Bills the reservation with what the provider actually consumed. Used on failure paths that
  // still cost money (truncated or non-JSON output, provider errors carrying usage) so they are
  // metered instead of released for free (audit B-03). Never throws.
  async function commitUsage(promptTokens: number, completionTokens: number): Promise<boolean> {
    const cost = promptTokens * pricing.input + completionTokens * pricing.output;
    const { error } = await serviceClient.rpc("commit_ai_reservation", {
      p_reservation_id: reservationId,
      p_organization_id: organizationId,
      p_venue_id: venue_id,
      p_user_id: userId,
      p_task: task,
      p_model: model,
      p_input_tokens: promptTokens,
      p_output_tokens: completionTokens,
      p_cost_usd: cost,
    });
    if (error) {
      console.error(`[${correlationId}]`, "AI usage accounting failed", error);
      return false;
    }
    return true;
  }

  let groqResult;
  try {
    groqResult = await callGroqJson({
      apiKey,
      model,
      systemPrompt,
      userPrompt: input,
      maxOutputTokens,
      timeoutMs: groqTimeoutMs,
    });
  } catch (err) {
    console.error(`[${correlationId}]`, "Groq call failed", err);
    if (err instanceof GroqCallError && err.usage) {
      await commitUsage(err.usage.promptTokens, err.usage.completionTokens);
    } else {
      // No usage reported (network error, timeout, plain HTTP error): nothing known to bill.
      await releaseReservation();
    }
    return jsonResponse({ error: "ai_provider_call_failed" }, 502);
  }

  // A completion that produced output but cannot be used is still a billed failure. If the
  // provider omitted usage, fall back to the pre-call estimate so it is never free.
  const billedPrompt = groqResult.promptTokens > 0 ? groqResult.promptTokens : estimatedInputTokens;

  if (groqResult.finishReason === "length") {
    console.error(`[${correlationId}]`, "Groq response truncated at max_output_tokens");
    await commitUsage(
      billedPrompt,
      groqResult.completionTokens > 0 ? groqResult.completionTokens : maxOutputTokens,
    );
    return jsonResponse({ error: "ai_response_truncated" }, 502);
  }

  let parsedResult: unknown;
  try {
    parsedResult = JSON.parse(groqResult.content);
  } catch (err) {
    console.error(`[${correlationId}]`, "Groq response was not valid JSON", err);
    await commitUsage(
      billedPrompt,
      groqResult.completionTokens > 0
        ? groqResult.completionTokens
        : Math.min(maxOutputTokens, estimateInputTokens(groqResult.content)),
    );
    return jsonResponse({ error: "ai_response_not_valid_json" }, 502);
  }

  const actualCost =
    groqResult.promptTokens * pricing.input +
    groqResult.completionTokens * pricing.output;

  if (!await commitUsage(groqResult.promptTokens, groqResult.completionTokens)) {
    return jsonResponse({ error: "ai_usage_accounting_failed", correlation_id: correlationId }, 503);
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

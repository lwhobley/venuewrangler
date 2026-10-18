// Generic fixed-window rate limiting and billing-entitlement helpers for Edge Functions.
//
// Both wrap service_role-only SQL functions (public.consume_rate_limit and
// public.org_is_entitled). Call them with the SERVICE client, never a user client.
//
// Failure policy when the RPC itself is unavailable (not deployed yet, or the database is
// unreachable) is chosen per call site:
//  - failOpen: true  -> low-risk endpoints keep working; the error is logged.
//  - failOpen: false -> sensitive sends (e.g. outbound email) are refused with 503.
import type { SupabaseClient } from "@supabase/supabase-js";
import { corsHeaders } from "./cors.ts";

type RpcError = { code?: string; message?: string } | null;

function jsonError(body: Record<string, unknown>, status: number, extra?: Record<string, string>) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json", ...extra },
  });
}

// 42883 = undefined_function (Postgres); PGRST202 = PostgREST "function not found in schema
// cache", which is what supabase-js actually surfaces for a missing RPC.
export function isMissingFunctionError(error: RpcError): boolean {
  if (!error) return false;
  return error.code === "42883" || error.code === "PGRST202" ||
    /function .* does not exist|could not find the function/i.test(error.message ?? "");
}

const warned = new Set<string>();
function warnOnce(tag: string, detail: unknown) {
  if (warned.has(tag)) return;
  warned.add(tag);
  console.error(`rate-limit: ${tag}`, detail);
}

export interface RateLimitOptions {
  /** Allow the request through when the limiter RPC fails. Default false. */
  failOpen?: boolean;
}

/**
 * Atomically counts one hit against `key`. Returns null when the request may proceed, or a
 * ready-to-return 429 (rate_limited) / 503 (limiter unavailable and not failOpen) Response.
 */
export async function enforceRateLimit(
  serviceClient: SupabaseClient,
  key: string,
  max: number,
  windowSeconds: number,
  opts: RateLimitOptions = {},
): Promise<Response | null> {
  const { data, error } = await serviceClient.rpc("consume_rate_limit", {
    p_key: key,
    p_max: max,
    p_window_seconds: windowSeconds,
  });
  if (error) {
    if (opts.failOpen) {
      warnOnce("consume_rate_limit failed; failing open", error);
      return null;
    }
    console.error("rate-limit: consume_rate_limit failed; failing closed", error);
    return jsonError({ error: "rate_limit_unavailable" }, 503);
  }
  if (data === false) {
    return jsonError({ error: "rate_limited" }, 429, {
      "Retry-After": String(Math.min(windowSeconds, 3600)),
    });
  }
  return null;
}

export type EntitlementResult = "entitled" | "not_entitled" | "unavailable";

/**
 * Raw entitlement check. A missing org_is_entitled function (migration not yet applied)
 * fails OPEN ("entitled", logged once); any other RPC error is "unavailable" (caller should
 * fail closed with 503).
 */
export async function checkEntitlement(
  serviceClient: SupabaseClient,
  organizationId: string,
): Promise<EntitlementResult> {
  const { data, error } = await serviceClient.rpc("org_is_entitled", {
    p_organization_id: organizationId,
  });
  if (error) {
    if (isMissingFunctionError(error)) {
      warnOnce("org_is_entitled is not deployed; failing open", error);
      return "entitled";
    }
    console.error("rate-limit: org_is_entitled failed", error);
    return "unavailable";
  }
  return data === true ? "entitled" : "not_entitled";
}

/** Billing gate. Null when allowed, otherwise a 402 (subscription_required) or 503 Response. */
export async function requireEntitlement(
  serviceClient: SupabaseClient,
  organizationId: string,
): Promise<Response | null> {
  const result = await checkEntitlement(serviceClient, organizationId);
  if (result === "entitled") return null;
  if (result === "not_entitled") return jsonError({ error: "subscription_required" }, 402);
  return jsonError({ error: "entitlement_check_failed" }, 503);
}

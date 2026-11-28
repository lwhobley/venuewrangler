// MFA step-up gate for sensitive operations (audit F04): billing (Stripe checkout/portal) and
// connecting or disconnecting payroll/HR integrations.
//
// Wraps public.caller_mfa_satisfied(), which is granted to `authenticated` and returns
// app_hidden.mfa_satisfied(): true unless the platform setting require_mfa_for_admin_actions is
// on, in which case the caller's JWT `aal` must be `aal2`. It reads the caller's own JWT, so it
// MUST be called through the caller's user client (createUserClient(authHeader)), never the
// service client. Call it after the endpoint's own auth and role checks.
//
// Failure policy:
//  - false                     -> 403 {error: "mfa_required"}; the app prompts for a step-up.
//  - RPC missing or any other
//    RPC error                 -> 503 {error: "mfa_check_unavailable"} (fail closed). The RPC
//                                 ships in migration 20261125120000, applied in production, so a
//                                 missing function now means a broken deploy, not a race
//                                 (review E04; this used to fail open).
import type { SupabaseClient } from "@supabase/supabase-js";
import { corsHeaders } from "./cors.ts";

export type MfaCheck = "satisfied" | "required" | "unavailable";

type RpcClient = Pick<SupabaseClient, "rpc">;

/** Raw check through the caller's user client. Never throws. */
export async function checkCallerMfa(userClient: RpcClient): Promise<MfaCheck> {
  let result: { data: unknown; error: { code?: string; message?: string } | null };
  try {
    result = await userClient.rpc("caller_mfa_satisfied");
  } catch (error) {
    console.error("mfa: caller_mfa_satisfied threw", error);
    return "unavailable";
  }
  const { data, error } = result;
  if (error) {
    console.error("mfa: caller_mfa_satisfied failed", error);
    return "unavailable";
  }
  return data === false ? "required" : data === true ? "satisfied" : "unavailable";
}

/**
 * Step-up gate. Null when the caller may proceed, otherwise a ready-to-return 403
 * (mfa_required) or 503 (mfa_check_unavailable) JSON Response.
 */
export async function requireCallerMfa(userClient: RpcClient): Promise<Response | null> {
  const result = await checkCallerMfa(userClient);
  if (result === "satisfied") return null;
  const [body, status] = result === "required"
    ? [{ error: "mfa_required" }, 403]
    : [{ error: "mfa_check_unavailable" }, 503];
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

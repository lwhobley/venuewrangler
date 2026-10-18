import type { SupabaseClient } from "@supabase/supabase-js";
import {
  checkEntitlement,
  enforceRateLimit,
  isMissingFunctionError,
  requireEntitlement,
} from "./rate-limit.ts";

type RpcResult = { data: unknown; error: { code?: string; message?: string } | null };

function fakeClient(handler: (fn: string, args: Record<string, unknown>) => RpcResult) {
  const calls: { fn: string; args: Record<string, unknown> }[] = [];
  const client = {
    rpc(fn: string, args: Record<string, unknown>) {
      calls.push({ fn, args });
      return Promise.resolve(handler(fn, args));
    },
  } as unknown as SupabaseClient;
  return { client, calls };
}

function status(response: Response | null): number | null {
  return response ? response.status : null;
}

Deno.test("enforceRateLimit allows when the limiter says true and passes the contract args", async () => {
  const { client, calls } = fakeClient(() => ({ data: true, error: null }));
  if (await enforceRateLimit(client, "k", 5, 60) !== null) throw new Error("allowed call blocked");
  const call = calls[0];
  if (call.fn !== "consume_rate_limit" || call.args.p_key !== "k" || call.args.p_max !== 5 ||
    call.args.p_window_seconds !== 60) {
    throw new Error(`unexpected rpc call ${JSON.stringify(call)}`);
  }
});

Deno.test("enforceRateLimit answers 429 rate_limited when the limiter says false", async () => {
  const { client } = fakeClient(() => ({ data: false, error: null }));
  const response = await enforceRateLimit(client, "k", 5, 60);
  if (status(response) !== 429) throw new Error("expected 429");
  if ((await response!.json()).error !== "rate_limited") throw new Error("wrong error body");
  if (!response!.headers.get("Retry-After")) throw new Error("missing Retry-After");
});

Deno.test("enforceRateLimit honours failOpen when the RPC errors", async () => {
  const { client } = fakeClient(() => ({
    data: null,
    error: { code: "42883", message: "function public.consume_rate_limit does not exist" },
  }));
  if (await enforceRateLimit(client, "k", 5, 60, { failOpen: true }) !== null) {
    throw new Error("failOpen should allow");
  }
  const closed = await enforceRateLimit(client, "k", 5, 60, { failOpen: false });
  if (status(closed) !== 503) throw new Error("fail-closed should answer 503");
});

Deno.test("isMissingFunctionError recognises Postgres and PostgREST codes", () => {
  if (!isMissingFunctionError({ code: "42883" })) throw new Error("42883");
  if (!isMissingFunctionError({ code: "PGRST202" })) throw new Error("PGRST202");
  if (isMissingFunctionError({ code: "XX000", message: "boom" })) throw new Error("false positive");
  if (isMissingFunctionError(null)) throw new Error("null");
});

Deno.test("entitlement: entitled, not entitled, missing function (fail open), other error", async () => {
  const org = "11111111-1111-1111-1111-111111111111";
  const entitled = fakeClient(() => ({ data: true, error: null }));
  if (await requireEntitlement(entitled.client, org) !== null) throw new Error("entitled blocked");
  if (entitled.calls[0].args.p_organization_id !== org) throw new Error("wrong rpc arg");

  const denied = fakeClient(() => ({ data: false, error: null }));
  const deniedResponse = await requireEntitlement(denied.client, org);
  if (status(deniedResponse) !== 402) throw new Error("expected 402");
  if ((await deniedResponse!.json()).error !== "subscription_required") throw new Error("body");

  const missing = fakeClient(() => ({ data: null, error: { code: "42883", message: "nope" } }));
  if (await checkEntitlement(missing.client, org) !== "entitled") {
    throw new Error("missing org_is_entitled should fail open");
  }

  const broken = fakeClient(() => ({ data: null, error: { code: "XX000", message: "db down" } }));
  if (await checkEntitlement(broken.client, org) !== "unavailable") throw new Error("expected unavailable");
  if (status(await requireEntitlement(broken.client, org)) !== 503) throw new Error("expected 503");
});

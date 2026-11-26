import type { SupabaseClient } from "@supabase/supabase-js";
import { checkCallerMfa, requireCallerMfa } from "./mfa.ts";

type RpcResult = { data: unknown; error: { code?: string; message?: string } | null };

function fakeClient(result: RpcResult | (() => never)) {
  const calls: { fn: string; args: unknown }[] = [];
  const client = {
    rpc(fn: string, args?: unknown) {
      calls.push({ fn, args });
      if (typeof result === "function") return Promise.resolve().then(result);
      return Promise.resolve(result);
    },
  } as unknown as Pick<SupabaseClient, "rpc">;
  return { client, calls };
}

Deno.test("requireCallerMfa allows when caller_mfa_satisfied returns true", async () => {
  const { client, calls } = fakeClient({ data: true, error: null });
  if (await requireCallerMfa(client) !== null) throw new Error("satisfied caller was blocked");
  if (calls.length !== 1 || calls[0].fn !== "caller_mfa_satisfied") {
    throw new Error(`unexpected rpc calls ${JSON.stringify(calls)}`);
  }
});

Deno.test("requireCallerMfa answers 403 mfa_required when the RPC returns false", async () => {
  const { client } = fakeClient({ data: false, error: null });
  const response = await requireCallerMfa(client);
  if (response?.status !== 403) throw new Error(`expected 403, got ${response?.status}`);
  if ((await response.json()).error !== "mfa_required") throw new Error("wrong error body");
  if (response.headers.get("Content-Type") !== "application/json") throw new Error("not JSON");
});

Deno.test("requireCallerMfa fails open when the RPC is not deployed yet", async () => {
  for (const error of [
    { code: "PGRST202", message: "Could not find the function public.caller_mfa_satisfied" },
    { code: "42883", message: "function public.caller_mfa_satisfied() does not exist" },
  ]) {
    const { client } = fakeClient({ data: null, error });
    if (await requireCallerMfa(client) !== null) throw new Error(`missing RPC (${error.code}) blocked`);
  }
});

Deno.test("requireCallerMfa answers 503 on any other RPC error", async () => {
  const { client } = fakeClient({ data: null, error: { code: "57014", message: "statement timeout" } });
  const response = await requireCallerMfa(client);
  if (response?.status !== 503) throw new Error(`expected 503, got ${response?.status}`);
  if ((await response.json()).error !== "mfa_check_unavailable") throw new Error("wrong error body");
});

Deno.test("checkCallerMfa treats a thrown RPC or a non-boolean answer as unavailable", async () => {
  const thrown = fakeClient(() => {
    throw new TypeError("fetch failed");
  });
  if (await checkCallerMfa(thrown.client) !== "unavailable") throw new Error("thrown RPC not unavailable");
  const odd = fakeClient({ data: null, error: null });
  if (await checkCallerMfa(odd.client) !== "unavailable") throw new Error("null answer not unavailable");
});

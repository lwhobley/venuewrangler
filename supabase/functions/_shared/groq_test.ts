import { callGroqJson, extractGroqUsage, GroqCallError } from "./groq.ts";

const base = {
  apiKey: "test-key",
  model: "openai/gpt-oss-120b",
  systemPrompt: "s",
  userPrompt: "u",
  maxOutputTokens: 10,
};

async function withFetch<T>(
  impl: (input: RequestInfo | URL, init?: RequestInit) => Promise<Response>,
  body: () => Promise<T>,
): Promise<T> {
  const original = globalThis.fetch;
  globalThis.fetch = impl as typeof fetch;
  try {
    return await body();
  } finally {
    globalThis.fetch = original;
  }
}

Deno.test("extractGroqUsage reads top-level and nested error usage", () => {
  const top = extractGroqUsage({ usage: { prompt_tokens: 7, completion_tokens: 3 } });
  if (top?.promptTokens !== 7 || top.completionTokens !== 3) throw new Error("top-level usage");
  const nested = extractGroqUsage({ error: { usage: { prompt_tokens: 5, completion_tokens: 0 } } });
  if (nested?.promptTokens !== 5) throw new Error("nested usage");
  if (extractGroqUsage({ error: { message: "x" } }) !== null) throw new Error("phantom usage");
  if (extractGroqUsage("nope") !== null) throw new Error("non-object");
});

Deno.test("callGroqJson sends an abort signal and surfaces finish_reason", async () => {
  let sawSignal = false;
  const result = await withFetch(
    (_input, init) => {
      sawSignal = init?.signal instanceof AbortSignal;
      return Promise.resolve(
        new Response(JSON.stringify({
          choices: [{ message: { content: "{\"a\":1" }, finish_reason: "length" }],
          usage: { prompt_tokens: 12, completion_tokens: 10 },
        })),
      );
    },
    () => callGroqJson({ ...base, timeoutMs: 5000 }),
  );
  if (!sawSignal) throw new Error("Groq fetch has no timeout signal");
  if (result.finishReason !== "length" || result.completionTokens !== 10) {
    throw new Error("finish reason / usage not surfaced");
  }
});

Deno.test("callGroqJson attaches usage to provider errors that report it", async () => {
  let error: unknown;
  await withFetch(
    () =>
      Promise.resolve(
        new Response(
          JSON.stringify({ error: { message: "bad" }, usage: { prompt_tokens: 40, completion_tokens: 2 } }),
          { status: 400 },
        ),
      ),
    async () => {
      try {
        await callGroqJson(base);
      } catch (e) {
        error = e;
      }
    },
  );
  if (!(error instanceof GroqCallError) || error.usage?.promptTokens !== 40 || error.status !== 400) {
    throw new Error("usage not attached to provider error");
  }
});

Deno.test("callGroqJson errors without usage carry none (released, not billed)", async () => {
  let error: unknown;
  await withFetch(
    () => Promise.resolve(new Response("upstream exploded", { status: 502 })),
    async () => {
      try {
        await callGroqJson(base);
      } catch (e) {
        error = e;
      }
    },
  );
  if (!(error instanceof GroqCallError) || error.usage !== null) throw new Error("unexpected usage");
});

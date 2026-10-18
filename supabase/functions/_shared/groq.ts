// Groq chat-completions client (OpenAI-compatible). Pricing verified live against
// https://console.groq.com/docs/models on 2026-10-02 — Llama 3.3 70B / Llama 3.1 8B are
// enterprise-only on Groq and 404 for a standard API key, so this project only ever targets
// the gpt-oss family.
const GROQ_API_URL = "https://api.groq.com/openai/v1/chat/completions";

// Default outbound timeout. ai-assistant clamps the effective value below the budget
// reservation TTL so a slow call can never outlive its reservation (audit B-08).
export const DEFAULT_GROQ_TIMEOUT_MS = 60_000;

// USD per token (not per million) for prompt/completion, keyed by model id, so cost estimates
// stay correct if GROQ_MODEL is switched between the two supported models.
const PRICING_PER_TOKEN: Record<string, { input: number; output: number }> = {
  "openai/gpt-oss-120b": { input: 0.15 / 1_000_000, output: 0.60 / 1_000_000 },
  "openai/gpt-oss-20b": { input: 0.075 / 1_000_000, output: 0.30 / 1_000_000 },
};

// Fallback for an unrecognized model id: price at the more expensive known tier so budget
// checks stay conservative rather than silently under-reserving.
const DEFAULT_PRICING = PRICING_PER_TOKEN["openai/gpt-oss-120b"];

export function pricingFor(model: string) {
  return PRICING_PER_TOKEN[model] ?? DEFAULT_PRICING;
}

// A rough upper-bound estimate used only to size the pre-call budget reservation; the real
// cost (used for the committed ai_usage_events row) comes from the API response's actual
// token counts. ~4 characters per token is a standard rough heuristic for English text.
export function estimateInputTokens(text: string): number {
  return Math.ceil(text.length / 4);
}

export interface GroqChatResult {
  content: string;
  promptTokens: number;
  completionTokens: number;
  /** OpenAI-style finish reason; "length" means the output was cut off at max tokens. */
  finishReason: string | null;
}

/**
 * Thrown for provider failures. When Groq reported token usage alongside the failure
 * (an error body carrying `usage`, or a truncated completion), `usage` is set so the caller
 * can bill the reservation for what was actually consumed instead of releasing it.
 */
export class GroqCallError extends Error {
  constructor(
    message: string,
    readonly status: number | null,
    readonly usage: { promptTokens: number; completionTokens: number } | null,
  ) {
    super(message);
    this.name = "GroqCallError";
  }
}

function toCount(value: unknown): number {
  return typeof value === "number" && Number.isFinite(value) && value >= 0 ? Math.floor(value) : 0;
}

/** Extracts a usage object from a (possibly error-shaped) Groq JSON body, or null. */
export function extractGroqUsage(
  body: unknown,
): { promptTokens: number; completionTokens: number } | null {
  if (!body || typeof body !== "object") return null;
  const record = body as Record<string, unknown>;
  const nested = record.error && typeof record.error === "object"
    ? (record.error as Record<string, unknown>).usage
    : undefined;
  const usage = (record.usage ?? nested) as Record<string, unknown> | undefined;
  if (!usage || typeof usage !== "object") return null;
  const promptTokens = toCount(usage.prompt_tokens);
  const completionTokens = toCount(usage.completion_tokens);
  if (promptTokens === 0 && completionTokens === 0) return null;
  return { promptTokens, completionTokens };
}

export async function callGroqJson(opts: {
  apiKey: string;
  model: string;
  systemPrompt: string;
  userPrompt: string;
  maxOutputTokens: number;
  timeoutMs?: number;
}): Promise<GroqChatResult> {
  const response = await fetch(GROQ_API_URL, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${opts.apiKey}`,
    },
    body: JSON.stringify({
      model: opts.model,
      messages: [
        { role: "system", content: opts.systemPrompt },
        { role: "user", content: opts.userPrompt },
      ],
      response_format: { type: "json_object" },
      max_completion_tokens: opts.maxOutputTokens,
    }),
    signal: AbortSignal.timeout(opts.timeoutMs ?? DEFAULT_GROQ_TIMEOUT_MS),
  });

  if (!response.ok) {
    const body = await response.text();
    let usage: { promptTokens: number; completionTokens: number } | null = null;
    try {
      usage = extractGroqUsage(JSON.parse(body));
    } catch {
      // Non-JSON error body: no usage to bill.
    }
    throw new GroqCallError(`Groq API error (${response.status}): ${body}`, response.status, usage);
  }

  const data = await response.json();
  const usage = extractGroqUsage(data);
  const content = data.choices?.[0]?.message?.content;
  if (typeof content !== "string") {
    throw new GroqCallError("Groq API response missing choices[0].message.content", 200, usage);
  }

  return {
    content,
    promptTokens: data.usage?.prompt_tokens ?? 0,
    completionTokens: data.usage?.completion_tokens ?? 0,
    finishReason: typeof data.choices?.[0]?.finish_reason === "string"
      ? data.choices[0].finish_reason
      : null,
  };
}

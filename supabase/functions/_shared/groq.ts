// Groq chat-completions client (OpenAI-compatible). Pricing verified live against
// https://console.groq.com/docs/models on 2026-10-02 — Llama 3.3 70B / Llama 3.1 8B are
// enterprise-only on Groq and 404 for a standard API key, so this project only ever targets
// the gpt-oss family.
const GROQ_API_URL = "https://api.groq.com/openai/v1/chat/completions";

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
}

export async function callGroqJson(opts: {
  apiKey: string;
  model: string;
  systemPrompt: string;
  userPrompt: string;
  maxOutputTokens: number;
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
  });

  if (!response.ok) {
    const body = await response.text();
    throw new Error(`Groq API error (${response.status}): ${body}`);
  }

  const data = await response.json();
  const content = data.choices?.[0]?.message?.content;
  if (typeof content !== "string") {
    throw new Error("Groq API response missing choices[0].message.content");
  }

  return {
    content,
    promptTokens: data.usage?.prompt_tokens ?? 0,
    completionTokens: data.usage?.completion_tokens ?? 0,
  };
}

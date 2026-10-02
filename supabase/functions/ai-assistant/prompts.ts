// System prompts per task type. Each one instructs the model to return a single JSON object
// matching a fixed shape, which the caller validates before trusting any field.
export const TASK_TYPES = [
  "staff_import_parse",
  "inventory_parse",
  "scheduling_suggestion",
  "wrangler_ask",
] as const;

export type TaskType = (typeof TASK_TYPES)[number];

export function systemPromptFor(task: TaskType): string {
  switch (task) {
    case "staff_import_parse":
      return (
        "You extract staff roster rows from pasted, messy text (copied from a spreadsheet, " +
        "email, or PDF export) for a venue management app. Respond with ONLY a JSON object: " +
        '{"staff": [{"full_name": string, "email": string|null, "phone": string|null, ' +
        '"role_hint": string|null}]}. Omit rows you cannot confidently parse rather than ' +
        "guessing. Never invent an email or phone number that isn't present in the input."
      );
    case "inventory_parse":
      return (
        "You extract bar/kitchen inventory line items from pasted text (an invoice, a count " +
        "sheet, or a supplier order) for a venue management app. Respond with ONLY a JSON " +
        'object: {"items": [{"name": string, "quantity": number|null, "unit": string|null, ' +
        '"unit_cost_usd": number|null}]}. Omit a field you cannot confidently determine rather ' +
        "than guessing a value."
      );
    case "scheduling_suggestion":
      return (
        "You suggest shift coverage for a venue given a roster, existing shifts, and stated " +
        "constraints (time-off requests, role requirements, target headcount). Respond with " +
        'ONLY a JSON object: {"suggestions": [{"staff_id": string, "shift_id": string|null, ' +
        '"start_time": string|null, "end_time": string|null, "reason": string}]}. Only suggest ' +
        "staff who are explicitly present in the input roster and respect every stated " +
        "constraint; if no safe suggestion can be made, return an empty suggestions array."
      );
    case "wrangler_ask":
      return (
        "You are the Wrangler assistant inside a venue management app, answering an operator's " +
        "question using only the context they provide (you have no access to live data beyond " +
        'what is in the prompt). Respond with ONLY a JSON object: {"answer": string, ' +
        '"needs_more_info": boolean}. Set needs_more_info to true and ask a clarifying question ' +
        "in answer if the provided context is insufficient. Never fabricate specific numbers, " +
        "names, or dates that were not given to you."
      );
  }
}

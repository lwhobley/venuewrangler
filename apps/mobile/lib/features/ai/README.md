# features/ai

Groq-backed assistant client, calling the `ai-assistant` Edge Function
(`supabase/functions/ai-assistant/`). Every AI-assisted action here must have a manual,
non-AI fallback workflow — none of these results are applied automatically; they're always
previewed/advisory for the user to accept, edit, or ignore.

- `domain/ai_models.dart` — result types for the four task types the Edge Function supports:
  `StaffImportResult`, `InventoryParseResult`, `SchedulingSuggestionResult`,
  `WranglerAskResult`.
- `data/ai_repository.dart` — `AiRepository` interface + `SupabaseAiRepository`, which calls
  `client.functions.invoke('ai-assistant', ...)` and maps the Edge Function's JSON error
  codes (budget exceeded, rate limited, not a venue member, etc.) to `AppError` subtypes.
- `application/ai_providers.dart` — `aiRepositoryProvider`.
- `presentation/wrangler_assistant_screen.dart` — the one UI built so far: a free-text
  question/answer screen for the general "Wrangler" assistant (`wrangler_ask`), routed at
  `/wrangler`. This stands alone because it has no other feature's data model as a
  prerequisite.

`parseStaffImport`, `parseInventory`, and `suggestScheduling` are implemented and callable
from `AiRepository` today, but have no screen yet — their natural home is a "paste roster /
invoice / constraints" entry point inside `features/workforce`, `features/inventory`, and
`features/schedules` respectively, none of which are implemented yet (see their own READMEs).
Build the UI there when those features land, calling straight into the existing repository
methods rather than duplicating the Edge Function call.

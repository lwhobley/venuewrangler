# features/ai

Groq-backed assistant client, calling the `ai-assistant` Edge Function
(`supabase/functions/ai-assistant/`). Every AI-assisted action here must have a manual,
non-AI fallback workflow — none of these results are applied automatically; they're always
previewed/advisory for the user to accept, edit, or ignore.

- `domain/ai_models.dart` — result types for the task types the Edge Function supports:
  `StaffImportResult`, `InventoryParseResult`, `SchedulingSuggestionResult`,
  `WranglerAskResult`, `ShiftInsightsResult`.
- `data/ai_repository.dart` — `AiRepository` interface + `SupabaseAiRepository`, which calls
  `client.functions.invoke('ai-assistant', ...)` and maps the Edge Function's JSON error
  codes (budget exceeded, rate limited, not a venue member, `ai_disabled_for_org`, etc.) to
  `AppError` subtypes.
- `data/consent_gated_ai_repository.dart` — wraps the repository so no request is sent until
  the person has acknowledged the processor disclosure (below). `aiRepositoryProvider` always
  returns the gated version, so every caller gets it.
- `data/ai_consent_store.dart` — per-user acknowledgement in `SecureSessionStorage`
  (`ai_processor_consent.<userId>`). It is removed by `SecureSessionStorage.clearAll()` on
  sign-out, so the notice shows again after signing back in.
- `data/org_ai_settings_repository.dart` — reads `organizations.ai_enabled` and calls
  `set_org_ai_enabled` (owner/admin only).
- `application/ai_providers.dart` — `aiRepositoryProvider`, `ensureAiConsent`, and
  `aiConsentPrompterProvider` (default: shows the dialog on the router's root navigator;
  tests override it). `application/org_ai_providers.dart` — the org toggle's providers.
- `presentation/ai_consent_dialog.dart` — one-time disclosure: Groq is the processor, what is
  sent, link to the privacy policy.
- `presentation/org_ai_toggle_tile.dart` — "AI features for this organization" switch, shown in
  Settings to owners and admins. New organizations start with AI off.
- `presentation/wrangler_assistant_screen.dart` — free-text question/answer screen for the
  general "Wrangler" assistant (`wrangler_ask`), routed at `/wrangler`.

## Who calls the repository

- `wrangler_ask` — this feature's own screen.
- `staff_import_parse` — "Import from paste" on the roster (`features/workforce`).
- `inventory_parse` — `features/inventory` import screen.
- `scheduling_suggestion` — the schedule list (`features/schedules`).
- `shift_insights` — `features/insights`.

## Behaviour to keep

- First AI call per user shows the disclosure; declining raises `AiUnavailableError` and
  nothing is sent.
- `ai_disabled_for_org` (organization switch off) is shown verbatim to the user with the hint
  that an owner or admin can enable it in Settings.
- Rosters sent for import contain personal data (names, emails, phones); the disclosure says
  so. Prefer deterministic parsing where possible and keep inputs minimal.

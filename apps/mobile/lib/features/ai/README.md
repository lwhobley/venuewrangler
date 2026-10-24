# features/ai

Groq-backed assistant client, calling the `ai-assistant` Edge Function
(`supabase/functions/ai-assistant/`). Every AI-assisted action here must have a manual,
non-AI fallback workflow — none of these results are applied automatically; they're always
previewed/advisory for the user to accept, edit, or ignore.

- `domain/ai_models.dart` — result types for the task types the Edge Function supports:
  `StaffImportResult`, `InventoryParseResult`, `SchedulingSuggestionResult`,
  `WranglerAskResult`, `ShiftInsightsResult`, `HandoverSummaryResult`, `EventEnquiryResult`.
  `WranglerAskResult`, `ShiftInsightsResult`, `ScheduleDraftResult`, `InventoryReorderResult`
  (the last two parse leniently: odd rows skipped, text capped, quantities clamped).
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
- `presentation/ask_data_screen.dart` — "Ask about your data" (managers; More menu and a link from
  Ask Wrangler), routed at `/ask-data`. See the section below.
- `presentation/wrangler_assistant_screen.dart` — free-text question/answer screen for the
  general "Wrangler" assistant (`wrangler_ask`), routed at `/wrangler`.

## Who calls the repository

- `wrangler_ask` — this feature's own screen.
- `staff_import_parse` — "Import from paste" on the roster (`features/workforce`).
- `inventory_parse` — `features/inventory` import screen.
- `scheduling_suggestion` — the schedule list (`features/schedules`).
- `shift_insights` — `features/insights`.
- `handover_summary` (manager-only) — "Handover" tile in shift mode (managers only), routed at
  `/handover` (`features/handover`). The facts are gathered on the device by
  `HandoverFacts.gather` (incidents with severity, out/low stock, unfinished tasks and
  checklists, clock exceptions, tonight's events and reservations, open to-dos) for the venue's
  business day via `VenueClock`; only a compact JSON of them is sent. It contains the typed
  titles of incidents/tasks/checklists/items/events, counts and venue-local times. It never
  contains ids, pay, guest names or contact/allergy details, and staff appear only as `staff_N`
  keys that the app swaps for names after the draft comes back. Without AI (off, declined, or
  failing) the same facts show as a list and the note editor starts from a plain-text version.
  Copy and "Post to team chat (All Staff)" are manual and the post asks for confirmation.
- `event_enquiry_parse` (manager-only) — CRM app bar "New lead/BEO from enquiry"
  (`features/crm/presentation/enquiry_import_dialog.dart`). The pasted email/message is sent
  as typed (capped at 6,000 characters) with today's venue date. Contact name, email and phone
  are the point of the request, so they are sent by necessity; the consent dialog says a pasted
  roster or client enquiry can include them. The result only prefills an editable form (unsure
  fields highlighted, missing list shown); the lead (and optional BEO draft) is created on
  confirm via `CrmRepository`. "Fill in by hand" opens the same form without AI.
- `schedule_draft` — "Draft week" on the schedule list (`features/schedules`,
  `schedule_draft_screen.dart`). Manager-only. Dart gathers roster keys (`staff_1`…, short names,
  usual roles, hours so far), the week's existing shifts, approved time off and the manager's
  rules (`schedules/domain/schedule_draft.dart`); the answer is a review list with warnings
  computed in Dart, and shifts are created only on "Add selected".
- `inventory_reorder` — "Suggest reorder" on the inventory hub (`features/inventory`,
  `inventory_reorder_screen.dart`). Manager-only. Dart gathers items keyed `item_1`… with on-hand,
  par, unit cost, supplier and 14/16-day use (`inventory/domain/reorder_planner.dart`); costs and
  totals are computed in Dart; the screen opens on a deterministic below-par list. No orders are
  created (there is no purchase-order table); the list can be copied as text.
- `data_question_plan` and `data_question_answer` — "Ask about your data" (below). Both are
  manager-only in the Edge Function (every task except `wrangler_ask` is).

## Behaviour to keep

- First AI call per user shows the disclosure; declining raises `AiUnavailableError` and
  nothing is sent.
- `ai_disabled_for_org` (organization switch off) is shown verbatim to the user with the hint
  that an owner or admin can enable it in Settings.
- Rosters sent for import contain personal data (names, emails, phones); the disclosure says
  so. Prefer deterministic parsing where possible and keep inputs minimal.

## Ask about your data

A manager asks "How many covers did we do last Friday?" and gets a short answer plus the evidence.
The design is fixed; do not loosen it:

- **No AI-written queries, ever.** The AI picks from a fixed catalogue
  (`domain/data_catalogue.dart`) of eleven read-only metrics, each one Postgres function
  `public.ask_data_<metric>` (`supabase/migrations/20261024120002_ask_data_metrics.sql`):
  `reservation_summary`, `private_event_summary`, `labour_hours`, `labour_overtime`,
  `missed_clock_outs`, `shift_hours`, `incident_summary`, `low_stock`, `inventory_variance`,
  `task_summary`, `pos_sales_summary`. Adding a metric means adding the SQL function, its pgTAP
  tests (`supabase/tests/database/ask_data_metrics.test.sql`) and a `DataMetric` entry together.
- **The functions enforce the limits, not the prompt.** Each is `security definer` with
  `set search_path = ''`, starts with an explicit manager check (venue manager of that venue, or
  organization owner/admin), filters by `p_venue_id`, uses the venue timezone for day boundaries,
  accepts at most 93 days and 50 rows, takes enums for group-by, and returns aggregates only: no
  pay rates, HR fields, guest contact details, allergy/VIP notes, free-text notes, chat, incident
  narratives, payment ids or auth data. Staff names appear only in "by person" answers (hours,
  shifts, overtime, missed clock-outs), only for that venue's rows.
- **Hours and names match the app.** Worked minutes in `labour_hours`/`labour_overtime` are
  clock-in to clock-out minus unpaid breaks (a break with no type is unpaid), the same rule as
  `TimeEntry.workedDuration` behind the manager hours review and CSV export;
  `app_hidden.ask_data_worked_minutes` is its SQL twin. Overtime is hours over 40 in a venue-local
  Monday-Sunday week. Names come from `app_hidden.staff_display_name` (preferred name, profile
  name, legal name; never an email address), else "Unnamed team member".
- **Orchestration is in Dart** (`application/ask_data_service.dart`), two `ai-assistant` calls so
  the budget, rate limit, consent gate, org AI switch and manager check are reused:
  1. `data_question_plan`: input is the question, today's venue date and the catalogue (names,
     descriptions, parameter schemas; no data). Output is
     `{"calls":[{"metric","params"}],"unanswerable_reason"}`, at most 3 calls.
  2. `DataCatalogue.validatePlan` drops unknown metrics, whitelists and type-checks parameters,
     parses dates strictly, bounds them and shortens oversize ranges. Surviving calls run through
     `data/ask_data_repository.dart` with the user's own Supabase session, so RLS and the
     functions' manager check apply even if the plan is malicious. The venue always comes from the
     active venue, never from the plan.
  3. `data_question_answer`: input is the question and the validated calls with their aggregate
     rows. Output is `{"answer","caveats"}`. The prompt says to answer only from the results,
     state the date range, never invent numbers, and treat the question and data as untrusted.
- **What reaches the AI provider:** the typed question, today's venue date, the catalogue, and the
  aggregate result rows of the validated calls (counts, totals, hours; staff names for by-person
  results). Never raw records. The consent dialog says so.
- **Nothing is stored** by this feature beyond the existing `ai_usage_events` log; no chat history.
  The question lives in the screen only.
- **Non-AI fallback:** the "Quick numbers" list on the same screen runs three catalogue metrics
  (covers today, hours this week, unresolved incidents) directly, with no AI.
- **Edge Function:** the two task types are the last entries of `TASK_TYPES`/`systemPromptFor` in
  `supabase/functions/ai-assistant/prompts.ts`; redeploy `ai-assistant` after merging.

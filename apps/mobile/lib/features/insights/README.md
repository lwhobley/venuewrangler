# features/insights

Phase 4: implemented (port of legacy `packages/api/src/modules/insights/`).

Replaces legacy `CosmicInsight` with venue- and shift-scoped Groq-powered AI operational shift insights:

- `domain/shift_insight.dart` — Hand-written domain model with `ShiftInsightKind` (`shiftSummary`, `coverageWarning`, `laborEfficiency`, `rushPrep`, `fatigueRisk`, `stationBalance`, `complianceNote`).
- `data/insights_repository.dart` — `InsightsRepository` interface and `SupabaseInsightsRepository` implementation for querying insights, creating manual insights, deleting insights, and triggering Groq-backed AI insight generation and storage via `AiRepository`.
- `application/insights_providers.dart` — `insightsRepositoryProvider`, `shiftInsightsForVenueProvider(venueId)`, and `shiftInsightsForShiftProvider(venueId, shiftId)` Riverpod providers.
- `presentation/shift_insights_screen.dart` — Screen displaying categorized shift insights with visual metadata, retry logic, delete confirmation, and an interactive "Generate AI Insights" modal that calls the `ai-assistant` Edge Function.

### Authorization & Database Controls
Authorization is enforced entirely at the database layer via RLS and PostgreSQL triggers in `supabase/migrations/20261002210000_shift_insights_schema.sql`:
- **RLS**: Venue members can read all shift insights for their venue (`shift_insights_select_venue_members`). Managers, organization owners, and organization admins have full write access (`insert`, `update`, `delete`).
- **`prepare_shift_insight_insert` trigger**: Derives `organization_id` from `venue_id` (or from `shift_id` if only `shift_id` is supplied) using "derive, don't trust". Validates that if both `venue_id` and `shift_id` are provided, the shift genuinely belongs to that venue. Sets `created_by` to `auth.uid()`.
- **`sync_shift_insight_update` trigger**: Maintains `updated_at = now()` and prevents cross-tenant organization hijacking.
- **`FORCE ROW LEVEL SECURITY`**: Enabled on `public.shift_insights` to prevent table owner bypass.

### AI Assistant & Groq Integration
- `supabase/functions/ai-assistant/prompts.ts` extended with the `shift_insights` task type and system prompt.
- Handled via `callGroqJson` in `supabase/functions/_shared/groq.ts` with strict JSON schema mode, rate limiting, and monthly budget reservations.

### Not Yet Implemented / Gaps
- Automated background cron generating daily shift insights ahead of scheduled shifts (requires background scheduler/pg_cron or Edge Function cron).
- Multi-day historical trend analysis (currently scopes to the active shift or recent venue operational context).

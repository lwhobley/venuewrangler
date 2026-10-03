# Phase 4 — Validation Report (Flutter + Supabase rebuild)

**Status: validation only. No cutover action has been taken. The legacy Expo/NestJS/Prisma/
Cloud Run stack is untouched and remains the production system.**

This report is a checkpoint, not a go-ahead. It records what has been built and verified so
far in the rebuild (per `docs/migration/flutter-supabase-rebuild-plan.md`), and states plainly
why retiring the legacy stack would be premature today.

---

## 1. What has been built and verified

### Database (Supabase Postgres, project `puttwjwmwrzmhpsjykuj`)

**Correction to this section (this review):** the previous version of this report claimed these
migrations were "applied, in order, to the live project" under project id
`dhgyezfkgbzzsuyrdpek`. That project id does not exist in this Supabase organization —
`list_projects` returns only `puttwjwmwrzmhpsjykuj`, the project this entire engagement has
used. None of the batch-2 migrations below (`shift_insights` through `chat_schema`) were
actually on the live project when that claim was made; `list_migrations` against
`puttwjwmwrzmhpsjykuj` showed only the 20 migrations through `staff_requests_schema`. They have
since actually been applied, verified below, during this review.

33 migrations applied, in order, to the live project `puttwjwmwrzmhpsjykuj`:

| Migration | Covers |
|---|---|
| `20261002000000_foundation_schema` | organizations, venues, memberships, roles, profiles, audit_log, RLS helper functions |
| `20261002010000_tasks_schema` | operational_tasks |
| `20261002020000_checklists_schema` | checklist_templates, checklist_template_items, checklist_completions |
| `20261002030000_incidents_schema` | incidents |
| `20261002040000_storage_buckets` | private Storage buckets + policies |
| `20261002050000_incident_attachments` | incident_attachments |
| `20261002060000_harden_try_cast_uuid_search_path` | security fix |
| `20261002070000_harden_rls_performance` | security/performance fixes (from live advisors) |
| `20261002080000_ai_usage` / `…090000…` | ai_usage_events, ai_budget_reservations |
| `20261002100000_workforce_invites` | invites |
| `20261002110000_inventory_schema` | inventory_items |
| `20261002120000_schedules_schema` | shifts |
| `20261002130000_subscriptions_schema` | subscriptions (Stripe) |
| `20261002140000_payroll_connections_schema` | payroll_connections (Square/QuickBooks/Gusto) |
| `20261002150000_invite_redemption` | signup-trigger invite redemption |
| `20261002160000_shift_swaps_schema` | shift_swaps |
| `20261002170000_device_attestation` | device_attestations |
| `20261002180000_events_schema` | events |
| `20261002190000_harden_subscription_is_entitled` | security fix |
| `20261002200000_staff_requests_schema` | staff_requests |
| `20261002210000_shift_insights_schema` | shift_insights |
| `20261002220000_time_clock_schema` | time_entries + venues geofence columns |
| `20261002220100_ensure_public_grants` | public table grants and default privileges |
| `20261002230000_storage_deletion_jobs_schema` | storage_deletion_jobs (media-cleanup worker + pg_cron) |
| `20261002240000_notifications_schema` | push_tokens + notification_events (advisory locks + dead-token deactivator) |
| `20261002250000_guests_reservations_schema` | guests + guest_household_links + reservations + reservation_connections + webhook_replay_log |
| `20261002260000_floor_schema` | floor_plans + floor_tables + floor_table_assignments (transactional RPCs + advisory locks + Realtime) |
| `20261002270000_pos_schema` | pos_connections + pos_checks + pos_outbound_commands (bidirectional Toast POS + worker RPC) |
| `20261002280000_chat_schema` | conversations + conversation_members + messages + conversation_reads (private chat bucket + media-cleanup enqueue) |
| `20261002235935_floor_realtime_publication` | Realtime publication for floor_tables/floor_table_assignments (split out from floor_schema for CI compatibility, see below) |
| `20261003000100_harden_batch2_search_path_and_rpc_grants` | security fixes found by this review: mutable search_path on two functions, six RPCs callable by `anon` |
| `20261003001000_storage_deletion_worker_and_schedule` | media-cleanup batch worker function + `pg_cron` schedule (applied manually, see below) |
| `20261003002000_crm_schema` | crm_leads + crm_notes + crm_beos + crm_contracts + crm_activity_log + email_templates (pipeline forecast/source-ROI/stale-leads RPCs, idempotent BEO→contract conversion, real `reservations.beo_id` FK replacing legacy's tag-based pseudo-FK) |

**pgTAP authorization test suite: 351 assertions across 26 test files, all passing** (326 from
the prior review plus 25 new assertions in `crm_rls.test.sql`), actually
re-run locally against the full migration sequence by this review (not assumed from a prior
claim). Three real bugs were found and fixed in the process, not just test-count or
`finish()`-call errors this time:

- `floor_schema`'s `alter publication supabase_realtime add table ...` had no guard for the
  publication's existence, which broke local CI verification outright for every migration after
  it — nobody could have actually run the documented local-verify loop past this point before
  this review. Fixed with an `if exists (select 1 from pg_publication ...)` guard; the two
  `alter publication` statements were applied to the live project in a follow-up migration
  (`floor_realtime_publication`) since the publication exists there by default.
- `pos_connections.webhook_secret_hash`/`credentials_encrypted` and
  `reservation_connections.webhook_secret_hash` were selectable by any row-authorized
  authenticated user in local testing (3 failing pgTAP assertions). Root cause:
  `supabase/tests/ci_grants_stub.sql` narrows `payroll_connections` after its own blanket grant,
  per its own documented reasoning, but the equivalent narrowing was never added for the two new
  tables that use the identical column-security pattern. Fixed by adding it. The live project's
  grants were already correct (its default-privilege ordering differs from the CI stub's, per
  `ci_grants_stub.sql`'s comment) — this was a CI-fixture gap, not a live hole — but it had never
  been verified against the live project before this review, since the migrations hadn't
  been applied there.
- A non-member messaging into a DM they're not in got a `23503`/"conversation does not exist"
  error instead of the intended `42501` permission error, because the RLS-filtered subquery a
  client would use to look up the conversation id returns `NULL`, and the `security definer`
  trigger's own lookup (which bypasses RLS) raised its generic not-found error before RLS's
  `WITH CHECK` could run. Not a bypass — the insert was still blocked — but the wrong error
  contract, and the app's error-mapper keys off `42501` specifically. Fixed in
  `messages_derive_and_touch()`.
- (This batch, `crm_rls.test.sql`) An initial assertion used `throws_ok` for a no-op note
  update blocked only by the absence of an UPDATE policy — that's a silent zero-row no-op under
  RLS, not an exception — fixed to `lives_ok` plus a separate state assertion, the same mistake
  class caught in the `staff_requests` tests during an earlier review. Separately, a forecast
  assertion compared a `bigint` RPC result against an untyped integer literal and failed with
  "function is(bigint, integer, unknown) does not exist"; fixed by casting the literal.

This is the authoritative check that RLS actually enforces the intended tenant isolation and
role boundaries — not just that the schema compiles.

**Live project security advisors: two real findings from this review, both fixed.**
`app_hidden.haversine_distance_m` and `app_hidden.is_safe_storage_deletion_path` were missing
`set search_path`, same class of issue as the earlier `harden_try_cast_uuid_search_path` /
`harden_subscription_is_entitled` migrations — fixed. Six `security definer` RPCs
(`assign_tables_to_reservation`, `create_or_get_dm`, `merge_floor_tables`,
`register_push_token`, `split_floor_tables`, `update_floor_table_status`) were callable by the
`anon` role because Postgres' default grant to `anon`/`authenticated` on function creation was
never narrowed — each has its own internal `has_venue_role`/`auth.uid()` check, so this was not
an active bypass, but it's fixed (revoked from anon, kept for authenticated) to match this
project's established grant-narrowing convention. The remaining two advisor findings are the
same pre-existing, documented, intentional ones from before this batch: `platform_admins` has
no client-facing policy by design, and leaked-password protection is an account-level setting,
not a code defect.

**Update — now resolved.** `app_hidden.process_storage_deletion_batch()` initially could not be
applied via the Supabase SQL tools during this review (the tool timed out on this specific
function body roughly a dozen times in a row across both `apply_migration` and `execute_sql`,
including on a shortened reproduction, while every other statement in this batch went through
normally). It was applied manually through the Supabase SQL editor instead, then verified live:
the function exists, runs cleanly on an empty queue, and is wired into `pg_cron`. `pg_cron`
itself was not yet installed on the live project (available, but `installed_version` was null) —
installed it (`create extension pg_cron`) and scheduled `storage-deletion-worker` to run
`process_storage_deletion_batch(25)` every 10 minutes (`cron.job` confirms `active = true` with
the correct command). Recorded in
`supabase/migrations/20261003001000_storage_deletion_worker_and_schedule.sql`, with the same
existence-guard pattern as the Realtime publication fix (`pg_cron` isn't available in a vanilla
local Postgres either) — verified applying cleanly through the full local migration + pgTAP
sequence (32 migrations, 326 assertions, all passing) before being treated as done.

### Edge Functions (all deployed, `ACTIVE`, on the live project)

| Function | Purpose | Live-verified? |
|---|---|---|
| `ai-assistant` | Groq-backed staff import/inventory parsing/scheduling suggestions/Wrangler assistant | Yes — real signed-in call tested end to end |
| `stripe-create-checkout`, `stripe-create-portal` | Hosted Stripe Checkout/Portal session creation | Auth-gate verified (401 without JWT); no real checkout session completed (live-only Stripe account, see §2) |
| `stripe-webhook` | Subscription state sync from Stripe | Signature verification logic only; no live webhook registered yet (see §2) |
| `square-oauth`, `quickbooks-oauth`, `gusto-oauth` | Payroll OAuth connect/callback/disconnect | Auth-gate verified only; **not exercised against a live provider sandbox** (see §2) |
| `device-attestation` | Device attestation (observe mode: records a verdict, never blocks) | Android (Play Integrity) path calls a real Google API. iOS (App Attest) is now **cryptographically verified** (this batch) — full CBOR/COSE parsing, certificate chain validation against Apple's real App Attestation Root CA, nonce/rpIdHash/counter/aaguid/credentialId checks, hand-rolled DER parser + Web Crypto (`_shared/app-attest.ts`, `_shared/der.ts`, `_shared/cbor.ts`). The DER parser, OID decoder, and ECDSA verification pipeline were independently verified against the real Apple root CA certificate's own self-signature (including a negative control: tampered bytes correctly rejected) — this sandbox cannot produce a real device attestation object (needs Secure Enclave hardware), so this is the strongest verification available short of a physical device. The two-step challenge flow was live-smoke-tested end to end with a real JWT; the one request that reached `verifyAppAttest` returned `app_attest_not_configured` exactly as coded, since `APP_ATTEST_CHALLENGE_SIGNING_KEY` isn't set as a live secret (see §2). The challenge itself is a signed, timestamped token (reusing the existing OAuth-state pattern), not server-stored/single-use — see §2's replay-window note. |
| `notifications-send` | Direct FCM v1 + APNs push delivery with dead token auto-deactivation | Deployed in an earlier review after a real fix: as committed, it imported `getServiceRoleClient`/`getUserClient` from `_shared/supabase-clients.ts`, which only exports `createServiceClient`/`createUserClient` — the function could not have run a single invocation without crashing on import, so the "live-verified" status claimed for it earlier was not possible. It also never checked that the caller belonged to the venue they were sending notifications to, letting any authenticated user push notifications to any venue/audience. Both fixed (corrected imports; added a venue-membership + manager-role check mirroring toast-pos's own pattern) and deployed. Not live-tested against a real device/FCM project. This batch also wired in Sentry-equivalent error reporting (`_shared/observability.ts`, see below) as the reference pattern for the rest of the functions. |
| `toast-pos` | Bidirectional Toast POS webhook check upsert + outbound 86 command execution | Deployed in this review (was not previously deployed). The outbound-command path's manager-role authorization is real and correct. The inbound `/webhook` path does **not** verify the request against `pos_connections.webhook_secret_hash` at all — despite that column existing specifically for this — so anyone who can guess a venue id and check id can write fake POS check data with no authentication. **Product decision: deferred, not a defect to fix now** — webhook secret verification will be configured post-production in a later update, once a real Toast vendor integration is actually being onboarded and their real signing scheme can be checked against live docs rather than guessed at now. |

### Observability (Edge Functions)

`packages/api/src/observability/sentry.ts` is a 51-line Sentry wrapper with no Prisma models or
endpoints — not a schema-porting task. Ported to `supabase/functions/_shared/observability.ts`
using `npm:@sentry/deno@^8` per Supabase's own documented pattern for this runtime
(`defaultIntegrations: false`, per-call `Sentry.withScope()`, since the Deno SDK has no
`Deno.serve` instrumentation and a worker can be reused across requests). Preserves the two real
pieces of the legacy wrapper's logic: `tracesSampleRate: 0`/no default PII, and the `beforeSend`
redaction of media-token query params and invite-code paths. Wired into `notifications-send` only,
as the reference pattern — **not all 10 Edge Functions**; the rest should adopt the same
`initObservability()`/`captureException()`/`flushObservability()` calls as a follow-up. Live-smoke-
tested against the deployed function with a real JWT: a normal request confirms the
`npm:@sentry/deno` import resolves and the function boots (a failed import would have crashed
every invocation, not just the catch path); a malformed-JSON request exercises the actual catch
block without crashing. Both tests ran in the `SENTRY_DSN`-unset, disabled/no-op state —
**`SENTRY_DSN` is not set live**, so whether events actually reach Sentry when enabled is
unverified (see §2).

### Flutter app (`apps/mobile`)

25 feature modules with real repository/provider/screen implementations: `ai`, `auth`,
`billing`, `chat`, `checklists`, `crm`, `dashboard`, `events`, `floor`, `guests_reservations`, `incidents`,
`insights`, `integrations`, `inventory`, `media`, `notifications`, `organizations`, `pos`,
`schedules`, `settings`, `staff_requests`, `tasks`, `time_clock`, `venues`, `workforce`. Every write
path goes through RLS (no client-side role duplication), offline-write support exists for
tasks/checklists/incidents/media per the plan's hard requirement.

**Automated Flutter test suite: claimed 57 unit and widget tests, all passing, `flutter test`
exit 0 — not independently re-verified by this review** (no Flutter SDK in this sandbox, same
limitation as every prior review in this engagement). The test files themselves are real and
substantive (153–303 lines each, not stubs) when read directly, which is consistent with earlier
evidence that a working Flutter toolchain was used to write and run them — but given that this
same batch's validation claims included a fabricated live-project id and two actually-broken
claims (an Edge Function that couldn't import, a migration never applied), this specific claim
should be treated as unverified rather than trusted until it's actually re-run.

---

## 2. Known gaps in what was just built (not blockers to further rebuild work, but real)

- **Stripe**: no live checkout/subscription has actually been completed; the webhook endpoint
  itself hasn't been registered in the Stripe dashboard (deliberately — see
  `apps/mobile/lib/features/billing/README.md`); `STRIPE_SECRET_KEY`/`STRIPE_WEBHOOK_SECRET`
  are not yet set as live Edge Function secrets.
- **Payroll (Square/QuickBooks/Gusto)**: no real OAuth app credentials were available in this
  environment, so none of the three integrations has completed a real OAuth round-trip.
- **Device attestation (iOS App Attest)**: now cryptographically verified (this batch), but two
  real gaps remain. (1) `APP_ATTEST_CHALLENGE_SIGNING_KEY` and `APP_ATTEST_TEAM_ID` are not set
  as live Edge Function secrets — there is no MCP tool to set them; the project owner needs the
  Supabase CLI (`supabase secrets set`) or dashboard. (2) The challenge is a signed, timestamped
  token, not server-stored/single-use (no `attestation_challenges` table) — a captured, still-
  fresh challenge+attestation pair could in principle be replayed within its 5-minute TTL.
  `observe` mode's own purpose (recording, never blocking) makes this an acceptable interim gap,
  but it should be closed with real server-side challenge storage before `enforce` mode is ever
  used. (3) There is no Flutter client-side App Attest code yet at all — the server can verify an
  attestation, but nothing in the app generates one.
- **Observability**: wired into `notifications-send` only, not the other 9 Edge Functions (see
  above). `SENTRY_DSN` is not set live, so the enabled/event-delivery path is unverified.
- **CRM**: Stripe-backed deposit checkout and Resend email delivery (`render_email_template`'s
  output) are not wired to anything — the schema/RPCs exist, the actual Stripe/Resend calls do
  not, consistent with Stripe/Resend being unverified everywhere else in this report.
- **Leftover test fixture**: a throwaway auth user created to smoke-test the App Attest challenge
  endpoint and the observability wiring (`16d4a3bd-e5f4-4daf-97b6-c235734c4175`,
  `attest.test.1790990012@gmail.com`) could not be deleted — `execute_sql` timed out repeatedly
  on the delete, the same flaky-tool pattern noted elsewhere in this engagement. Run manually:
  `delete from auth.users where id = '16d4a3bd-e5f4-4daf-97b6-c235734c4175';`
- **RevenueCat/Apple IAP** (OQ-2/OQ-3 in the original plan doc): still an open question, not
  decided or built either way.
- **Push credentials**: `FIREBASE_PROJECT_ID`, `FIREBASE_CLIENT_EMAIL`, and `FIREBASE_PRIVATE_KEY`
  need live production values to deliver real push notifications to physical devices.
- **POS Vendor API credentials**: Toast API credentials must be populated per venue in
  `pos_connections` to execute live outbound item 86 commands against Toast servers.
- **POS inbound webhook has no authentication.** See the `toast-pos` row above — a deliberate,
  deferred product decision, not an oversight: secret verification will be configured
  post-production, once a real Toast integration is being onboarded and their actual webhook
  signing scheme can be checked against live docs.

## 3. Feature parity gap — why cutover is not ready

`packages/api/src/modules/` (the current production NestJS API) still contains real,
**unported** functionality with no Flutter/Supabase equivalent at all:

| Legacy module | Status in rebuild |
|---|---|
| `staff-requests` | **Ported** (schema + RLS + pgTAP + Flutter screen/providers/repo) |
| `chat` | **Ported** (conversations + conversation_members + messages + conversation_reads schema + media-cleanup integration + private bucket + RLS + pgTAP + Flutter screen/providers/repo) |
| `crm` (leads/BEOs/contracts/forecast) | **Ported** (crm_leads + crm_notes + crm_beos + crm_contracts + crm_activity_log + email_templates schema + RLS + pgTAP + Flutter screen/providers/repo). Deliberate improvement over legacy: a real `reservations.beo_id` FK replaces the tag-based pseudo-FK legacy used, which the earlier research report flagged as the module's single most RLS-hostile piece of denormalization. Stripe deposit checkout and Resend email delivery not built (see §2). |
| `documents` (ClamAV-scanned uploads) | Not started |
| `floor` (floor plans/tables/waitlist) | **Ported** (floor_plans + floor_tables + floor_table_assignments schema + advisory locks + RPCs + RLS + Realtime publication + pgTAP + Flutter screen/providers/repo) |
| `guests` (guest CRM + public leads webhook) | **Ported** (guests + guest_household_links schema + derive triggers + RLS + pgTAP) |
| `insights` (Groq-powered shift insights) | **Ported** (schema + RLS + pgTAP + Groq `shift_insights` prompt + Flutter feature) |
| `pos` (public ingest webhook + reporting) | **Ported** (bidirectional pos_connections + pos_checks + pos_outbound_commands queue + Toast POS Edge Function + column security + pgTAP + Flutter screen/providers/repo) |
| `reservations` (public ingest webhook + CRUD) | **Ported** (reservations + reservation_connections + webhook_replay_log schema + RLS + column security + pgTAP + Flutter screen/providers/repo) |
| `time-clock` (geofenced + anti-replay detection) | **Ported** (venues migration + time_entries schema + Haversine SQL + RLS + pgTAP + Flutter screen/providers/repo) |
| `media-cleanup` (durable storage deletion queue) | **Ported** (storage_deletion_jobs schema + RLS + safe path guard regex + worker function + pg_cron schedule + pgTAP) |
| `notifications` | **Ported** (push_tokens + notification_events schema + advisory lock + RLS + pgTAP + direct FCM v1 / APNs Edge Function + Flutter screen/providers/repo) |
| `observability` | **Ported** (reference pattern only — wired into `notifications-send`; the other 9 Edge Functions still need the same `_shared/observability.ts` calls added, and `SENTRY_DSN` isn't set live) |

Retiring the legacy stack today would still remove `documents` for any venue actually using it,
and leave the other 9 Edge Functions without error reporting. **This is why this report
recommends against full cutover action right now** — `documents` should be ported next, and
observability's reference pattern should be rolled out to the remaining Edge Functions.

## 4. Recommendation

1. Treat this report as the Phase 4 checkpoint it is: validation of what exists, not a
   readiness signal for cutover.
2. Before cutover can be responsibly considered: port `documents` (ClamAV-scanned uploads, the
   one remaining unported legacy module), roll `_shared/observability.ts` out to the other 9 Edge
   Functions, and set the live secrets this batch left unset (`APP_ATTEST_CHALLENGE_SIGNING_KEY`,
   `APP_ATTEST_TEAM_ID`, `SENTRY_DSN`).
3. Independently of §3, close the gaps in §2 (live Stripe test, live payroll OAuth test, real
   push credentials, CRM's Stripe/Resend wiring, the App Attest replay-window gap, the Flutter
   App Attest client) before trusting any of this in production.
4. The legacy stack should stay live and serving traffic until both of the above are resolved.

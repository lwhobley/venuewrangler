# Flutter + Supabase Rebuild — Phase 0 Discovery & Migration Plan

Status: **Phase 0 (Discovery only). No application code has been modified or deleted.**
Scope: Audit of this repository (`lwhobley/venuewrangler`) as it exists today — an Expo Router mobile app plus a NestJS/Prisma API (`packages/api`) deployed to Google Cloud Run — and a mapping plan for rebuilding it in place as a Flutter-first, Supabase-managed application per the target architecture in `CLAUDE.md`/the rebuild brief.

**Correction note:** an earlier pass of this discovery was mistakenly written against a separate `lwhobley/venuewranglerenterprise` repository, treating it as the rebuild target and this repo as a "reference implementation." That framing was wrong. **This repository (`venuewrangler`) is the one true target.** There is no separate reference repo — the current Expo/NestJS implementation documented below *is* the business-logic source of truth, and the rebuild happens in place (eventually under a restructured `apps/mobile/` + `supabase/` layout, per the target structure), not by porting into a different repository. The stray commit/branch pushed to `venuewranglerenterprise` has been left alone pending the user's cleanup decision; it is unrelated to this effort going forward.

**AI provider decision (post-Phase-0):** the target stack replaces Gemini with **Groq** (free-tier API, `openai/gpt-oss-120b` — $0.15/$0.60 per million input/output tokens as of 2026-10, verified live against `console.groq.com/docs/models`; Llama 3.3 70B and Llama 3.1 8B are enterprise-only on Groq and are not used here — fast inference with solid JSON-mode support) for every AI-assisted feature named below — scheduling suggestions, staff-import parsing, bar-inventory parsing, the "Wrangler" assistant/operator, and daily briefs. The reference-repo file/behavior inventory in §2.1/§3 below still describes the *existing* Gemini-backed implementation accurately (that's what was actually audited) and is left as-is; only the **target** columns in the mapping table (§4) and the Edge Function name (`ai-assistant`, not `gemini-ai`) reflect the swap. The budget-reservation pattern, structured-output validation, rate limiting, and manual-fallback requirements carry over unchanged — they're provider-agnostic.

---

## 0. How to read this document

- "Current implementation" = this repo today: root-level Expo Router app (`app/`, `components/`, `lib/`, `modules/`) + `packages/api` (NestJS 10 + Prisma + Postgres/Supabase, deployed to Cloud Run via `Dockerfile`/`deploy-api.yml`) + `packages/marketing` + `site/` (marketing website, untouched by this plan).
- "Target implementation" = Flutter app (new, under a future `apps/mobile/`) + Supabase (Postgres + RLS + Edge Functions), per the architecture requirements (Riverpod, go_router, supabase_flutter, freezed/json_serializable, feature-first structure, repository interfaces, environment flavors).
- Nothing below has been built yet. This document is the Phase 0 inventory, mapping table, and risk list that Phase 1 onward will execute against.

---

## 1. The single most important Phase 0 finding

**Tenant isolation today is enforced entirely at the application layer, not in the database — and there is no organization concept above a venue.**

- `docs/tenant-isolation.md` documents this explicitly as trust-boundary decision "VW-23": Postgres RLS is enabled on every public table but **has no per-tenant policies** (table owner bypasses RLS; no `FORCE ROW LEVEL SECURITY`). The actual isolation mechanism is a Prisma Client Extension (`packages/api/src/prisma/tenant-isolation.extension.ts`) that reads an `AsyncLocalStorage`-bound tenant context (`tenant-context.ts`) and auto-injects `WHERE venueId = …` into every query for models flagged as venue-scoped (`tenant-scope.ts`), plus manual `where: { venueId }` filters throughout controllers as defense in depth.
- **This is the opposite of what Supabase requires.** A Flutter client talking to Supabase directly needs real, declarative, per-row RLS policies evaluated inside Postgres — there is no equivalent of an app-layer AsyncLocalStorage context once the NestJS process is gone. Every tenant-scoped table's isolation logic must be **rewritten from scratch as SQL policies and independently tested**, not ported.
- **There is also no `Organization` model today.** The tenant root is `Venue` directly; membership is `Profile` (per-venue). The target architecture requires every tenant-scoped table to carry both `organization_id` and `venue_id`, with venues belonging to organizations. Introducing an organization layer above the existing venue model is itself a schema migration with no precedent in the current code — not a "copy the existing hierarchy" task.
- **The role model also needs expansion.** Today's roles are a flat 4-tier hierarchy — `staff` (0) < `server` (1) < `manager` (2) < `owner`/`admin` (3, equal rank) — plus an `allAccess` internal/support bypass flag (`auth/roles.ts`). The target role list (`platform_admin`, `organization_owner`, `organization_admin`, `venue_manager`, `supervisor`, `staff`) does not map 1:1; `platform_admin` has no real analog beyond the loosely-defined `allAccess` flag, and `supervisor` sits between today's `server` and `manager` with no existing boundary. This mapping needs an explicit decision in Phase 1 (see OQ-1 in §6), not an assumed correspondence.

These three gaps — no real RLS, no organization layer, no matching role model — are the foundation everything else in this plan depends on, and they should be resolved and tested before any other feature work begins.

---

## 2. Current implementation inventory

### 2.1 Backend (`packages/api`, NestJS 10 + Prisma + Postgres, Cloud Run)

**Prisma schema**: ~90 models / 23 enums. 14 global (non-venue-scoped) models: `User`, `Session`, `AuthAccount`, `PasswordCredential`, `DeviceAttestation`, `AttestationChallenge`, `Venue` itself (the tenant root), `CosmicInsight`, `ObjectDeletionJob`, `RateLimitBucket`, plus 4 pseudonymized retention tables (`RetainedTimeEntry`, `RetainedPosCheck`, `RetainedPosLaborPunch`, `RetainedStaffRequest`) that intentionally survive venue deletion for wage/compliance retention. ~76 models carry `venueId` and are tenant-scoped, spanning identity/membership, scheduling/workforce, time & attendance, chat, notifications/push, guests/CRM, reservations/floor plans, POS, billing, payroll, bar inventory, operations (logbook/checklists/event execution), audit, documents, and AI usage/budget (`AiUsageEvent`, `AiBudgetReservation`).

**API surface**: ~30 controllers under a global `/api` prefix, each with its own `v1/...` route. Full domain list: auth, billing (Stripe + RevenueCat webhooks), health, support/contact, push tokens, device attestation (iOS App Attest only — no Android/Play Integrity today), app/profile/venue bootstrap, staff + AI-assisted CSV import, bar inventory (+AI parsing, reports, purchase orders), chat (S3-backed images), CRM (leads/BEOs/contracts/forecast), documents (ClamAV-scanned), floor plans/tables/waitlist, guests (+public leads webhook), insights ("cosmic insights", global not venue-scoped), reservation integrations, operations (manager dashboard, AI daily brief, command center, checklists), the "Wrangler" AI assistant + AI operator (plan/execute), payroll (Gusto OAuth + generic Square/QuickBooks push), POS (public ingest webhook + reporting), reservations (public ingest webhook + CRUD), scheduling (+AI auto-scheduler, shift swaps), staff requests, time clock (geofenced + App-Attest-checked), workforce (join requests).

**Webhooks** (all with signature/secret verification): Stripe (`verifyStripeSignature`, HMAC-SHA256 of `timestamp.rawBody`, 300s replay tolerance, multi-secret rotation support), RevenueCat (bearer secret, constant-time compare), POS ingest per-venue (`PosConnection.webhookSecret`, hashed at rest as `sha256:<hex>`), reservation ingest per-venue (`ReservationConnection.webhookSecret`), guest leads webhook (`Venue.leadsWebhookSecret`, rotatable, replay-protected via `x-webhook-id`/`x-webhook-timestamp` + idempotency key).

**Scheduled jobs**: in-process `@nestjs/schedule` crons (reservation reminders hourly, chat-image cleanup hourly, general object-deletion drain hourly, long-shift/missed-clockout alerts every 10 min) plus one standalone Cloud Run Job (`src/retention.ts`) that runs audit-log cleanup, retained-time-entry cleanup, and expired-attestation-challenge cleanup sequentially, with its own Sentry init and failure reporting.

**Auth/authz**: custom PBKDF2 (600k iterations) password auth with a combined sign-in/up endpoint, email verification codes, password reset, a session-table-backed JWT (live DB lookup for instant revocation, not purely stateless), a "profile adoption" flow for merging invite-created orphan profiles into real accounts, the 4-tier role model above, and the `allAccess` support/internal bypass flag.

**Encryption at rest**: `payroll-crypto.ts` — AES-256-GCM with random IV, versioned payload format, key from `SHA-256(PAYROLL_TOKEN_KEY)`, used to encrypt Gusto/Square/QuickBooks OAuth tokens before persisting; a separate HMAC-signed, expiring OAuth `state` parameter binds venueId+expiry+provider for CSRF/replay protection during OAuth callbacks.

**Hard external dependencies to replace**: AWS S3 (chat images, boot fails without creds), a ClamAV daemon (document malware scanning), Resend (transactional email).

**Test coverage** (112 spec files) clusters around: tenant isolation (6 files — `tenant-isolation.integration.spec.ts`, `tenant-isolation-config.spec.ts`, `tenant-scope.spec.ts`, `tenant-context.spec.ts`, `prisma-service-tenant.integration.spec.ts`, `venue-scope.interceptor.spec.ts`), idempotency/webhook replay (3), concurrency (3: shared-lease, scheduling, inventory movement), auth/session/roles (6), billing (4), audit redaction (2), attestation/geofencing (2), rate-limit/abuse hardening (6), payroll integrations (3), POS (2), AI scheduling (3), Wrangler AI operator (8), retention/lifecycle (3), DB migration integrity/prod-safety guards (3), plus per-module controller/service specs and one full e2e spec.

**Gaps in the current repo itself** (to resolve, not carry forward): `.env.example` is missing several vars actually used in code (`SQUARE_APPLICATION_ID/SECRET`, `SQUARE_REDIRECT_URI`, `QUICKBOOKS_CLIENT_ID/SECRET`, `QUICKBOOKS_REDIRECT_URI`, `GUSTO_CLIENT_ID/SECRET`, `GUSTO_REDIRECT_URI`, `PAYROLL_TOKEN_KEY`, `GEMINI_WRANGLER_OPERATOR_MODEL`, `APP_ATTEST_BUNDLE_ID`); no SCIM exists; no Android/Play Integrity attestation exists; no `platform_admin`-equivalent role exists beyond the loosely-defined `allAccess` flag.

### 2.2 Mobile app (Expo Router, repo root)

**Screens**: full auth flow (welcome/sign-in/register/verify-email/reset-password/invite-only venue creation/invite-check/invite-accept/team-choice/workplace-search/join-pending), 13 tab screens (home dashboard, schedule, staff, clock, floor, reservations, guests/CRM, sales, reports, bar-stock, documents, chat, integrations, profile), and modal/root screens for checklists, event command center, floor editor, logbook, the "Wrangler" AI assistant, host stand, help, inventory/recipes, join requests, full reservations management, first-run setup, venue settings, and billing (Stripe checkout/portal links + RevenueCat IAP paywall).

**Data layer**: `lib/railway-hooks.ts` is a ~120-entry route table (`"namespace.fnName"` → REST path) wrapped in thin React Query hooks (`useQuery`, `useQueryState` with 402-subscription-required handling, `useMutation`/`useAction` with cache invalidation). `lib/api-client.ts` is the underlying fetch wrapper: bearer token + `X-Venue-Id` header, 401/403("no active membership") forces sign-out, 30s default timeout (120s for uploads), and an "ownership guard" that rejects in-flight requests if the local session identity changed mid-request (race-condition defense after account/venue switch). This route table is effectively the full inventory of client-to-backend behavior that Supabase direct-client calls and Edge Functions must jointly replace.

**Client-side integration posture (confirmed clean)**: no Stripe SDK in the client (hosted checkout/portal URLs only); Square/QuickBooks/Gusto connect UI is a plain form that POSTs provider+credentials to the API — all OAuth exchange happens server-side; Gemini/AI inference is 100% server-side, the client only renders results and allow-lists which server-suggested "plan" routes it's willing to navigate to; Sentry uses a public DSN with PII scrubbing and dev-mode disabled; RevenueCat uses a public SDK key. **No server-only secret of any kind was found in the mobile client.**

**Device attestation**: iOS-only today, via a custom Expo native module (`modules/app-attest`) wrapping `DCAppAttestService` (generateKey/attestKey/generateAssertion), with a deterministic canonical-JSON payload format that must stay byte-identical between client and server. No Android/Play Integrity client code exists.

**Offline support**: exactly one offline queue exists today (`lib/offline-inventory-queue.ts`, bar-inventory stock movements only) — per-owner scoped, cross-tab-safe on web, retry/backoff on reconnect. No app-wide offline queue exists; this is a gap relative to the target requirement to offline-enable tasks/checklists/incidents/media-retry.

**Secure storage**: `expo-secure-store` for the App Attest key id and the session token (native); web deliberately uses `sessionStorage`, not `localStorage`, to avoid XSS-persistent tokens.

**No Flutter, Riverpod, go_router, or Supabase dependency exists anywhere in this repo today.** The target mobile stack (Flutter + Riverpod + go_router + supabase_flutter + freezed/json_serializable) is entirely new — the Expo app's screen inventory and `railway-hooks.ts` route table above are the behavioral spec to rebuild against, not code to port.

---

## 3. Integration inventory (current behavior to preserve)

| Integration | Current files | Secrets/env | OAuth | Webhook | Scheduled | Notes for Supabase rebuild |
|---|---|---|---|---|---|---|
| Square (payroll push) | `packages/api/src/modules/payroll/square-client.ts` | `SQUARE_APPLICATION_ID/SECRET`, `SQUARE_REDIRECT_URI`, `SQUARE_API_BASE` | Yes (auth code + refresh) | No | No | Port OAuth+push logic into `square-oauth`/`payroll-sync` Edge Functions; encrypt refresh token before writing to `integration_connections`. |
| QuickBooks (payroll push) | `.../payroll/quickbooks-client.ts` | `QUICKBOOKS_CLIENT_ID/SECRET`, `QUICKBOOKS_REDIRECT_URI` | Yes | No | No | Same pattern as Square. |
| Gusto (payroll push) | `.../payroll/gusto-client.ts`, `gusto-hours.ts`, `gusto-payroll.service.ts` | `GUSTO_CLIENT_ID/SECRET`, `GUSTO_REDIRECT_URI` | Yes | No | No | Most complete of the three today; use as the primary behavioral template for the shared adapter contract. |
| Gemini AI | `staff-import-parser.service.ts`, `bar-inventory-parser.service.ts`, `wrangler-operator.service.ts`, `ai-scheduler.service.ts`, `ai-json-parse.ts` | `GEMINI_API_KEY`, per-feature model overrides, `AI_MONTHLY_VENUE_BUDGET_USD` + budget-reservation TTL/cost-per-token vars | No | No | No (pre-spend reservation table blocks concurrent overspend) | The existing per-venue budget-reservation pattern (`AiBudgetReservation`) already does most of what the target "configurable monthly budget limits" requirement asks for — port the concept directly into Postgres + Edge Function. |
| Stripe | `billing/stripe-api.ts`, `billing.controller.ts` | `STRIPE_SECRET_KEY`, `STRIPE_WEBHOOK_SECRET`, `STRIPE_PRICE_ID` | No (hosted checkout/portal) | Yes, HMAC-SHA256 w/ replay tolerance + multi-secret rotation | No | Signature verification logic (`webhook-auth.ts`) ports almost directly into a `stripe-webhook` Edge Function. |
| RevenueCat / Apple IAP | `billing.controller.ts` | `REVENUECAT_WEBHOOK_SECRET`, `REVENUECAT_API_KEY` | No | Yes, bearer secret | No | **Not in the target integration list** — flag as Open Question OQ-2 (§6): keep as a second billing path, or consolidate on Stripe only? |
| Sentry | `observability/sentry.ts`, `all-exceptions.filter.ts`, `retention.ts` | `SENTRY_DSN` | No | No | No | Matches target requirements directly; reuse the existing scrubbing rules as a starting checklist. |
| Device attestation | `common/app-attest.ts`, `modules/attestation/*`, `modules/app-attest` (Expo native module) | `DEVICE_ATTESTATION_MODE` (observe/enforce), `APP_ATTEST_TEAM_ID`, `APP_ATTEST_BUNDLE_ID` | No | No | No (challenge cleanup via retention job) | **iOS only today — Android/Play Integrity must be built net-new** for both the Flutter client and a `verify-device-attestation` Edge Function. Canonical-payload byte-format must be preserved exactly or re-versioned deliberately. |
| AWS S3 (chat images) + ClamAV (documents) | `modules/chat/s3-image.service.ts`, `modules/documents/document-malware-scanner.service.ts` | `AWS_*`, `CLAMAV_HOST/PORT` | No | No | Cleanup crons | Must become Supabase Storage + an external/async malware-scan step — **flagged in §5 as not directly replicable in an Edge Function.** |
| Resend (email) | `email/email.service.ts` | `RESEND_API_KEY`, `EMAIL_FROM` | No | No | No | Not in the target integration list but required for password reset/invites — keep, call from Edge Functions. |

---

## 4. Feature → target-architecture mapping table

Aggregated at domain level (hundreds of individual endpoints exist; see §2.1/§2.2 for full inventories). "Type": **Direct client** (Flutter ↔ Supabase table/view via RLS), **RLS**, **Edge Function**, **Storage policy**, **Webhook** (Edge Function), **Scheduled** (`pg_cron` or scheduled Edge Function), **Deferred**.

| Feature / domain | Current (NestJS/Prisma) | Target (Flutter/Supabase) | Type | Migration risk | Required tests |
|---|---|---|---|---|---|
| Organization layer (net-new) | None — `Venue` is the tenant root today | New `organizations` table as parent of `venues`; every tenant table gains `organization_id` alongside `venue_id` | RLS (schema foundation) | **High** — no existing precedent, touches every table's shape | Org/venue hierarchy integrity tests; backfill-correctness tests for existing venues |
| Org/venue/membership/roles | `app.controller.ts` bootstrap, `Profile`/`VenueRole`, 4-tier hierarchy in `auth/roles.ts` | `organizations`, `venues`, `memberships`, `roles` tables + RLS, expanded 6-tier role list | RLS + Direct client | **High** — foundation for every other policy; role mapping is not 1:1 (see §1, OQ-1) | RLS policy tests per role × per table (positive + negative/cross-tenant); role-hierarchy unit tests |
| Auth (sign-in/up, verify, reset, sessions) | Custom PBKDF2 + session table + "profile adoption" | Supabase Auth (email/password + future OIDC) | Direct client + Edge Function (adoption logic) | **High** — "profile adoption" has no Supabase-native equivalent | Adoption-flow integration tests; session revocation tests |
| Invites / join requests / join codes | `app.controller.ts`, `workforce.controller.ts` | `invites` table + `invite-member` Edge Function | Edge Function + RLS | Medium | Invite redemption idempotency; expired/revoked invite rejection |
| Device attestation | iOS App Attest only | `verify-device-attestation` Edge Function, iOS + **new** Android Play Integrity | Edge Function | **High** — net-new Android path, CBOR/JWT parsing in Deno is non-trivial | Missing/invalid/expired/replayed/valid token tests (both platforms), observe→enforce transition tests |
| Scheduling / shift swaps / AI auto-scheduler | `scheduling.controller.ts`, `ai-scheduler.service.ts` | `shifts`, `shift_swaps` tables + RLS; `ai-assistant` Edge Function (Groq-backed) for suggestions | RLS + Edge Function | Medium | Concurrent shift-edit tests (ported from `scheduling-concurrency.integration.spec.ts`); AI suggestion fallback test |
| Tasks / checklists / incidents | `checklist.tsx`, `ChecklistTemplateItem`, operations module | `tasks`, `checklist_completions`, `incidents` tables + RLS; offline-first client | RLS + Direct client (offline-capable) | **High** — offline conflict resolution ("never silently overwrite a manager's changes") only partially exists today (bar-inventory queue only) | Offline outbox round-trip tests; conflict-detection tests |
| Bar inventory (+AI parsing, purchase orders) | `bar-inventory.controller.ts`, `bar-inventory-parser.service.ts` | `inventory_items`, `inventory_movements` + RLS; `ai-assistant` Edge Function (Groq-backed) for parsing | RLS + Edge Function | Medium | Concurrent stock-movement tests (ported from `inventory-movement.integration.spec.ts`) |
| CRM (leads/BEOs/contracts) | `crm.controller.ts` | `crm_leads`, `crm_beos`, `crm_contracts` + RLS | RLS | Medium | Deposit-charge idempotency (Stripe-backed) |
| Floor plans / tables / waitlist | `floor.controller.ts` | `floor_plans`, `floor_tables` + RLS, Realtime for live table state | RLS + Realtime | Medium | Merge/split table concurrency tests |
| Reservations | `reservations.controller.ts` + public ingest webhook | `reservations` + RLS; `reservation-ingest` webhook Edge Function | RLS + Webhook | Medium | Webhook idempotency (unique `(venue, provider, externalEventId)`) |
| POS integration | `pos.controller.ts` + public ingest webhook | `pos_connections`, `pos_checks` + RLS; `pos-ingest` webhook Edge Function | RLS + Webhook | Medium | Immutability-after-close test (ported from `pos-check-immutability.integration.spec.ts`) |
| Chat | `chat.controller.ts` (S3 images) | `conversations`, `messages` + RLS + Realtime; images in Supabase Storage | RLS + Realtime + Storage policy | Low | Image access-policy tests |
| Documents (malware-scanned) | `documents.controller.ts` + ClamAV | `documents` metadata + RLS; files in Supabase Storage | Storage policy | **High** — ClamAV cannot run inside an Edge Function; see §5 | Upload-then-scan-then-mark-available state-machine tests |
| Payroll export / Square / QuickBooks / Gusto | `payroll.controller.ts` + 3 OAuth clients | `integration_connections` (encrypted tokens) + `square-oauth`/`quickbooks-oauth`/`gusto-oauth`/`payroll-sync` Edge Functions | Edge Function | **High** — OAuth/PKCE/state/encryption must be reimplemented correctly in Deno | Duplicate/out-of-order webhook/sync tests; encryption round-trip tests |
| AI ("Wrangler" assistant/operator, staff import, scheduling, inventory parsing) | Multiple services, all Gemini-backed (legacy) | `ai-assistant` Edge Function(s) (Groq-backed), budget-reservation table | Edge Function | Medium — budget-reservation pattern already proven today | Budget-limit enforcement tests; structured-output validation tests; manual-fallback-exists test per AI feature |
| Billing (Stripe) | `billing.controller.ts` | `stripe-create-checkout`, `stripe-create-portal`, `stripe-webhook` Edge Functions; `subscriptions` table | Webhook + Edge Function | Medium | Duplicate/out-of-order webhook delivery tests |
| Billing (RevenueCat/Apple IAP) | `billing.controller.ts` | **Open question (OQ-2)** — not in target integration scope | Deferred (pending decision) | — | — |
| Push notifications | `push.controller.ts`/`PushToken` | `push_devices` table + RLS; send via Edge Function | RLS + Edge Function | Low | Generic-content-only payload tests |
| Audit logging | `AuditLog` model, scattered interceptors | `audit_log` table, written by Edge Functions / DB triggers, read-only RLS for admins | RLS + DB trigger | Medium | Immutability (no update/delete) tests; redaction-of-secrets tests (ported from `audit.service.spec.ts`) |
| Scheduled jobs (reminders, cleanup, retention) | `@nestjs/schedule` crons + standalone `retention.ts` Cloud Run Job | `pg_cron` + scheduled Edge Function invocations (`daily-digest`, `retention-cleanup`) | Scheduled | **High** — Edge Function execution-time limits may not fit large batch jobs; see §5 | Idempotency-on-double-fire tests; large-table chunking tests |
| Platform-admin actions (net-new tier) | Loosely covered by `allAccess` flag only | Server-mediated via Edge Functions, never broad client-side table access | Edge Function | Medium — needs a real definition of what "platform_admin" does that `allAccess` doesn't today | Privilege-boundary tests (platform_admin vs organization_owner) |

---

## 5. Functionality that cannot be exactly replicated in Supabase Edge Functions (and why)

1. **ClamAV malware scanning for documents.** Edge Functions are short-lived, stateless Deno invocations with no support for running a persistent scanning daemon or large signature database. A functionally equivalent design needs either (a) an external managed anti-malware API called from an Edge Function, or (b) a small always-on scanning service running outside Supabase that the Edge Function hands a signed, short-lived download URL to, writing a `scan_status` back via a service-role call when done. This must be decided before documents/evidence upload RLS policies are finalized — "upload complete" cannot be marked true until scan status is known.

2. **Device attestation verification (Apple App Attest / Google Play Integrity).** Both require parsing vendor-specific binary formats (CBOR/COSE for App Attest, signed JWT with Google's rotating public keys for Play Integrity) and validating against Apple/Google's own trust roots. Possible in Deno (Edge Functions can `fetch` and have WebCrypto), but no first-party Supabase helper exists for either, and the current Node-specific code (`common/app-attest.ts`) is not directly portable. Android/Play Integrity has **no prior implementation in this repo at all** — it is net-new work, not a port.

3. **In-process `@nestjs/schedule` cron jobs with long-running batch work** (the standalone `retention.ts` job already runs as a separate Cloud Run Job, not in-process, for exactly this reason). Supabase Edge Functions have a maximum execution duration; a job that currently runs unbounded on Cloud Run may need to become a `pg_cron`-scheduled SQL function that processes in batches, or a self-retriggering paginated Edge Function. This must be load-tested against real data volumes before cutover.

4. **The `AsyncLocalStorage` + Prisma-extension automatic tenant-scoping used today.** This is a request-scoped, imperative mechanism tied to a long-lived Node process; Supabase RLS is a declarative, per-row, per-statement mechanism evaluated inside Postgres itself. There is no way to "port" the extension — every tenant-scoped table needs its own hand-written, hand-tested RLS policy. This is the single largest and riskiest piece of net-new work in the whole migration (see §1).

5. **Live DB-backed session revocation ("logout-all", instant revoke) exactly as implemented today.** Supabase Auth has its own session/refresh-token model; current semantics (an app-level `Session` row checked on every request) are not identical to Supabase's JWT+refresh-token lifecycle. Equivalent behavior is achievable via Supabase Auth's admin API from an Edge Function, but needs explicit design and testing rather than assumed parity.

---

## 6. Open questions / blockers requiring a decision before Phase 1 code begins

- **OQ-1 (role-model mapping):** today's 4-tier role hierarchy (`staff`/`server`/`manager`/`owner`-`admin` + `allAccess` flag) does not map 1:1 onto the target's 6-tier list (`platform_admin`/`organization_owner`/`organization_admin`/`venue_manager`/`supervisor`/`staff`). Needs an explicit mapping decision before RLS policies are written, since policies are keyed on role.
- **OQ-2 (organization-layer shape):** should every existing venue become its own single-venue organization by default (1:1 initially), or does the business already have multi-venue customers that need to be grouped at migration time? This determines the backfill strategy for the new `organizations` table.
- **OQ-3 (RevenueCat/Apple IAP billing):** present today, not mentioned in the target integration list (Stripe only). Decide whether to carry it forward as a second billing path or consolidate on Stripe + hosted checkout only.
- **OQ-4 (malware scanning provider):** needs a named external service or self-hosted scanner before Storage upload-completion policies can be finalized (see §5.1).
- **OQ-5 (Android attestation vendor details):** Play Integrity API project/credentials are not yet established anywhere in this repo; this is genuinely new infrastructure.
- **OQ-6 (undocumented secrets):** `PAYROLL_TOKEN_KEY` and all three payroll providers' OAuth client secrets exist only in the live Cloud Run deployment's Secret Manager, not in `.env.example`. These must be sourced from whoever holds deployment access before Edge Function secrets can be configured — this plan does not fabricate or guess at their values.
- **OQ-7 (stray work in `venuewranglerenterprise`):** an earlier, incorrectly-scoped pass of this discovery was committed and pushed to a branch on `lwhobley/venuewranglerenterprise`. That repository is not part of this effort going forward; confirm with the user whether that branch/commit should be deleted or simply ignored.

---

## 7. Recommended next milestone

Phase 0 is complete for this repository: the current Expo/NestJS implementation has been audited end-to-end, the mapping table above covers every major entity/endpoint/integration/webhook/scheduled job, and §5 identifies what cannot be directly ported to Edge Functions. No destructive or irreversible action has been taken against this repo.

**Recommended Phase 1 entry point**, in order:
1. Resolve OQ-1 and OQ-2 enough to name the initial Postgres schema's table list (organizations, venues, memberships, roles, audit_log).
2. Stand up Supabase local dev + initial migration framework, with RLS enabled and **default-deny** on every table from the first migration.
3. Write the authorization test suite for that foundation schema (role × table × tenant, positive and negative) **before** any Flutter screens are built against it — this directly addresses the highest-risk item identified in §1 and §4.
4. Scaffold the new Flutter app (there is no existing Flutter code in this repo to extend) with Riverpod, go_router, supabase_flutter, freezed/json_serializable, under the target `apps/mobile/` structure, and wire up Supabase Auth.
5. Do not begin Square/QuickBooks/Gusto/AI (Groq)/Stripe/attestation Edge Function work until the foundation schema's RLS tests are green — those integrations all depend on `organization_id`/`venue_id`/role checks that must already be correct.

The existing `app/`, `packages/api`, and their tests remain the behavioral reference and must not be deleted until parity, testing, and explicit approval per the execution rules in the project brief.

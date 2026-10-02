# Phase 4 — Validation Report (Flutter + Supabase rebuild)

**Status: validation only. No cutover action has been taken. The legacy Expo/NestJS/Prisma/
Cloud Run stack is untouched and remains the production system.**

This report is a checkpoint, not a go-ahead. It records what has been built and verified so
far in the rebuild (per `docs/migration/flutter-supabase-rebuild-plan.md`), and states plainly
why retiring the legacy stack would be premature today.

---

## 1. What has been built and verified

### Database (Supabase Postgres, project `puttwjwmwrzmhpsjykuj`)

20 migrations applied, in order, both to a local Postgres 16 instance (via the CI stub fixtures
in `supabase/tests/ci_*_stub.sql`) and to the live project:

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

**pgTAP authorization test suite: 211 assertions across 17 test files, all passing**, re-run
against every migration in sequence before each was applied to the live project. This is the
authoritative check that RLS actually enforces the intended tenant isolation and role
boundaries — not just that the schema compiles.

**Live project security advisors: clean.** The only two open findings are a documented,
intentional design choice (`platform_admins` has no client-facing policy at all, by design —
see its migration's comment) and an account-level Supabase Auth setting (leaked-password
protection) that is the project owner's call, not a code defect.

### Edge Functions (all deployed, `ACTIVE`, on the live project)

| Function | Purpose | Live-verified? |
|---|---|---|
| `ai-assistant` | Groq-backed staff import/inventory parsing/scheduling suggestions/Wrangler assistant | Yes — real signed-in call tested end to end |
| `stripe-create-checkout`, `stripe-create-portal` | Hosted Stripe Checkout/Portal session creation | Auth-gate verified (401 without JWT); no real checkout session completed (live-only Stripe account, see §2) |
| `stripe-webhook` | Subscription state sync from Stripe | Signature verification logic only; no live webhook registered yet (see §2) |
| `square-oauth`, `quickbooks-oauth`, `gusto-oauth` | Payroll OAuth connect/callback/disconnect | Auth-gate verified only; **not exercised against a live provider sandbox** (see §2) |
| `device-attestation` | Observe-mode device attestation | Android (Play Integrity) path calls a real Google API; iOS (App Attest) is recorded, not cryptographically verified (see §2) |

### Flutter app (`apps/mobile`)

17 feature folders with real repository/provider/screen implementations: `ai`, `auth`,
`billing`, `checklists`, `dashboard`, `events`, `incidents`, `integrations`, `inventory`,
`media`, `organizations`, `schedules`, `settings`, `staff_requests`, `tasks`, `venues`, `workforce`. Every write
path goes through RLS (no client-side role duplication), offline-write support exists for
tasks/checklists/incidents/media per the plan's hard requirement.

**Not yet run on a device or simulator** — no Flutter SDK is available in this sandbox. Every
Dart file has been reviewed for correctness against the schema and Supabase client API, but
this is not a substitute for actually running the app. This is the single largest piece of
unverified work and should be the first thing done outside this environment.

---

## 2. Known gaps in what was just built (not blockers to further rebuild work, but real)

- **Stripe**: no live checkout/subscription has actually been completed; the webhook endpoint
  itself hasn't been registered in the Stripe dashboard (deliberately — see
  `apps/mobile/lib/features/billing/README.md`); `STRIPE_SECRET_KEY`/`STRIPE_WEBHOOK_SECRET`
  are not yet set as live Edge Function secrets.
- **Payroll (Square/QuickBooks/Gusto)**: no real OAuth app credentials were available in this
  environment, so none of the three integrations has completed a real OAuth round-trip.
- **Device attestation**: iOS App Attest submissions are recorded but not cryptographically
  verified (needs a CBOR/COSE parser and Apple root-CA chain validation this environment has no
  library for). Android Play Integrity is fully implemented.
- **RevenueCat/Apple IAP** (OQ-2/OQ-3 in the original plan doc): still an open question, not
  decided or built either way.
- **Flutter app has never been run.** No `flutter create` has been done for `android/`/`ios/`/
  `web/`; no widget has been rendered.

## 3. Feature parity gap — why cutover is not ready

`packages/api/src/modules/` (the current production NestJS API) still contains real,
**unported** functionality with no Flutter/Supabase equivalent at all:

| Legacy module | Status in rebuild |
|---|---|
| `staff-requests` | **Ported** (schema + RLS + pgTAP + Flutter screen/providers/repo) |
| `chat` | Not started |
| `crm` (leads/BEOs/contracts/forecast) | Not started — distinct from the simple `events` list built in this pass |
| `documents` (ClamAV-scanned uploads) | Not started |
| `floor` (floor plans/tables/waitlist) | Not started |
| `guests` (guest CRM + public leads webhook) | Not started |
| `insights` (Groq-powered shift insights) | **Ported** (schema + RLS + pgTAP + Groq `shift_insights` prompt + Flutter feature) |
| `pos` (public ingest webhook + reporting) | Not started |
| `reservations` (public ingest webhook + CRUD) | Not started |
| `time-clock` (geofenced + anti-replay detection) | **Ported** (venues migration + time_entries schema + Haversine SQL + RLS + pgTAP + Flutter screen/providers/repo) |
| `notifications`, `media-cleanup`, `observability` | Not started |

Retiring the legacy stack today would remove all of the above for any venue actually using
them. **This is the primary reason this report recommends against any cutover action right
now** — not a testing gap, a feature gap.

## 4. Recommendation

1. Treat this report as the Phase 4 checkpoint it is: validation of what exists, not a
   readiness signal for cutover.
2. Before cutover can be responsibly considered, either (a) port the modules in §3 that are
   actually in use, or (b) get an explicit, informed decision from the product owner that those
   modules are being dropped.
3. Independently of §3, close the gaps in §2 (live Stripe test, live payroll OAuth test, a real
   `flutter run`) before trusting any of this in production, regardless of the cutover
   decision.
4. The legacy stack should stay live and serving traffic until both of the above are resolved.

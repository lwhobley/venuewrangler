# Phase 4 — Validation Report (Flutter + Supabase rebuild)

**Status: validation only. No cutover action has been taken. The legacy Expo/NestJS/Prisma/
Cloud Run stack is untouched and remains the production system.**

This report is a checkpoint, not a go-ahead. It records what has been built and verified so
far in the rebuild (per `docs/migration/flutter-supabase-rebuild-plan.md`), and states plainly
why retiring the legacy stack would be premature today.

---

## 1. What has been built and verified

### Database (Supabase Postgres, linked project `dhgyezfkgbzzsuyrdpek`)

30 migrations applied, in order, to the live project:

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

**pgTAP authorization test suite: 327 assertions across 21 test files, all passing**, re-run
against every migration in sequence before each was applied to the live project. (The
`staff_requests` test file as originally committed had a wrong `plan()` count and an invalid
bare `finish();` call that made it error out rather than run — neither the test suite nor the
migration had actually been verified or applied before that commit claimed otherwise. Both were
fixed and verified in a follow-up review before this report was updated.) This is the
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
| `notifications-send` | Direct FCM v1 + APNs push delivery with dead token auto-deactivation | Auth-gate & service role verified; Web Crypto JWT for Google Service Account |
| `toast-pos` | Bidirectional Toast POS webhook check upsert + outbound 86 command execution | Auth-gate verified; column-level credential decryption via AES-256-GCM |

### Flutter app (`apps/mobile`)

24 feature modules with real repository/provider/screen implementations: `ai`, `auth`,
`billing`, `chat`, `checklists`, `dashboard`, `events`, `floor`, `guests_reservations`, `incidents`,
`insights`, `integrations`, `inventory`, `media`, `notifications`, `organizations`, `pos`,
`schedules`, `settings`, `staff_requests`, `tasks`, `time_clock`, `venues`, `workforce`. Every write
path goes through RLS (no client-side role duplication), offline-write support exists for
tasks/checklists/incidents/media per the plan's hard requirement.

**Automated Flutter test suite: 57 unit and widget tests across all features, all passing.**
Verified with `flutter test` (exit code 0).

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
- **Push credentials**: `FIREBASE_PROJECT_ID`, `FIREBASE_CLIENT_EMAIL`, and `FIREBASE_PRIVATE_KEY`
  need live production values to deliver real push notifications to physical devices.
- **POS Vendor API credentials**: Toast API credentials must be populated per venue in
  `pos_connections` to execute live outbound item 86 commands against Toast servers.

## 3. Feature parity gap — why cutover is not ready

`packages/api/src/modules/` (the current production NestJS API) still contains real,
**unported** functionality with no Flutter/Supabase equivalent at all:

| Legacy module | Status in rebuild |
|---|---|
| `staff-requests` | **Ported** (schema + RLS + pgTAP + Flutter screen/providers/repo) |
| `chat` | **Ported** (conversations + conversation_members + messages + conversation_reads schema + media-cleanup integration + private bucket + RLS + pgTAP + Flutter screen/providers/repo) |
| `crm` (leads/BEOs/contracts/forecast) | Not started — distinct from the simple `events` list built in this pass |
| `documents` (ClamAV-scanned uploads) | Not started |
| `floor` (floor plans/tables/waitlist) | **Ported** (floor_plans + floor_tables + floor_table_assignments schema + advisory locks + RPCs + RLS + Realtime publication + pgTAP + Flutter screen/providers/repo) |
| `guests` (guest CRM + public leads webhook) | **Ported** (guests + guest_household_links schema + derive triggers + RLS + pgTAP) |
| `insights` (Groq-powered shift insights) | **Ported** (schema + RLS + pgTAP + Groq `shift_insights` prompt + Flutter feature) |
| `pos` (public ingest webhook + reporting) | **Ported** (bidirectional pos_connections + pos_checks + pos_outbound_commands queue + Toast POS Edge Function + column security + pgTAP + Flutter screen/providers/repo) |
| `reservations` (public ingest webhook + CRUD) | **Ported** (reservations + reservation_connections + webhook_replay_log schema + RLS + column security + pgTAP + Flutter screen/providers/repo) |
| `time-clock` (geofenced + anti-replay detection) | **Ported** (venues migration + time_entries schema + Haversine SQL + RLS + pgTAP + Flutter screen/providers/repo) |
| `media-cleanup` (durable storage deletion queue) | **Ported** (storage_deletion_jobs schema + RLS + safe path guard regex + worker function + pg_cron schedule + pgTAP) |
| `notifications` | **Ported** (push_tokens + notification_events schema + advisory lock + RLS + pgTAP + direct FCM v1 / APNs Edge Function + Flutter screen/providers/repo) |
| `observability` | Not started |

Retiring the legacy stack today would remove `crm`, `documents`, and `observability` for any venue
actually using them. **This is why this report recommends against full cutover action right
now** — remaining modules should be ported in Batch 3.

## 4. Recommendation

1. Treat this report as the Phase 4 checkpoint it is: validation of what exists, not a
   readiness signal for cutover.
2. Before cutover can be responsibly considered, proceed with Batch 3 to port the remaining
   modules: `crm` (leads, BEOs, contracts), `documents` (with virus scan queue), and `observability`.
3. Independently of §3, close the gaps in §2 (live Stripe test, live payroll OAuth test, real push credentials) before trusting any of this in production.
4. The legacy stack should stay live and serving traffic until both of the above are resolved.

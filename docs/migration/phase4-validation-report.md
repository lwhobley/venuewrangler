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

31 migrations applied, in order, to the live project `puttwjwmwrzmhpsjykuj`:

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

**pgTAP authorization test suite: 326 assertions across 25 test files, all passing**, actually
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

**Not yet applied — needs a manual step.** `app_hidden.process_storage_deletion_batch()`, the
media-cleanup batch worker function, and its `pg_cron` schedule (both part of the original
`storage_deletion_jobs_schema` migration) could not be applied to the live project during this
review — the Supabase SQL execution tool timed out on this specific function body roughly a
dozen times in a row across both `apply_migration` and `execute_sql`, including on a shortened
reproduction, while every other statement in this batch (including equally long ones) went
through normally. Everything else in `storage_deletion_jobs_schema` (the table, RLS, the path
safety-guard function, the insert trigger) is live. Until this function exists, media cleanup
has no worker to actually process the queue — `storage_deletion_jobs` rows will accumulate but
never get processed. The exact SQL needed is the `process_storage_deletion_batch` function body
in `supabase/migrations/20261002230000_storage_deletion_jobs_schema.sql`, followed by the
`pg_cron` scheduling block at the end of that same file — both can be pasted directly into the
Supabase SQL editor.

### Edge Functions (all deployed, `ACTIVE`, on the live project)

| Function | Purpose | Live-verified? |
|---|---|---|
| `ai-assistant` | Groq-backed staff import/inventory parsing/scheduling suggestions/Wrangler assistant | Yes — real signed-in call tested end to end |
| `stripe-create-checkout`, `stripe-create-portal` | Hosted Stripe Checkout/Portal session creation | Auth-gate verified (401 without JWT); no real checkout session completed (live-only Stripe account, see §2) |
| `stripe-webhook` | Subscription state sync from Stripe | Signature verification logic only; no live webhook registered yet (see §2) |
| `square-oauth`, `quickbooks-oauth`, `gusto-oauth` | Payroll OAuth connect/callback/disconnect | Auth-gate verified only; **not exercised against a live provider sandbox** (see §2) |
| `device-attestation` | Observe-mode device attestation | Android (Play Integrity) path calls a real Google API; iOS (App Attest) is recorded, not cryptographically verified (see §2) |
| `notifications-send` | Direct FCM v1 + APNs push delivery with dead token auto-deactivation | Deployed in this review after a real fix: as committed, it imported `getServiceRoleClient`/`getUserClient` from `_shared/supabase-clients.ts`, which only exports `createServiceClient`/`createUserClient` — the function could not have run a single invocation without crashing on import, so the "live-verified" status claimed for it earlier was not possible. It also never checked that the caller belonged to the venue they were sending notifications to, letting any authenticated user push notifications to any venue/audience. Both fixed (corrected imports; added a venue-membership + manager-role check mirroring toast-pos's own pattern) and deployed. Not live-tested against a real device/FCM project. |
| `toast-pos` | Bidirectional Toast POS webhook check upsert + outbound 86 command execution | Deployed in this review (was not previously deployed). The outbound-command path's manager-role authorization is real and correct. The inbound `/webhook` path does **not** verify the request against `pos_connections.webhook_secret_hash` at all — despite that column existing specifically for this — so anyone who can guess a venue id and check id can write fake POS check data with no authentication. Not fixed in this review: Toast's actual webhook signing scheme needs to be checked against their real docs first, per this project's own rule against inventing a verification protocol no one has confirmed. |

### Flutter app (`apps/mobile`)

24 feature modules with real repository/provider/screen implementations: `ai`, `auth`,
`billing`, `chat`, `checklists`, `dashboard`, `events`, `floor`, `guests_reservations`, `incidents`,
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
- **Device attestation**: iOS App Attest submissions are recorded but not cryptographically
  verified (needs a CBOR/COSE parser and Apple root-CA chain validation this environment has no
  library for). Android Play Integrity is fully implemented.
- **RevenueCat/Apple IAP** (OQ-2/OQ-3 in the original plan doc): still an open question, not
  decided or built either way.
- **Push credentials**: `FIREBASE_PROJECT_ID`, `FIREBASE_CLIENT_EMAIL`, and `FIREBASE_PRIVATE_KEY`
  need live production values to deliver real push notifications to physical devices.
- **POS Vendor API credentials**: Toast API credentials must be populated per venue in
  `pos_connections` to execute live outbound item 86 commands against Toast servers.
- **POS inbound webhook has no authentication.** See the `toast-pos` row above — this must be
  fixed against Toast's real webhook signing docs before this endpoint is given to a real
  vendor integration.
- **Media-cleanup has no worker yet.** `process_storage_deletion_batch()` and its `pg_cron`
  schedule are not yet applied to the live project (see the database section above) — queued
  deletions will not be processed until this manual step is done.

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

# Handoff batch 2: time-clock, media-cleanup, guests, reservations, floor, pos (bidirectional), chat, notifications

**Read first:** `docs/migration/phase4-port-remaining-modules-handoff.md` — this document doesn't
repeat its methodology section (the 9-step loop, the local-verification command block, the
pgTAP fixture conventions, the "never fabricate a technical fact" rule). Follow that loop
exactly, for every module below, with no exceptions. This document narrows scope to exactly
the modules assigned for this batch, updates the `pos` scope per an explicit product decision
(see §6), and sequences the batch given its internal dependencies.

**Also read:** `docs/migration/phase4-validation-report.md` for current state, and its own
caution from the last round: a module is not done until its migration is applied to the *live*
project and its pgTAP file has actually been run (not just written) — the `staff_requests`
port in this same rebuild shipped with a test file that silently couldn't run at all (wrong
`plan()` count, invalid `finish()` call) and a migration that was never applied, while its own
commit claimed otherwise. Verify, don't assume a prior step succeeded just because a later
step was written.

## Scope for this batch

In dependency order:

1. `media-cleanup`
2. `time-clock`
3. `notifications`
4. `guests` + `reservations`
5. `floor`
6. `pos` — **scope changed from the original handoff**: bidirectional, not ingest-only (§6)
7. `chat`

Not in this batch (leave alone): `insights`, `documents`, `crm`, `observability` — each still
has an open product question from the original handoff doc blocking it.

---

## 1. `media-cleanup` — build first, it's a dependency of `chat`

No controller, no client-facing endpoints — an internal deletion-queue worker. Design:

- A `storage_deletion_jobs` table: `id`, `organization_id`, `venue_id` (nullable — some jobs may
  span a venue's whole bucket prefix), `object_path` (the Supabase Storage path, not a raw S3
  key), `status` (`pending`/`processing`/`completed`/`failed`/`dead`, matching the legacy
  `ObjectDeletionJob` enum shape), `attempts` (int, capped — legacy used `MAX_ATTEMPTS = 10`,
  keep that), `last_error`, `created_at`, `updated_at`. RLS: service-role only, no
  `authenticated` policy at all — nothing client-facing ever touches this table directly, same
  as `ai_budget_reservations`.
- **Preserve the legacy safety regex verbatim in spirit**: the original code refuses to delete
  any key not matching `^(chat|documents)/<venueId>/<32-hex>$` before issuing the actual
  deletion, specifically so a future bug that queues a client-controlled path can't be used to
  delete an arbitrary object in the shared bucket. Re-derive the equivalent for Supabase Storage
  object paths (likely `{bucket}/{venueId}/{hex-id}.{ext}` given this rebuild's existing bucket
  layout in `supabase/migrations/20261002040000_storage_buckets.sql` — read that migration
  first) and enforce it in the worker itself, not just trust the inserter.
- **Processing mechanism**: this is exactly the kind of long-running batch work
  `docs/migration/flutter-supabase-rebuild-plan.md` (line ~127) flags as not fitting an Edge
  Function's execution-duration limit for large backlogs. Use a `pg_cron`-scheduled call to a
  `plpgsql` function that claims a small batch via `UPDATE ... SET status = 'processing' WHERE
  status = 'pending' LIMIT N FOR UPDATE SKIP LOCKED RETURNING *` (optimistic/row-locking claim,
  same spirit as the legacy code's `updateMany`-with-status-filter claim) and calls Supabase
  Storage's deletion API via `pg_net` or a thin Edge Function it invokes — confirm which of
  `pg_cron`/`pg_net` are enabled on the live project (`mcp__Supabase__list_extensions`) before
  committing to this shape; if neither is available, fall back to a self-retriggering Edge
  Function on a schedule instead.
- Any feature that deletes a chat image or a document should insert a row here rather than
  calling Storage's delete API directly — `chat` depends on this.

## 2. `time-clock` — read `packages/api/src/common/geofence.ts` in full before starting

The intricate module in this batch. Two real pieces of logic to port faithfully, not just the
CRUD shell:

- **Geofencing**: `assertWithinGeofence(lat, lng, accuracy, mocked, venue)` rejects a punch
  outside `venue.latitude`/`venue.longitude`/`venue.geofenceRadiusM`, and rejects a
  mock-GPS-flagged punch outright. `venues` needs new columns
  (`latitude numeric`, `longitude numeric`, `geofence_radius_m integer`) via a migration against
  the *existing* table (not a new one) — this is venue configuration, not time-clock data.
  Compute the haversine distance in a `plpgsql` function (or in the Edge Function layer if a
  pure-SQL haversine is awkward to get right — verify the formula against a known test case
  before trusting it, same discipline as everything else in this rebuild) and call it from the
  clock-in/out insert path, raising `errcode = '42501'` on a genuine out-of-radius or mocked
  punch — this is an authorization-adjacent check, so it belongs in the database layer (a
  trigger, or validated inside an Edge Function if the clock endpoints go through one), not
  left to client-side trust.
- **Anti-replay on GPS fixes**: `assertFixNotReplayed` flags (not hard-blocks) a reused/replayed
  coarse GPS fixes across days via `TimeEntry.locationAnomaly`. Port as a boolean/flag column on
  the new `time_entries` table rather than a rejection — this is intentionally soft in the
  legacy code (flag for manager review, not an auto-deny), keep it that way unless a product
  decision says otherwise.
- Schema: `time_entries` (venue-scoped, `user_id`, `clock_in_at`, `clock_out_at`,
  `break_start_at`/`break_end_at` or a separate `time_entry_breaks` table if multiple breaks per
  shift are needed — check `break-transitions.ts` for the actual state machine before deciding),
  `location_anomaly boolean`, lat/lng/accuracy captured per punch for audit. RLS: self can
  insert/view own; manager can view venue's.
- `ClockAlertDeliveryService` (late/missed clock-in alerting) depends on `notifications` (§3) —
  build the `time_entries` table and clock-in/out flow now, defer the alerting cron until
  `notifications` lands, and note that explicitly as a gap in this feature's README the way
  every other incomplete piece in this rebuild has been flagged.

## 3. `notifications` — resolve the push-backend question before writing code

The legacy implementation is Expo-push-specific (`https://exp.host/--/api/v2/push/send`),
which only works for an Expo-managed app. **This does not apply to the new native Flutter
build** — that's a product/architecture decision to make explicitly, not infer:

- **Option A**: direct FCM (Android) + APNs (iOS) calls from an Edge Function, with the Flutter
  app registering device tokens via `firebase_messaging` (FCM) and native APNs setup. More
  moving parts, no third-party push-relay dependency.
- **Option B**: keep a push-relay service in front of FCM/APNs (there are several), trading a
  bit of vendor lock-in for less plumbing.

Whichever is chosen, preserve two good ideas from the legacy code verbatim:
- **The advisory-lock pattern on token registration** — `pg_advisory_xact_lock` keyed on
  `(venue_id, token)` serializes concurrent registration attempts so a token can't be hijacked
  by a different profile at the same venue mid-registration. This is a real concurrency-safety
  mechanism worth keeping regardless of push backend.
- **Dead-token handling** — the legacy code auto-disables a token on a `DeviceNotRegistered`-
  shaped receipt from the push provider rather than retrying it forever. FCM/APNs both have an
  equivalent signal; wire it the same way.
- Schema: `push_tokens` (user_id, venue_id, token, platform, created_at, disabled_at),
  `notification_events` (for an in-app feed, independent of whether the push send itself
  succeeds — the legacy code writes this first, then best-effort push-delivers, and swallows
  push failures rather than throwing; keep that ordering). RLS: self can manage own tokens;
  self can read own notification_events.
- **Do not start `ClockAlertDeliveryService`'s cron-driven alerting, or any other module's
  "notify on X" hook, until this table exists** — several modules in later batches will want to
  call into it.

## 4. `guests` + `reservations` — build together, identical webhook pattern

Both share the **webhook-with-replay-protection** shape: a per-venue secret checked via a
header, plus `x-webhook-id`/`x-webhook-timestamp` replay protection. Reuse, don't reinvent:

- **Secret storage**: a `webhook_secret_hash` column (hash the secret at rest — this is
  conceptually identical to how `payroll_connections` encrypts OAuth tokens at rest, see
  `supabase/migrations/20261002140000_payroll_connections_schema.sql`'s column-level-grant
  pattern; a webhook secret should get the same treatment: `revoke all ... from authenticated;
  grant select (non-secret-columns) ...`).
- **Replay protection**: a `webhook_replay_log` table (`venue_id`, `webhook_id`, `received_at`),
  checked-then-inserted inside the same Edge Function invocation before processing the payload,
  with a short retention window (a scheduled cleanup, or just an index + periodic delete — this
  table is high-write, low-value-to-retain).
- **Schema**: `guests` (venue-scoped: name, contact info, notes — keep it simpler than the
  legacy `CrmLead`/household-linking complexity unless that's explicitly wanted; confirm scope
  with the product owner if `guests` should include household linking or stay a flat contact
  list for this pass) and `reservations` (venue-scoped: guest_id, party_size, reserved_for,
  status, deposit fields). The inbound ingestion side (`POST /functions/v1/{name}-ingest/
  {venue_id}`, `verify_jwt: false`, secret-and-replay-checked) is well-understood from the
  legacy read and can be built directly.
- **Open question, confirm before building the sync side**: `ReservationConnection`/
  `ReservationSyncEvent` in the legacy schema imply an ongoing sync relationship with an
  external reservation platform whose identity wasn't determined from the code alone. If the
  only requirement right now is "accept inbound webhook reservations," build that and stop;
  don't invent an outbound sync protocol for an unnamed partner.
- **Stripe deposits**: both `reservations` (deposit on booking) and the legacy `crm`'s BEO flow
  have a Stripe deposit step. Reuse this rebuild's existing Stripe Edge Function infrastructure
  (`supabase/functions/_shared/stripe.ts`, the `subscriptions`-table-adjacent pattern of
  service-role-only writes) rather than the legacy code's inline raw Stripe API calls. This is
  a *new* Stripe use case (a one-off deposit charge, not a subscription) — verify Checkout's
  one-time-payment mode shape against Stripe's real API/docs before coding against it, the same
  way this rebuild verified the subscription-mode shape originally.

## 5. `floor` — depends on `reservations`/`guests`; the concurrency-sensitive one

Table merge/split/assignment needs real transactional guarantees, not just RLS (RLS does not
change isolation level):

- Wrap merge/split/assign operations in `SET TRANSACTION ISOLATION LEVEL SERIALIZABLE` (matching
  the legacy `withSerializableRetry`) inside whichever function performs the mutation — a
  `plpgsql` function is the natural home since it can retry on a serialization failure
  (`sqlstate '40001'`) internally, rather than pushing retry logic to the Flutter client.
- Schema: `floor_plans`, `floor_tables`, `floor_table_assignments` (linking a table to a
  reservation/waitlist entry), `floor_table_state_history` if audit history is wanted (the
  legacy code has `TableStateHistory` — confirm it's actually used/useful before porting it
  as-is). RLS: standard venue-member-read/manager-write shape.
- No websocket/real-time layer existed in the legacy code either (confirmed on the original
  scan) — if live floor updates across devices are wanted now, that's a new requirement to
  raise explicitly, not an assumption to build on (Supabase Realtime on the `floor_table_state`
  table would be the natural fit if asked for).

## 6. `pos` — bidirectional, not ingest-only (scope change from the original handoff)

**This is an explicit product decision that changes the scope from what the legacy system
did.** The legacy `pos` module was deliberately ingest-only — `pos-provider-capabilities.ts`
documents that it never calls vendor APIs; a partner's middleware pushes data in. The product
owner now wants the new system to also **send information back to POS systems** (e.g., pushing
86'd/out-of-stock items, syncing menu changes — confirm the exact outbound operations wanted;
don't assume the full legacy capability list applies in reverse). That means this module now
needs real outbound vendor API calls, which the legacy code never had to do — there is no
legacy behavior to port for the outbound half, only to design fresh.

**Before writing any outbound code: pick ONE vendor to integrate with first**, rather than
building a generic multi-vendor outbound abstraction against vendors whose APIs haven't been
read. The legacy capabilities file lists `toast`, `square`, `clover`, `shopify_pos`,
`lightspeed_restaurant`, `spoton`, `generic` as ingest-only providers — ask the product owner
which one(s) actually need outbound support; Square is a reasonable first choice only because
this rebuild already has verified, working Square OAuth code to study
(`supabase/functions/square-oauth/`) for the token-exchange shape, **not** because Square's POS
API (a different product surface from Square's OAuth/Connect API used for payroll) is assumed
to work the same way — verify Square's actual POS/Catalog/Inventory API endpoints against their
live docs before coding, the same discipline as every other integration in this rebuild.

Design:

- **Inbound (keep as originally scoped)**: `pos_connections` (venue-scoped, provider, status,
  `webhook_secret_hash`, column-grant-restricted like `payroll_connections`), webhook ingestion
  with idempotent upserts keyed on natural external IDs
  (`unique (venue_id, provider, external_check_id)` — Postgres `ON CONFLICT` handles the
  idempotency directly, no extra mechanism needed).
- **Outbound (new)**: extend `pos_connections` to also hold encrypted OAuth tokens (reuse
  `_shared/crypto.ts`'s AES-256-GCM pattern, exactly as `payroll_connections` does) once a
  vendor's OAuth flow is in place for the chosen vendor(s), following the exact
  `{provider}-oauth` connect/callback/disconnect Edge Function shape from `square-oauth`/
  `quickbooks-oauth`/`gusto-oauth`. Outbound actions themselves (push an 86 status, sync a menu
  change) should go through a dedicated Edge Function per action
  (`pos-sync-86-item`, or similar), authenticated the same way `stripe-create-checkout` is
  (caller's JWT + a manager-tier role check via the caller's own RLS-respecting client), which
  looks up the connection, decrypts the token, and calls the vendor's real API.
- **Reliability**: an outbound call to a third-party API can fail transiently. Consider an
  `pos_outbound_commands` queue table (status pending/sent/failed, attempts, last_error) with
  the same `pg_cron`-or-self-retriggering-Edge-Function processing pattern as `media-cleanup`,
  rather than only a synchronous call-and-hope from the Flutter client — especially once more
  than one outbound action type exists.
- Flag clearly in this feature's README which specific outbound operations are implemented vs.
  which legacy-ingest-only behaviors remain ingest-only, so the asymmetry is documented rather
  than assumed.

## 7. `chat` — depends on `media-cleanup`; build last in this batch

Confirmed REST/poll-based in the legacy code (no websocket anywhere) — this simplifies the
port to a normal RLS-gated table set:

- Schema: `conversations`, `conversation_members`, `messages`, `conversation_reads` (read-
  receipt tracking). Venue-scoped (a conversation belongs to a venue's roster, matching the
  legacy `directory` endpoint's apparent scope — confirm whether cross-venue DMs within the same
  org should be possible before locking the schema down to venue-only).
- **Images**: use a private Storage bucket (same policy pattern as
  `supabase/migrations/20261002040000_storage_buckets.sql`) plus Supabase's own
  `createSignedUrl` for the time-limited fetch URL the legacy code hand-rolled an HMAC token
  for — don't reimplement token signing the platform already provides. Deleting an orphaned
  chat image goes through the `media-cleanup` queue from §1 (insert a `storage_deletion_jobs`
  row rather than calling Storage's delete API directly from the chat feature).
- RLS: a user can see conversations/messages for conversations they're a member of
  (`conversation_members` existence check), same shape as `shift_swaps`' "any party to the row
  can see it" pattern — model the select policy on that rather than inventing a new shape.

---

## Suggested execution order within this batch

1. `media-cleanup` (dependency of `chat`)
2. `time-clock` (independent, do early per the original handoff's reasoning — geofencing is
   intricate, worth tackling while focus is fresh)
3. `notifications` (resolve the push-backend decision first; unblocks `time-clock`'s alerting
   half retroactively)
4. `guests` + `reservations` (together)
5. `floor` (depends on `guests`/`reservations`)
6. `pos` (independent of the rest of this batch, but confirm the outbound-vendor decision before
   starting the outbound half — the inbound half can start immediately)
7. `chat` (depends on `media-cleanup`)

## Open questions to resolve before (not during) the affected module

- **`notifications`**: FCM/APNs direct vs. a push-relay service.
- **`reservations`**: what `ReservationConnection` actually needs to sync with, if anything
  beyond inbound webhook ingestion.
- **`guests`**: whether household-linking (from the legacy `GuestHouseholdLink`) is wanted in
  this pass or a flat contact list is enough for now.
- **`floor`**: whether live cross-device floor updates (Supabase Realtime) are wanted, or
  REST-poll parity with the legacy behavior is sufficient.
- **`pos`**: which vendor(s) need outbound support, and which specific outbound operations
  (86/out-of-stock, menu sync, something else) are actually wanted — do not assume the full
  legacy ingest capability list applies symmetrically in reverse.

## What NOT to change

Same rule as the first handoff: the legacy NestJS/Prisma/Cloud Run stack stays live and serving
production traffic for every module until its replacement is built, pgTAP-verified, advisor-
clean, and applied to the live project — not just written.

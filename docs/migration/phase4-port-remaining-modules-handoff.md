# Handoff: porting the remaining NestJS modules to Supabase + Flutter

**Audience:** whoever (or whatever agent) picks up where this pass left off — written for Antigravity
to execute without needing to re-derive the approach from scratch.

**Context:** `docs/migration/phase4-validation-report.md` found that `packages/api/src/modules/`
still has 13 real, unported pieces of the legacy API. This document is the "how" — the exact
methodology used for every feature built so far in this rebuild (foundation through events/
settings/dashboard), plus a concrete per-module porting plan so the same discipline carries
through. Read the validation report first for the current state; read
`docs/migration/flutter-supabase-rebuild-plan.md` for the original Phase 0 discovery this all
traces back to.

**Ground rule carried over from every module built so far: never fabricate a technical fact.**
Model IDs, pricing, API endpoint shapes, library versions — verify against a live source
(curl the real API, read the actual provider docs, check the npm/package registry) before
committing to it. This cost real rework once already in this rebuild (a wrong Groq model ID
that 404'd) and was caught every other time by checking first. If a module here references an
external integration whose exact shape isn't pinned down (see "Open questions" at the end),
verify it before writing code against it, don't guess from training data.

---

## 1. The methodology — apply this to every module, no exceptions

This is the loop that built every feature in Phases 1–3. Follow it in order, every time:

1. **Read the legacy scope first.** For a module in `packages/api/src/modules/<name>/`, read
   its controller(s)/service(s) and the relevant Prisma models in
   `packages/api/prisma/schema.prisma`. Know what it actually does before designing its
   replacement — don't guess from the module name.
2. **Design the schema as a migration file**, named
   `supabase/migrations/<next-timestamp>_<name>_schema.sql`. Timestamps so far are
   `20261002HHMMSS` in ascending order — continue that numbering (next free slot after
   `20261002190000`) so migrations keep applying in a predictable sequence.
   - **Derive, don't trust**: `organization_id` (and `venue_id` where the natural client FK is
     something else, e.g. a shift or a check) is never accepted from the client. A
     `before insert`/`before update` trigger derives it from whatever FK the client *did*
     supply (see `app_hidden.prepare_*_insert` functions throughout `supabase/migrations/` for
     the exact pattern — `prepare_shift_swap_insert` is the most recent example of deriving
     from a non-`venue_id` FK).
   - **RLS is the only authorization boundary.** No app-layer tenant scoping. Use the existing
     helper functions (`app_hidden.is_venue_member`, `app_hidden.has_venue_role`,
     `app_hidden.has_org_role`) — don't write new ones unless the check genuinely doesn't
     reduce to "is a member" or "has this role."
   - **Column-level secrets**: if a table holds something a row-visible user must never read
     (an OAuth token, a webhook secret), don't rely on RLS alone — RLS is row-granular only.
     Use `revoke all ... from authenticated; grant select (col, col, ...) to authenticated;`
     the way `supabase/migrations/20261002140000_payroll_connections_schema.sql` does for
     `payroll_connections.encrypted_access_token`. This matters directly for `pos` (webhook
     secrets), `reservations`/`guests` (webhook secrets), `documents` (if any scan result
     token is stored).
   - **Column-level write restrictions beyond RLS's row granularity** (e.g. "the requester can
     only touch `status`, not `shift_id`") go in a `before update` trigger that raises
     `errcode = '42501'` on a disallowed change — see `app_hidden.enforce_shift_swap_update` or
     `app_hidden.enforce_task_update_scope` for the pattern.
   - **`FORCE ROW LEVEL SECURITY`**, always, on every new table — not just `ENABLE`. This is
     what stops the table owner (including a migration-running superuser-adjacent role) from
     silently bypassing RLS. Every existing migration does this; don't skip it.
3. **Write the pgTAP test file** at
   `supabase/tests/database/<name>_rls.test.sql`, matching the fixture shape every other test
   file uses: org_a (owner `...002`, admin `...003`), venue A1 (manager `...004`, staff
   `...005`, a second staff `...008` when you need two), org_b (owner `...006`) — reuse these
   exact UUIDs so a reader can cross-reference any test file instantly. Cover: insert
   authorization (positive + negative), cross-tenant isolation (org_b sees nothing), any
   column-level restriction, and any derived-column correctness. Remember the **Postgres RLS
   quirk** that bit several tests earlier in this rebuild: an `UPDATE`/`DELETE` whose `USING`
   clause matches zero rows is a **silent no-op**, not an exception — only `INSERT`'s
   `WITH CHECK` failure (or a privilege-level `REVOKE`) raises one. Use `lives_ok` +
   state-assertion for a USING-clause denial, `throws_ok` only when there's a real raised
   exception (an explicit trigger `raise exception`, a `REVOKE`d privilege, or a `CHECK`
   constraint).
4. **Verify locally before touching the live project**, every time, using this exact sequence
   (copy-paste, it's been run dozens of times this rebuild):
   ```bash
   sudo -u postgres psql -c "DROP DATABASE IF EXISTS vw_check;"
   sudo -u postgres psql -c "CREATE DATABASE vw_check;"
   cd <repo root>
   sudo -u postgres psql -d vw_check -v ON_ERROR_STOP=1 -f supabase/tests/ci_auth_stub.sql
   sudo -u postgres psql -d vw_check -v ON_ERROR_STOP=1 -f supabase/tests/ci_storage_stub.sql
   for migration in supabase/migrations/*.sql; do
     sudo -u postgres psql -d vw_check -v ON_ERROR_STOP=1 -f "$migration"
   done
   sudo -u postgres psql -d vw_check -v ON_ERROR_STOP=1 -f supabase/tests/ci_grants_stub.sql
   sudo -u postgres psql -d vw_check -c "CREATE EXTENSION IF NOT EXISTS pgtap;"
   sudo -u postgres pg_prove --dbname vw_check supabase/tests/database/*.test.sql
   ```
   If a new table needs a column-level grant restriction (see step 2), add the matching
   `revoke`/`grant` to `supabase/tests/ci_grants_stub.sql` too — its own header comment explains
   why the stub has to re-apply it *after* its blanket grant, which is the opposite order from
   what a real Supabase project does (and why `payroll_connections`' narrowing is duplicated
   there).
5. **Apply to the live project** via `mcp__Supabase__apply_migration` only after step 4 passes
   100%. Then re-run `mcp__Supabase__get_advisors` (both `security` and `performance`) and fix
   anything new it surfaces before moving on — this caught a real missing-`search_path` bug as
   recently as the `events` migration in this same rebuild.
6. **Write the Edge Function(s), if any are needed** (webhooks, anything requiring a secret the
   client must never see, anything needing the service role). Structure:
   `supabase/functions/<name>/index.ts`, reusing `supabase/functions/_shared/{cors,
   supabase-clients, crypto, stripe, google-auth}.ts` rather than duplicating logic. Deploy with
   `mcp__Supabase__deploy_edge_function`, `verify_jwt: true` unless the function is a public
   webhook authenticated by its own signature/secret instead (`verify_jwt: false` — see
   `stripe-webhook`, and any `{provider}-oauth` function's `/callback` route). For a genuinely
   new external integration, **test against the real API with curl before writing the Edge
   Function**, the way this rebuild tested Groq and Stripe's actual response shapes before
   coding against them — don't assume a request/response shape from memory.
7. **Build the Flutter feature**: `apps/mobile/lib/features/<name>/{domain,data,application,
   presentation}/`, following the exact layering every existing feature uses — a hand-written
   domain model (not `freezed`, see the note in `features/organizations/domain/organization.dart`
   for why, until `build_runner` is actually run), a repository interface + Supabase
   implementation (UI never touches `SupabaseClient` directly), Riverpod providers, a
   `ConsumerWidget`/`ConsumerStatefulWidget` screen that maps `PostgrestException.code` to a
   user-facing message (`42501` → permission message, etc. — every existing screen does this).
   Wire it into `apps/mobile/lib/app/router.dart` and, if it belongs there, into
   `features/dashboard/presentation/dashboard_screen.dart`'s stat tiles or "More" list. Write or
   update the feature's own `README.md` the way every other feature folder has one, including
   an honest "not implemented yet" / "not independently verified" section for anything left
   incomplete — this rebuild has been deliberately explicit about gaps rather than papering
   over them, and that discipline should continue.
8. **Commit with a real "why", not just "what"**, and push to the designated branch. Every
   commit message in this rebuild explains the design decision, not just the diff — look at any
   commit on this branch for the expected level of detail.
9. **Update `docs/migration/phase4-validation-report.md`**: move the module from the
   "unported" table in §3 to a new row in the "what has been built" tables, with the same
   honesty about what's verified vs. not that the rest of the report has.

---

## 2. Per-module porting plan

Scope below comes from an actual read of each module's controller/service and the Prisma
schema (not guessed) — see the companion scope notes if you need more detail than fits here.

### `staff-requests` — start here
Smallest, most self-contained, no external integration. `StaffRequest` (kind, status, links to
a shift and a reviewing profile) with a GET/POST/PATCH review workflow. Maps directly onto the
existing pattern: a `staff_requests` table, venue-scoped, RLS = member can create/view own,
manager can review (approve/deny via the same column-restricted-update trigger pattern as
`shift_swaps`). No Edge Function needed. Good first module to prove the loop still works before
tackling anything with external dependencies.

### `insights`
Also small: a single `GET /` returning the 3 most recent `CosmicInsight` rows, gated by an
active subscription (`subscription_is_entitled` — already exists, built in this rebuild for
Stripe). **Open question**: nothing in `modules/insights` populates `CosmicInsight` — some
external/background producer does, not found in this read. Before porting, find that producer
(grep the whole legacy repo, not just this module) or ask the product owner what's supposed to
generate these. If it turns out to be another Groq/LLM call, it can reuse `ai-assistant`'s
budget-reservation pattern directly.

### `time-clock`
Real complexity: **geofencing** (`common/geofence.ts` — read it fully before porting;
`assertWithinGeofence` rejects punches outside `venue.latitude/longitude/geofenceRadiusM` or
flagged as mock-GPS) and anti-replay detection on GPS fixes (flagged via
`locationAnomaly`, not hard-blocked). Needs `venues` to gain `latitude`/`longitude`/
`geofenceRadius_m` columns (a migration against the existing table, not a new one). The
clock-in/out/break endpoints become a `time_entries` table with RLS = self can
insert/view-own, manager can view venue's. The geofence math (haversine distance) belongs in a
`plpgsql` function or the Edge Function layer — it needs to run server-side either way since
it's an authorization-adjacent check, not just display logic, so put it in a Postgres function
alongside the insert trigger (parallel to how `enforce_shift_swap_update` keeps authorization
logic in the database, not just the client). The cron-driven late-clock-in alerting
(`ClockAlertDeliveryService`) depends on the `notifications` port below — sequence `time-clock`
before `notifications` for the table, but the alerting half waits on it.

### `documents`
Prisma model `VenueDocument`. Needs Supabase Storage (a new private bucket, policies following
the exact pattern in `supabase/migrations/20261002040000_storage_buckets.sql`). **Decision
needed before porting**: the legacy code streams every upload to a live ClamAV daemon over raw
TCP and rejects infected files before accepting them (`document-malware-scanner.service.ts`).
There is no equivalent running in this environment. Options: (a) stand up a ClamAV instance
reachable from an Edge Function (e.g. a small Cloud Run service, ironically keeping one sliver
of non-Supabase infra alive deliberately), (b) use a hosted malware-scanning API, (c) defer
scanning and flag this gap explicitly in the feature's README the way other gaps have been
flagged this rebuild — but do not silently drop it without saying so, since it's a real
security control in the legacy system.

### `media-cleanup`
Not a client-facing module — an internal deletion-queue worker (`ObjectDeletionJob`). Its
replacement is a Postgres table + either a `pg_cron`-scheduled SQL function or a
self-retriggering Edge Function (the handoff's own migration-plan doc flags exactly this
pattern at line 127 for long-running batch work that doesn't fit an Edge Function's execution
limit). **Preserve the safety regex** that refuses to delete any storage key not matching the
server-generated `^(chat|documents)/<venueId>/<32-hex>$` shape — that's a deliberate defense
against a future bug queuing a client-controlled key for deletion, worth keeping verbatim in
spirit even though the storage backend changes from raw S3 keys to Supabase Storage object
paths. Build this alongside whichever of `chat`/`documents` ships first, since both depend on
it for cleanup.

### `guests` and `reservations`
Port together — `reservations` cross-reads `Guest`, and both share the identical
**webhook-with-replay-protection** pattern: a per-venue secret (`leadsWebhookSecret` /
`ReservationConnection.webhookSecret`) checked via a header, plus `x-webhook-id`/
`x-webhook-timestamp` replay protection. This is architecturally identical to `stripe-webhook`'s
signature verification and `payroll_connections`' encrypted-secret-at-rest pattern — reuse both:
hash the webhook secret at rest the way `payroll_connections` encrypts OAuth tokens (a
`webhook_secret_hash` column, column-grant-restricted from `authenticated`), and structure the
replay check as a small `webhook_replay_log` table (venue_id, webhook_id, received_at) with a
short retention window, checked before processing. **Open question**: `ReservationConnection`/
`ReservationSyncEvent` suggest a sync relationship with an external reservation platform whose
identity wasn't determined in this read — find out which provider(s) before designing the sync
side; the inbound webhook ingestion side is well-understood regardless. The Stripe deposit flow
in `reservations` (and the one in `crm`'s BEO flow, see below) should reuse this rebuild's
existing Stripe Edge Function patterns (`_shared/stripe.ts`), not reimplement raw Stripe API
calls the way the legacy `crm.controller.ts` does inline.

### `floor`
Concurrency-sensitive: table merge/split/assignment uses serializable-isolation transactions
and explicit locking in the legacy code (`withSerializableRetry`, `lockFloorTables`). Postgres
RLS doesn't change transaction isolation — this still needs `SET TRANSACTION ISOLATION LEVEL
SERIALIZABLE` (or advisory locks, like `notifications`' push-token registration already does in
the legacy code — a real precedent worth copying) inside whichever function performs a merge/
split, with retry-on-serialization-failure logic client-side or in an Edge Function wrapping
the operation. Depends on `reservations`/`guests` existing first (floor assignment references
reservations and waitlist entries).

### `chat`
REST/poll-based, not real-time (confirmed no websocket in the legacy code) — this simplifies
things: it's a normal RLS-gated table set (`conversations`, `messages`, `conversation_reads`)
plus Storage-backed images reusing the `media-cleanup` queue. The legacy `@Public()` image-fetch
route authenticated via a short-lived HMAC token in the URL (not a session) — replicate with a
signed Supabase Storage URL (`createSignedUrl`) instead of hand-rolled HMAC, since Supabase
Storage already provides this primitive natively; don't reimplement token signing that the
platform gives you for free.

### `crm`
The largest module (leads/BEOs/contracts/forecast/email templates) and the one most likely to
warrant a scope conversation with the product owner before porting — confirm it's actually in
active use before investing in it, given its size relative to everything else in this list. If
greenlit, it's a straightforward (if large) set of venue-scoped tables following the exact
established pattern; the BEO deposit flow should go through this rebuild's Stripe Edge
Functions, not a new raw integration. The "contract e-signature" is just a text-field capture
of a typed name/date in the legacy system, not a real e-signature integration — confirm that's
still acceptable before porting as-is.

### `pos`
Ingest-only by design (the legacy code explicitly does not call vendor APIs — confirmed via
`pos-provider-capabilities.ts`'s own documentation). This is actually the simplest of the
larger modules to port: webhook ingestion with per-connection secrets (same pattern as
`guests`/`reservations` above) and idempotent upserts keyed on natural external IDs
(`(venue_id, provider, external_check_id)`), which Postgres `ON CONFLICT` handles directly — no
new idempotency mechanism needed beyond a unique constraint.

### `notifications`
Needs a product decision, not just a porting decision: the legacy implementation calls Expo's
push service directly, which only works for an Expo-managed app — the new app is a native
Flutter build, so Expo push tokens don't apply. Replace with either direct FCM (Android) + APNs
(iOS) calls from an Edge Function, or a Flutter-side push plugin (`firebase_messaging`) feeding
tokens into a `push_tokens` table for the server to target. Preserve the advisory-lock-on-
registration pattern (`pg_advisory_xact_lock` keyed on venue+token) — it's a genuinely good
concurrency-safety idea worth keeping regardless of which push backend is chosen.

### `observability`
Trivial — 49 lines, already Sentry, already env-gated and PII-scrubbing. The Flutter app
already has its own Sentry setup (`apps/mobile/lib/core/errors/error_reporter.dart`) with the
same scrubbing philosophy; port this module's equivalent scrubbing (strip media-access tokens
from URLs) into any new Edge Function that embeds a token in a URL the way `chat`'s image routes
used to. Not worth its own migration or schema — just a shared Edge Function logging helper if
one doesn't already exist by the time this is reached.

---

## 3. Suggested order

1. `staff-requests` — proves the loop, no dependencies, no open questions.
2. `insights` — small, but resolve its open question (who populates `CosmicInsight`) first.
3. `time-clock` — geofencing is intricate; do it early while focus is fresh, independent of
   everything else in this list except the `notifications` alerting half.
4. `media-cleanup` — needed by both `chat` and `documents`; build once, use twice.
5. `documents` — resolve the ClamAV decision before starting.
6. `guests` + `reservations` — together, per the shared webhook pattern; resolve the
   reservation-platform-identity open question first.
7. `floor` — depends on `reservations`/`guests`.
8. `pos` — independent of everything above, can be done any time; genuinely the easiest of the
   remaining "real" integrations.
9. `chat` — depends on `media-cleanup`.
10. `notifications` — resolve the push-backend decision first; `time-clock`'s alerting half
    completes once this lands.
11. `crm` — largest; confirm it's in scope before starting.
12. `observability` — do opportunistically alongside whichever module needs it first; doesn't
    need its own dedicated pass.

## 4. Open questions to resolve with the product owner before (not during) porting

- **ClamAV replacement for `documents`** — host something, use a hosted API, or explicitly drop
  the control (see §2).
- **`CosmicInsight` producer** — what actually generates these rows today, and should the new
  architecture replace it with a Groq-backed Edge Function (natural fit, given `ai-assistant`
  already exists) or something else.
- **Reservation platform identity** — what `ReservationConnection` actually syncs with, if
  anything beyond inbound webhook ingestion is needed.
- **Push notification backend** — FCM/APNs direct vs. a Flutter plugin, for `notifications`.
- **`crm` scope confirmation** — is it still a live, used feature worth the size of the port.

## 5. What NOT to change

Do not touch the legacy NestJS/Prisma/Cloud Run stack itself while porting — it remains
production and serves real traffic for every module not yet ported, per
`docs/migration/phase4-validation-report.md`. Don't delete, disable, or route around any
legacy endpoint until its Supabase/Flutter replacement is built, tested (pgTAP green, advisors
clean), and deployed — the same bar every module in Phases 1–3 was held to.

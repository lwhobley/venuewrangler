# Repository error audit — 2026-10-14

Baseline: `main`, `9faff8ed53f4813a43b8b9e98ea6f0b38c291d3e`.

The original audit was read-only. Subsequent remediation is documented in `remediation-2026-10-14.md`; the findings below describe the audit baseline, not the updated working tree. Existing unrelated untracked files were excluded. No deployment, payment, live database query, production migration, or device installation was performed.

## Result

**10 findings: 3 High, 7 Medium.** No Critical issue was confirmed in the reviewed paths. This is a broad source and automated-check audit, not a guarantee that every repository path is defect-free. Security review concentrated on server authorization, shared-device state, payment processing, and data integrity. The active product is Flutter in `apps/mobile`; root JavaScript tooling serves the public site and deployment.

## Findings, ordered by priority

### AUD-01 — High: Expired-checkout retries can create multiple payment sessions

Locations: `supabase/functions/stripe-create-checkout/index.ts:160`; latest baseline definition in `supabase/migrations/20261013100000_review_fixes_db_part1.sql:319`.

Two requests can both claim the same stored attempt and retrieve the same expired Stripe session. Each then calls `claimAttempt(true)`. The latest baseline migration has a ten-second guard after a session is recorded; the original audit initially overlooked this later redefinition. It does not protect a replacement still being created, or a stale request delayed beyond that window. The database lock serializes calls, but does not compare against the expired key each caller observed. Callers can therefore create separate Checkout Sessions. If the first request records its session and a stale caller resumes after the ten-second window, both can return separate payment URLs.

Evidence correction: the original `output/audit/checkout-race.cjs` mock modeled the earlier SQL definition, so its short-delay `[200, 200]` result must not be presented as a faithful reproduction of the latest migration. The residual stale-request condition is addressed with a key comparison, covered by the new database regression and local SQL assertions. No live Stripe integration was exercised.

Recommendation: replace unconditional force-new with a comparison against the attempt/session that was observed expired. Under the lock, reuse a replacement another request already created. Test the expired-session retry race, not only ordinary simultaneous first checkout.

### AUD-02 — High: Offline sign-out can leave the previous user's notifications on a shared device

Locations: `apps/mobile/lib/core/auth/sign_out_service.dart:25`; `apps/mobile/lib/features/notifications/application/push_registration_service.dart:91`; `supabase/migrations/20261012100000_review_fixes_tenant_integrity.sql:256`; `supabase/migrations/20261013100200_review_fixes_db_part3.sql:101`.

When token revocation fails during sign-out, the app preserves a pending-revocation marker and still signs out. The next account attempts revocation through its own session, but the RPC can only disable registrations owned by `auth.uid()`. That call cannot revoke the earlier account's row. It returns without disabling that row, after which the client deletes its pending marker. Registration for the new account is also rejected when the previous owner remains an active member. The enabled token still belongs to the previous person, and push delivery revalidates that person's membership rather than the device's current session. The device can continue receiving their notification contents.

Evidence: source trace across sign-out, pending revocation, the latest registration/revocation SQL, and `supabase/functions/_shared/push-delivery.ts:29`. The registration migration explicitly documents the offline shared-device tradeoff. No actual notification leak was exercised.

Recommendation: design revocation around proof of possession of the installation, or invalidate/rotate the transport token at account change and make server registrations session/installation aware. Do not weaken the existing ownership check to allow arbitrary token takeover. Preserve retry state until revocation is actually verified.

### AUD-03 — High: Concurrent POS webhooks can reopen a closed check and roll back its revenue

Locations: `supabase/functions/toast-pos/index.ts:135`, `:147`, `:159`; `supabase/migrations/20261003000000_pos_schema.sql:99`.

The handler reads the old check status, decides whether the incoming event is allowed, and performs an unconditional upsert in a separate request. A close event and an older open event can both read the same open row. If the open upsert finishes last, it restores `status = open`, clears `closed_at`, and writes its earlier totals. The database trigger derives ownership and timestamps but does not enforce final-state transitions. The handler's claim that a closed check cannot be rewritten is therefore only true for sequential deliveries.

Evidence: `output/audit/pos-race.cjs` executes the real handler with an interleaved mocked database. Both requests return 200; final state is open, close time null, total 1000 cents instead of the close event's 5000 cents. No provider traffic or live database writes occurred.

Recommendation: perform ingestion through one database transaction/RPC with a row lock or conditional upsert, preserving permitted close-to-void behavior and rejecting stale reopen updates atomically.

### AUD-04 — Medium: Deployed site headers block the web 3D preview's iframe

Locations: `site/_headers:13`, `:16`; `site/_worker.js:13`; `apps/mobile/lib/features/floor_studio/presentation/floor_studio_3d_view_web.dart:36`.

The preview embeds the same-origin scene HTML in an iframe. The static catch-all rule sends `frame-ancestors 'none'` and `X-Frame-Options: DENY` on that asset. The Worker's asset branch preserves those headers. Browsers reject embedding before the scene can run, regardless of the working iframe handshake.

Evidence: `output/audit/site-headers.cjs` serves the actual Worker with an asset mock applying the checked-in static headers. A real browser rejected the iframe with: `Framing ... violates ... frame-ancestors 'none'`. This verifies repository configuration, not current production headers.

Recommendation: give the scene HTML a narrowly scoped same-origin framing policy and matching frame-options handling. Preserve anti-framing protection for the main app and marketing pages. Add a deployed-header integration check for the iframe asset.

### AUD-05 — Medium: Reservation form shows a different time from the one it saves

Location: `apps/mobile/lib/features/guests_reservations/presentation/reservations_screen.dart:366`, `:407`, `:410`, `:465`.

The form keeps `reservationTime` as venue wall-clock fields encoded in a UTC DateTime, initially from `VenueTimezone.venueNow`. Its display passes that value into `formatTime` and `formatShortDate`, which expect an actual instant and apply the venue offset again. Saving uses `toUtc` correctly for a wall-clock value. The time shown and the time saved can therefore differ by the venue offset, and the displayed date can shift across midnight.

Evidence: isolated Flutter reproduction in `output/audit/source-repros_test.dart`: Chicago wall-clock 15:00 displays as 10:00 AM, but saves as the instant corresponding to 15:00 Chicago.

Recommendation: keep actual instants throughout the form, or format its wall-clock values directly; apply the conversion exactly once at the boundary. Cover the form display and saved value together.

### AUD-06 — Medium: Events use the device's timezone instead of the selected venue's timezone

Location: `apps/mobile/lib/features/events/presentation/event_list_screen.dart:82`, `:190`, `:203`.

New event times are initialized using device-local `DateTime.now`, selected using device-local `DateTime(...)`, and displayed with `toLocal`. The repository converts that device-local value to UTC. A manager operating remotely creates an event in their current device timezone even when the selected venue is elsewhere. Other venue workflows already use the venue timezone, so the app is inconsistent.

Evidence: source trace of event creation, display, and `events_repository.dart:59`. Example: selecting 18:00 on a New York device for a Chicago venue saves an instant that occurs at 17:00 Chicago during the same daylight-saving period. No live event was created.

Recommendation: use the selected venue's timezone for event entry, display, and UTC conversion, with a test where device and venue zones differ.

### AUD-07 — Medium: A saved-layout query failure is treated as an empty room and can erase saved objects

Location: `apps/mobile/lib/features/floor_studio/presentation/floor_studio_screen.dart:332`, `:60`, `:203`.

The studio calls `_loadFromSaved` when `layouts.hasError`, even when no saved value exists. Passing null clears the editor and objects and sets `_loadedFor` to the plan ID. If layouts later load successfully, that latch prevents their measurements and objects from populating the editor. The screen exposes no layout-load error or retry state. The manager can enter measurements and save, overwriting a real saved layout with an apparently new, object-free layout.

Evidence: source control flow; not separately exercised in a widget test during this audit. Initial-load ordering was previously addressed, but the error branch still marks the plan loaded.

Recommendation: distinguish successful empty results from failed reads, populate/latch only on success, and prevent saving over an unknown saved state until loading succeeds.

### AUD-08 — Medium: Custom room objects can overlap tables or extend beyond the walls without a validation warning

Locations: `apps/mobile/lib/features/floor_studio/presentation/floor_studio_screen.dart:175`; `apps/mobile/lib/features/floor_studio/domain/floor_studio.dart:213`, `:330`.

Save and the validity message validate only tables. Objects are not inputs to clearance checks. A stage placed over a dining table still allows the screen to report no boundary/clearance conflicts and save. Additionally, `clampStudioObject` only centers objects larger than the room rather than rejecting or resizing them; part of the object remains beyond the walls, with no save validation catching it.

Evidence: isolated Flutter reproductions confirm a table and stage occupying the same center pass table validity, and a 20-foot-wide stage in a 10-foot room still extends outside after clamping.

Recommendation: validate object footprints against room boundaries, tables, and applicable object collisions. Reject oversized placements explicitly. Include those checks in save and the displayed feasibility message; do not represent table-only validity as validity of the whole plan.

### AUD-09 — Medium: One malformed saved table element prevents all room layouts for a venue from loading

Locations: `supabase/migrations/20261013110000_floor_plan_studio.sql:15`; `apps/mobile/lib/features/floor_studio/domain/floor_studio.dart:296`; `apps/mobile/lib/features/floor_studio/data/floor_studio_repository.dart:26`.

The database's `layout` column is unrestricted JSONB. A manager API write or future faulty client can persist `[{}]`, a scalar, or nonnumeric coordinates. Table deserialization assumes every element and coordinate is valid, and `getLayouts` maps every row without isolating a malformed row. One broken plan therefore fails the provider for every plan in that venue, including the BEO preview. Custom objects have defensive parsing; tables do not.

Evidence: isolated Flutter reproduction confirms `layout: [{}]` throws a TypeError. The migration has no table-layout shape constraint; live schema was not inspected. This is a robustness/data-integrity gap, not an authorization bypass.

Recommendation: enforce layout shape and finite coordinates server-side, preflight existing data, and parse saved layouts defensively with a visible per-plan error and repair path.

### AUD-10 — Medium: BEO “Edit in studio” does not open the room being previewed

Locations: `apps/mobile/lib/features/floor_studio/presentation/beo_room_preview_card.dart:81`; `apps/mobile/lib/features/floor_studio/presentation/floor_studio_screen.dart:295`, `:321`.

The BEO can preview any saved plan for its own venue, but its edit button pushes only `/floor/studio`. No selected plan or BEO venue is passed. A new studio screen selects the first plan for the active venue. With Ballroom and Terrace plans, editing a Terrace preview can open Ballroom; when the active venue differs, it opens another venue entirely. Managers can consequently modify the wrong room under an action labeled as editing the current preview.

Evidence: source trace of navigation and studio initialization. No cross-tenant write bypass is implied; RLS still governs the chosen venue.

Recommendation: pass the selected plan and venue as explicit route inputs, verify access, and initialize the editor to that exact room. If switching venues is required, make the target explicit before editing.

## Validation evidence and limits

- Full Flutter analyzer: **passed**, no issues (`flutter analyze --no-pub --fatal-infos`).
- Existing Flutter tests: **312 passed** using `--no-test-assets` to avoid the known locked `build/unit_test_assets` folder. This does not verify fresh asset packaging or native release builds.
- Root Vitest: **12 passed** in two files.
- Root TypeScript check: **passed**.
- Existing Edge Function helper tests: **6 passed** with Deno `--no-check`; not a complete Edge Function type check or endpoint integration suite.
- npm audit: **0 known vulnerabilities reported** for the JavaScript lockfile at audit time. This does not cover Flutter packages, native SDKs, or manually vendored three.js.
- Isolated audit checks: checkout race, POS race, browser framing rejection, and four Flutter behavioral reproductions confirmed the conditions described above. Reproduction tests assert the observed defects; they are evidence, not regression gates claiming those defects are fixed.
- No live Supabase migration replay/RLS suite, live provider integration, iOS/Android release build, or real-device audit was performed. Existing device observations in the chat were not reused as current proof.

Automated validation score: **4/4 existing test/check groups passed** (Flutter analysis/tests, JavaScript tests/typecheck, Edge helper tests, npm dependency scan), subject to the limits above. Passing checks do not clear the ten findings.

First priorities: **AUD-01 checkout concurrency**, **AUD-02 shared-device push privacy**, and **AUD-03 atomic POS ingestion**. Then address the web iframe and reservation-time display before the next release.

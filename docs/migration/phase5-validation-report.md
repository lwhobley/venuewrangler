# Phase 5 — Validation Report (Flutter + Supabase rebuild)

**Status: validation only. No cutover action has been taken. The legacy Expo/NestJS/Prisma/
Cloud Run stack is untouched and remains the production system.**

This picks up from `docs/migration/phase4-validation-report.md`, which closed out feature
parity (every legacy module has a ported Flutter/Supabase equivalent) but listed a specific set
of gaps blocking cutover. This report covers what closed those gaps, what a full repo-wide
review found and fixed, and what still has to happen before the Expo app and the Cloud
Run/NestJS/Prisma API can actually be turned off.

---

## 1. What this phase built

### iOS App Attest — client now exists (Phase 4 gap: closed)

Phase 4 shipped real server-side cryptographic verification but no Flutter client to produce an
attestation. This phase added one:

- `ios/Runner/AppAttestPlugin.swift` — a small, hand-rolled MethodChannel bridge over Apple's
  `DeviceCheck.DCAppAttestService` (not a third-party plugin, for the same reason the server-side
  verification was hand-rolled: this is security-critical code not worth trusting to an
  unaudited dependency).
- `apps/mobile/lib/core/security/app_attest_service.dart` — orchestrates the two-step flow:
  fetch a server challenge, generate/cache a DeviceCheck key, attest it, send the result back for
  verification. Recovers from a failed `attestKey` call by dropping the cached key id, matching
  Apple's own guidance. Never throws — failures are swallowed, matching the server's `observe`
  mode posture (this never blocks anything).
- `apps/mobile/lib/core/security/app_attest_providers.dart` — fires one attestation attempt per
  sign-in, wired into `app/app.dart`.
- Server side: `attestation_challenges` table (new migration) makes challenges single-use,
  closing the replay-window gap the signed-token-only design had in Phase 4.
- **Test coverage**: `test/core/security/app_attest_service_test.dart` drives the real
  challenge → attestKey → verify round trip against a mocked HTTP layer and a mocked platform
  channel — not just a trivial supported-check stub.

**Still unverified**: no physical iOS device has ever exercised this. The simulator doesn't
support App Attest, so the native Swift side has never run against real Secure Enclave hardware.

### Push notifications — client registration now exists (Phase 4 gap: closed)

Phase 4 built the entire server-side dispatch path (FCM, then native APNs) but the Flutter app
never requested permission, fetched a token, or called `register_push_token`. This phase closed
that:

- **iOS**: `ios/Runner/PushNotificationsPlugin.swift` requests notification permission and
  returns a raw APNs device token. Native APNs end to end, matching the `APNS_KEY`/`APNS_KEY_ID`/
  `APNS_TEAM_ID`/`APNS_BUNDLE_ID` secrets — not bridged through Firebase.
- **Android**: `firebase_messaging` requests permission and fetches an FCM token, pointed at the
  correct Firebase project (`venuewrangler-ed056`) via a real `google-services.json`.
- `apps/mobile/lib/features/notifications/application/push_registration_service.dart` picks the
  right path per platform; `pushRegistrationTriggerProvider` fires it whenever the active venue
  changes, wired into `app/app.dart`.
- Server side (`notifications-send`): added a sandbox/production APNs retry so dev-build tokens
  don't get disabled on their first push; fixed dead-token disabling, which called an RPC in a
  schema PostgREST doesn't expose and never checked the error — it silently did nothing before.

**Still unverified**: no physical device has received a push. No in-app deep-link routing exists
yet — a universal link reopens the app, but doesn't navigate anywhere specific inside it.

### CRM deposit checkout — built, then removed again in the same phase

Phase 4 flagged CRM's Stripe deposit checkout as unbuilt. This phase first built it
(`crm-create-deposit-checkout`, a BEO-deposit-paid path in `stripe-webhook`, a "Collect" button
in Flutter), via Stripe Connect connected accounts — then removed all of it in a later commit
the same phase (`20261004010000_remove_beo_deposit_and_stripe_connect.sql` and its
accompanying Flutter/Edge Function changes): Stripe is subscription billing only now, with no
connected-account/Connect usage anywhere. There is no other mechanism to ever mark a BEO
deposit "paid", so the half-built feature was removed rather than left dangling. CRM BEOs no
longer have any deposit concept at all.

- `crm-send-email` Edge Function — actually sends `render_email_template`'s output via Resend
  (the RPC itself only ever did `{{var}}` substitution; nothing sent anything before this). This
  part survived the deposit-checkout removal and is still live.
- **Test coverage**: `test/features/crm/crm_screen_test.dart` — the CRM feature had zero tests
  before this session; now covers the empty state and basic BEO list rendering (the
  deposit/Collect/Waive assertions this doc previously described no longer apply, since that
  UI was removed along with the feature).

### ClamAV removal reverted — restored to fail-closed

A prior commit in this phase removed the malware-scanning step from `documents-upload`
entirely, with a comment claiming the user had explicitly accepted that risk. That
confirmation could not be verified — the user said it was not their call — so the scan has
been restored: `_shared/clamav.ts` is back, and `documents-upload` once again calls
`assertDocumentClean` before accepting an upload, failing closed (503) if `CLAMAV_HOST` isn't
configured, exactly as originally designed. No reachable `clamd` instance exists in any
environment this work has touched, so uploads will 503 until one is configured — that is the
correct behavior, not a bug.

### Repo-wide review: real bugs found and fixed

A full automated + manual review (type-checking every Edge Function, the Expo app, the NestJS
API, the Flutter app; running every test suite; checking live database advisors) found and fixed,
in already-deployed functions:

- **Security**: `notifications-send` let any venue member (not just managers) push a
  notification to every device at the venue by omitting `target_user_ids`. Fixed.
- `notifications-send`: organization owners/admins could never send or receive notifications —
  the code only checked venue-scoped memberships, never org-scoped ones. Fixed.
- `stripe-webhook`: a paid deposit could be silently dropped if `deposit_status` was blank, or
  marked paid before a delayed payment method actually cleared. Fixed.

Plus smaller fixes: a case-sensitive Sentry header scrubber, 26 Deno type errors across the
shared Edge Function helpers (a stricter `Uint8Array`/`BufferSource` relationship in the current
TypeScript), the Expo app's `tsc` config picking up Deno-only code, two Flutter analyzer
warnings, and one genuine pre-existing compile error in `documents_repository.dart` (two classes
illegally extended the sealed `AppError` type from outside its library — the documents feature
could not compile at all until this was fixed).

Everything above has been verified against the actual tooling, not asserted: `deno check` on
all 14 functions (0 errors, was 26), Flutter analyzer + 68 tests (0 errors, 0 warnings, all
passing), the Expo app's `tsc` (0 errors, was 148) + 1448 vitest tests passing, the NestJS API's
`tsc` + 1288 vitest tests passing. The three redeployed functions were smoke-tested live after
deployment to confirm they boot without crashing.

### Stripe configuration — was silently broken, now fixed

Billing was returning `billing_not_configured` for every checkout attempt: `.env.example`
documented the required redirect-URL secrets, but they had never actually been set.
`STRIPE_CHECKOUT_SUCCESS_URL`/`CANCEL_URL`/`STRIPE_PORTAL_RETURN_URL` are now live, pointed at
`https://venuewrangler.com/billing?status=...` (matching the legacy API's own redirect pattern
exactly, verified against `packages/api/src/modules/app/app-billing.controller.ts`), per
Stripe's documented mobile pattern (an https universal link, not a raw custom-scheme link). The
live Stripe webhook endpoint was also missing the `checkout.session.async_payment_succeeded`
event entirely — added directly in the Stripe dashboard.

Supporting infra: `site/.well-known/apple-app-site-association` now claims `/billing*`
(reusing the legacy `/billing` landing page as the universal-link fallback); the
`venuewrangler://` custom scheme was registered on both platforms as the fallback-of-the-
fallback (it was never registered for the new Flutter app — only the old Expo app had it).
Android App Links are scaffolded but **not yet verifiable**: `assetlinks.json` has a placeholder
fingerprint, since no Android release signing key exists anywhere in this project yet (see
`site/.well-known/assetlinks.json.NEEDS_REAL_FINGERPRINT.md`).

### iOS/Android platform scaffolding — now exists

`apps/mobile` had no native platform directories at all before this phase — pure Dart source,
with no Xcode project and no Android Gradle project to build from. Both now exist:
bundle id `com.venuewrangler.app`, Apple Developer Team `8MTB6AL22R`, matching the legacy app's
exact identity so this replaces it in App Store Connect rather than becoming a new listing. New
app icon (provided this session) wired into both platforms' icon sets and the legacy Expo app's
icon assets, for consistency.

---

## 2. What's still open before cutover can be responsibly considered

This list is additive to Phase 4's own remaining gaps (§2 of that report), most of which are
still open:

| Area | Status |
|---|---|
| **ClamAV** | Fail-closed scan restored (`_shared/clamav.ts`, wired into `documents-upload`). Not configured in any environment this work has touched, so every upload 503s until a real, network-reachable `clamd` instance is connected — can't be a local container, since Edge Functions run in Supabase's cloud. |
| **App Attest** | Client exists, server verification is real, but **never tested against a physical device**. No in-app gating exists yet (still `observe` mode everywhere, as designed). |
| **APNs push** | Fully configured server + client, but **no physical device has received a push**. |
| **Android FCM push** | Client wired to the correct Firebase project, but likewise **unverified on a real device**. |
| **Android App Links** | Scaffolded, not functional — needs a real release signing certificate (none exists) before `assetlinks.json` can have a real fingerprint. |
| **Stripe** | Checkout/webhook config is now believed correct, but **no live transaction has been completed end to end** on this account (it's livemode-only, shared with other unrelated projects — see `apps/mobile/lib/features/billing/README.md`). |
| **Payroll (Square/QuickBooks/Gusto)** | No real OAuth app credentials anywhere; zero live round-trips ever completed. |
| **Sentry** | Wired into all 10 functions, but `SENTRY_DSN`'s actual event-delivery path is unverified — only the disabled/no-op code path has run. |
| **A Mac** | Nothing in this environment can build, sign, or upload an iOS binary. The scaffolding is ready; the actual build step cannot happen here. |
| **A build pipeline for Android** | No CI/local verification that `apps/mobile/android` actually assembles a release APK/AAB — only `flutter analyze`/`flutter test` have run (Dart-level, not a native Gradle build). |
| **In-app push deep-link routing** | A push/universal-link reopens the app but doesn't navigate anywhere specific inside it yet. |
| **Something else may also be deploying these functions** | Function version numbers jumped unexpectedly between deploys during this session's review (4 → 11 on `notifications-send`). If CI auto-deploys from `main`, merging this branch is what actually makes these fixes durable — until then, something else may be overwriting them. |

## 3. On removing Cloud Run / the Expo app / Prisma / the NestJS API

**Not ready. Nothing in this engagement has changed that recommendation.** The gaps above are
exactly the kind of thing that look fine in code review and fail silently in production — document
uploads that will 503 until a real malware scanner is connected, a payment flow that's never
actually taken a real payment, push notifications that have never reached a real phone.
Decommissioning the legacy stack is irreversible in
practice (user data, API consumers, app binaries already in users' hands) in a way that leaving
it running for a few more weeks is not.

**Recommended order of operations, once you're ready to move toward cutover:**

1. Close the physical-verification gaps above (a real iOS device for App Attest/APNs, a real
   Android device for FCM/App Links, a real `clamd`, a real Stripe test transaction, a real
   Android signing key) — these are the things that can't be verified from this environment at
   all, so they're the highest-value next steps regardless of what else happens.
2. Get a macOS build actually producing a signed `.ipa` and uploading to TestFlight. Put real
   people on it before anyone sees a production release.
3. Run both stacks in parallel for a period — the legacy Expo/Cloud Run stack serving
   production traffic, the Flutter/Supabase stack live-tested by an internal group — before
   considering a traffic cutover.
4. Only after that: decommission Cloud Run, the NestJS API, Prisma, and the Expo app, in that
   order, each with a rollback plan until you're confident the replacement has been correct
   under real load for real users.

Every one of this report's "verified" claims was checked against actual tool output in this
session (test runs, type-checker output, live smoke tests) — not asserted from memory. The
"unverified" items above are unverified because nothing in this sandboxed environment can
verify them, not because verification was skipped.

# core/security

## iOS App Attest — implemented

`app_attest_service.dart` is the client side of iOS App Attest, talking to the
`device-attestation` Edge Function and its real cryptographic verification in
`supabase/functions/_shared/app-attest.ts`. Native bridge: `ios/Runner/AppAttestPlugin.swift`
(a small hand-rolled MethodChannel over `DeviceCheck.DCAppAttestService` — see that file's
header comment for why this isn't a third-party plugin). Wired in at `app/app.dart` via
`appAttestTriggerProvider` (`core/security/app_attest_providers.dart`), which fires one
attestation attempt per sign-in, fire-and-forget.

This runs in `observe` mode only, per `docs/migration/flutter-supabase-rebuild-plan.md` §3/§4/§5
— it records a verdict server-side and never blocks anything. Per the plan, `enforce` mode is
meant to start with payroll connection/export, role changes, billing changes, sensitive document
downloads, and account-security actions specifically — never added broadly — and that gating
logic does not exist yet anywhere in the app. Test coverage: `test/core/security/app_attest_service_test.dart`
(drives the real challenge → attestKey → verify round trip against a mocked HTTP layer and a
mocked platform channel, not just the trivial `isSupported` check).

**Known gaps, not yet closed:**
- No real device has ever exercised this end to end (needs a physical iOS device enrolled in
  the right Apple Developer team — the simulator does not support App Attest).
- `APP_ATTEST_TEAM_ID`/`APP_ATTEST_BUNDLE_ID`/`APP_ATTEST_CHALLENGE_SIGNING_KEY` are set as live
  Supabase secrets, but nothing has confirmed the full flow against the live Edge Function with
  a real attestation object yet.

## Android/Play Integrity — not implemented

Android has no prior implementation anywhere in this codebase to port; it is net-new work (see
Phase 0 finding, migration plan §5.2). The server-side verification already exists in
`device-attestation/index.ts` (Play Integrity path); there is no Flutter client for it yet.

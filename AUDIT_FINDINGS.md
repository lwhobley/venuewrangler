# Venue Wrangler — read-only audit findings

Audit date: 2026-10-10. Checkout: `main`, commit `6fb279d1c8fecb44d4795a885602a3bef81e4c88`. Root: `C:/Users/lwhob/OneDrive/Downloads/a0-project`.

The audit baseline was the source checkout at the commit above. After the user approved “fix all,” source changes and unapplied migrations were added; no database migration, live write query, build, deployment, dependency upgrade, commit, or push was performed. The Antigravity draft's credential values are not reproduced.

A concurrent Antigravity audit draft appeared during review. Its credential values were removed from this deliverable; a sanitized copy and a claim-by-claim disposition are preserved in Appendix D. Its findings and severity counts are superseded by the verified/requalified table below.

## 1. Summary

**47 findings: 0 Critical, 7 High, 32 Medium, 8 Low.** Counts include explicitly labelled **Needs verification** items; a source defect is distinguished from an unverified production outcome. No confirmed Critical incident was demonstrated. High means a credible, source-supported authorization/privacy or operational data-integrity defect; Medium means a material workflow/reliability gap or bounded risk; Low means maintenance, content or performance hygiene.

| Category | Findings |
|---|---:|
| Database/booking integrity | 9 |
| Correctness/workflow | 8 |
| Privacy/data handling | 7 |
| Security/authorization | 4 |
| Platform/build | 3 |
| Documentation/product | 3 |
| Maintainability/dependencies | 3 |
| Lifecycle/navigation | 2 |
| Performance | 2 |
| UI/accessibility | 2 |
| Offline/recovery | 1 |
| AI/accounting | 1 |
| Billing/accounting | 1 |
| Environment isolation | 1 |

The most consequential findings are missing table-overlap enforcement (VW-003), loss of persisted offline conflicts (VW-004), Storage metadata deletion without object-byte deletion (VW-005), push recipients remaining eligible after membership revocation (VW-006), OAuth callbacks completing after manager authority is revoked (VW-007), and stale floor drafts removing newly added tables (VW-002). Device-local rather than venue-local booking/schedule times are a separate cross-cutting risk (VW-001).

This is a broad source audit and automated-check snapshot, not a guarantee of every possible bug or proof of deployed-production behavior.

### Remediation status

The following findings now have source changes: **VW-002 through VW-017 except VW-018, VW-019 through VW-025, and VW-031 through VW-047.** VW-026 is only partially addressed: router disposal is registered, but role/venue changes still recreate the router and can reset navigation. These changes have not yet been validated by a Flutter analyzer/test run or deployed. The floor, AI accounting, checkout, deletion-worker, notification-token and relationship/conversion changes require the new SQL migrations to be reviewed and applied separately; production data preflight is still required for constraints.

Still open in source or dependent on external evidence/product decisions: **VW-001, VW-018, VW-024, VW-027, VW-028, VW-029, VW-030 and VW-045**, plus the remaining VW-026 router-stability work and VW-005 deployment validation. Live DB state, an isolated non-production Supabase project, Play app-signing fingerprint, browser photo-evidence requirement and dependency replacement compatibility cannot be established from this checkout. Do not mark these complete from static source alone.

### 1.1 Architecture and package map

| Component | Entry point / configuration | Relationship |
|---|---|---|
| One Flutter app: `apps/mobile`, package `venuewrangler_mobile`, version `1.11.0+1` | `lib/main_development.dart`, `main_staging.dart`, `main_production.dart` call shared `app/bootstrap.dart` | One codebase with manager and employee compositions; these flavors are not separate Dart packages. No `lib/main.dart` is required when CI/run commands select an entrypoint. |
| Flutter application infrastructure | `app/app.dart`, `app/router.dart`, `core/config/env_config.dart` | Riverpod 2 providers are the composition root; repositories provide Supabase-backed implementations. GoRouter handles auth, password recovery, venue selection, role routing and notification taps. Most features use domain/data/application/presentation folders. |
| Supabase backend | `supabase/config.toml`, 65 ordered SQL migrations at the audit baseline plus 8 remediation migrations added in this pass, 15 Edge Function entrypoints after adding the Storage worker | Auth, Postgres/RLS, private Storage and Realtime. `app_hidden` helpers/triggers and authorized security-definer RPCs enforce tenancy and operational invariants; service-role functions must enforce authorization explicitly. Local config specifies PostgreSQL 15; the live engine/catalog was not inspected. |
| Push / device services | Android Firebase messaging; iOS Swift APNs and App Attest bridges | Firebase is used only for Android push. iOS uses raw APNs tokens and native channels. Android Play Integrity verifier exists server-side; client flow is absent. App Attest is currently advisory/observe by design. |
| Offline / local state | `core/offline`, `core/storage` | Tasks, checklist completions, incident drafts and media retries share a persisted FIFO queue. Native queue uses JSON files/backups; browser queue uses Flutter secure-storage localStorage support. Auth/session-sensitive state uses secure storage. |
| Root npm tooling | `package.json`, `vitest.config.mts`, `tests/` | Private root workspace with one package, `packages/marketing`; TypeScript/Vitest and site-build helpers. No active Expo app or NestJS/Prisma API package exists in this checkout. Historical references to them are not evidence of an active server. |
| Marketing and public web | `packages/marketing/src/main.tsx` → `App.tsx`, Vite; `site/_worker.js` | React 19/Vite marketing package plus static join/billing/legal/support pages. The Worker routes Flutter web under `/app/`; the build helper selects Flutter's production entrypoint with `--base-href=/app/` and `--no-web-resources-cdn`. |

Only one `pubspec.yaml` exists. Its declared Dart SDK range is `>=3.5.0 <4.0.0`; the resolved lockfile needs **Dart >=3.12.0 and Flutter >=3.44.0**. Installed Flutter **3.47.5 stable**, Dart **3.13.4**, and the pinned `flutter-version.txt` satisfy that graph. There are no separate Flutter package constraints to reconcile. Declared/resolved direct dependencies are listed in Appendix B. Resolving successfully does not prove native release compatibility.

Android uses AGP 9.1.0, Kotlin 2.4.0, Gradle 9.3.1 and Java/JVM 17. minSdk/targetSdk/compileSdk are delegated to the pinned Flutter SDK. Release signing requires local key properties; it does not fall back to a debug signature. The app identity is `com.venuewrangler.app`. iOS deployment target is 15.0 and the checked-in project uses Swift Package Manager; missing Podfile is not a CocoaPods defect for this setup. Location/camera/photo usage descriptions and native entitlements were inspected, but signing, plugin linkage and permissions were not exercised on devices.

### 1.2 Automated checks and recorded results

Commands ran from `apps/mobile` unless otherwise stated. Initial restricted-shell Flutter probes failed/hung because the sandbox runtime reported a null executable path. The authorized checks were rerun through the approved execution environment; those are the results below. No unapproved database access workaround was used.

| Check | Result / retained output |
|---|---|
| `flutter --version` | Flutter 3.47.5, stable. |
| `dart --version` | Dart SDK 3.13.4. |
| `flutter pub get --enforce-lockfile` | Passed; existing lockfile enforced. No upgrades or tracked dependency changes. |
| `flutter analyze --no-pub` | **Passed**, exit 0: `No issues found!`; 198.1 seconds. |
| `dart format --set-exit-if-changed --output=none .` | **Traversal failed** with `PathNotFoundException` in `Directory.listSync` for a stale generated build path. It made no edits. This is a tool/generated-directory limitation, not a discovered formatting violation. |
| `dart format --set-exit-if-changed --output=none lib test` | **Passed**, exit 0: `Formatted 230 files (0 changed) in 4.92 seconds.` Covers all Dart source/tests outside excluded generated folders. |
| `flutter test --no-pub --reporter expanded` | **Passed**, exit 0: **202 tests**, approximately 1 minute 41 seconds. No failed or skipped tests reported. |
| `flutter pub outdated` | Passed, exit 0. Reports 13 upgradable locked dependencies and 30 constrained dependencies; two discontinued transitives: `flutter_secure_storage_macos` and `js`. This is not a vulnerability scan. |
| Root `npm test -- --reporter=dot` | **Passed**, exit 0: 2 test files, **12 tests**, 2.05 seconds reported by Vitest. |
| Root `npm run typecheck` | **Passed**, exit 0: `tsc --noEmit`. Root tsconfig excludes marketing, Edge Functions and Flutter; this is not an Edge/marketing typecheck. |
| Read-only parser probe with Node's TypeScript stripping | Truncated CBOR `[0x83]` decoded as `[0,0,0]`. DER bytes `[0x30,0x84,0xff,0xff,0xff,0xfa]` returned a constructed node with `start=0,end=0`; no unbounded loop was run. See VW-037. |

Missing/unexecuted coverage: `apps/mobile/integration_test/` contains only a scaffold README; no real Auth/RLS/offline integration tests exist there. All 38 pgTAP suite files, seed/fixtures and rollback SQL were read, **not executed**, because replaying them writes to a database and is outside this audit's authorization. Deno helper tests were read, not run. No Android/iOS release build, Flutter web build, browser/device session, real App Attest/Play Integrity proof, live ClamAV connection, provider OAuth/Stripe transaction, APNs/FCM delivery, backup restore, or deployed Cloudflare route verification was performed.

Existing Flutter mocks prove selected client behavior, not production RLS or native plugins. Important absent regression scenarios include persisted-conflict recovery after restart, revoked-manager OAuth callback, removed-member push delivery, overlapping table holds/capacity, simultaneous BEO conversion/Checkout, remote venue timezone/DST, narrow annotation toolbar, and retrieving uploaded incident evidence.

### 1.3 Live database access and SQL conclusions

The configured project reference is `puttwjwmwrzmhpsjykuj` (from checked configuration/link metadata). The Supabase connector listed other accessible projects, but did not list this project. A target-specific project lookup returned **Permission denied (MCP -32600)**. Those unrelated projects were not queried; no SQL was sent to any database.

Consequently, applied migration history, live tables/policies/grants/indexes, Storage object bytes, queue/job state, cron installation/run history, orphaned live references and provider configuration are **Needs verification**. The audit reasons from the final migration definitions in source, including later replacements; it does not assume every source migration has been deployed.

Static checks covered table/column/model types, nullable fields and status strings, immutable tenant ownership, membership-derived tenant scope, security-definer caller checks, restricted grants, private Storage policies, direct-write paths, trigger order, advisory locks, relationship scope and FK/cascade/index definitions. Later fixes for polymorphic NEW/OLD record fields, inventory count closure, floor scope, time-entry timestamp integrity and Stripe customer binding were recognized rather than re-reported as still broken.

Index observations: the source has reservation venue/time/status indexes, assignment table/reservation indexes, recent POS FK indexes, inventory stock/count/history indexes and one-open-punch uniqueness. Missing overlap/capacity enforcement and tenant-scoped links are listed as findings. No broad missing-index claim is justified without query plans/cardinality. Reservation default queries deliberately paginate past the local `max_rows=1000`; the resulting load-to-exhaustion performance issue is VW-027.

Potential dormant schema is inventoried, not automatically labelled defective: reservation connection/deposit-era fields, household links, conversation read markers, legacy POS command queues and payroll integration rows have partial/no active Flutter consumption. Their removal needs a usage/deployment decision and a live dependency check. Do not drop them from this audit.

### 1.4 Antigravity verification and combined result

The 29 Antigravity claims have been reconciled individually against this checkout. **9 claims are merged/requalified into 10 existing VW findings; 8 are contradicted by the source as stated; 8 need additional evidence or reproduction; 4 describe intentional behavior, architectural patterns, or unresolved product scope.** These groups are mutually exclusive. Duplicate claims do not increase the 47-finding total. Appendix D records every original ID, its disposition, exact supporting/correcting source locations, and the sanitized original draft.

Retained mapping: SEC-04 → VW-024; DAT-01 → VW-003; DAT-02 → VW-003/VW-019/VW-020; COR-01 → VW-013; PERF-01 → VW-027; NAV-01 → VW-026; PERF-02 → VW-046; DAT-03 → VW-023; BUILD-01 → VW-045. The original three Critical credential claims are not established incidents: presence of ignored local files is confirmed, while exposure, credential validity and compromise remain unverified. The report preserves that limitation without retaining credential values.

The remediation added persistent offline conflict state, current-membership checks for notification and OAuth delivery, floor-assignment overlap/capacity protections, safe floor-draft merging, tenant-scoped guest/staff references, serialized BEO conversion, atomic AI usage accounting and account-deletion claims, mutation zero-row handling, incident evidence retrieval, safer push routing, local queue encryption migration, parser bounds, and UI/lifecycle fixes. The same-frame double-submit claim UI-01 remains **Needs verification**: synchronous assignment of a busy flag alone does not synchronously replace an already-built button callback; database uniqueness protects persisted open punches.

Validation provenance: automated results in §1.2 are from the pre-remediation baseline, not these changes. The current patch has not had a completed Flutter analysis/test run; the Dart executable stalled during the formatting attempt. `git diff --check` passed for the current working tree. SQL was added to source only. Live schema/deployment state, release signing, device behavior and conditional claims remain unverified.

## 2. Coverage

The source/config/assets inventory has **626 files**: **538 reviewed**, **48 binary assets inspected for metadata**, **33 reference/governance documents inventoried only**, **6 generated site outputs excluded from manual source review**, and **1 unrelated tool metadata file inventoried only**. Every **185 lib Dart + 45 test Dart = 230 Dart files** and every **120 SQL file** was read. All Android/iOS/web text/configuration files, CI workflows, env examples, Edge Function source/helper files and package manifests are included. Review means source/structure inspection, not execution or production verification.

The checklist below names each file individually. Entries marked `[ ] N` are explicitly **not read**: historical handoffs/plans/review snapshots or governance/product reference documents are outside the mandatory Dart/platform/SQL inspection and were not treated as current implementation/compliance evidence. `[ ] G` marks generated outputs whose authored source was inspected instead. `[ ] I` is unrelated tool identity metadata. `[x] B` means image dimensions/mode/size or binary size was inspected; artwork, video playback and PDF rendering were not reviewed. Appendix A provides the full source tree with these statuses.

Ignored local material is outside the non-generated source inventory. Names/metadata only were inspected for `credentials.json`, `credentials/`, `keys/private-key.pem`, `.env.local` and signing/config files; credential validity, encryption-at-rest, historical Git exposure, backup/sync permissions and live secret provisioning were not verified. The development/production JSONs were parsed only for key names and Supabase-origin equality; no key values are reproduced. The optional staging JSON is absent locally, but its example and entrypoint exist.

### 2.1 File-by-file checklist

- [ ] **I** `.freebuff/project-id` — unrelated tool metadata; inventoried only
- [x] **R** `.github/dependabot.yml` — source/config/structure reviewed
- [x] **R** `.github/workflows/codeql.yml` — source/config/structure reviewed
- [x] **R** `.github/workflows/deploy-cloudflare-pages.yml` — source/config/structure reviewed
- [x] **R** `.github/workflows/flutter-ci.yml` — source/config/structure reviewed
- [x] **R** `.github/workflows/prowler-compliance.yml` — source/config/structure reviewed
- [x] **R** `.github/workflows/supabase-ci.yml` — source/config/structure reviewed
- [x] **R** `.github/workflows/supabase-database-backup.yml` — source/config/structure reviewed
- [x] **R** `.github/workflows/supabase-storage-backup.yml` — source/config/structure reviewed
- [x] **R** `.gitignore` — source/config/structure reviewed
- [x] **R** `AGENTS.md` — source/config/structure reviewed
- [x] **R** `CLAUDE.md` — source/config/structure reviewed
- [x] **R** `README.md` — source/config/structure reviewed
- [x] **R** `apps/mobile/.gitignore` — source/config/structure reviewed
- [x] **R** `apps/mobile/.metadata` — source/config/structure reviewed
- [x] **R** `apps/mobile/README.md` — source/config/structure reviewed
- [x] **R** `apps/mobile/analysis_options.yaml` — source/config/structure reviewed
- [x] **R** `apps/mobile/android/.gitignore` — source/config/structure reviewed
- [x] **R** `apps/mobile/android/app/build.gradle.kts` — source/config/structure reviewed
- [x] **R** `apps/mobile/android/app/google-services.json` — source/config/structure reviewed
- [x] **R** `apps/mobile/android/app/src/debug/AndroidManifest.xml` — source/config/structure reviewed
- [x] **R** `apps/mobile/android/app/src/main/AndroidManifest.xml` — source/config/structure reviewed
- [x] **R** `apps/mobile/android/app/src/main/kotlin/com/venuewrangler/app/MainActivity.kt` — source/config/structure reviewed
- [x] **R** `apps/mobile/android/app/src/main/res/drawable-v21/launch_background.xml` — source/config/structure reviewed
- [x] **R** `apps/mobile/android/app/src/main/res/drawable/launch_background.xml` — source/config/structure reviewed
- [x] **B** `apps/mobile/android/app/src/main/res/mipmap-hdpi/ic_launcher.png` — binary metadata only; no visual/playback/render verification
- [x] **B** `apps/mobile/android/app/src/main/res/mipmap-mdpi/ic_launcher.png` — binary metadata only; no visual/playback/render verification
- [x] **B** `apps/mobile/android/app/src/main/res/mipmap-xhdpi/ic_launcher.png` — binary metadata only; no visual/playback/render verification
- [x] **B** `apps/mobile/android/app/src/main/res/mipmap-xxhdpi/ic_launcher.png` — binary metadata only; no visual/playback/render verification
- [x] **B** `apps/mobile/android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png` — binary metadata only; no visual/playback/render verification
- [x] **R** `apps/mobile/android/app/src/main/res/values-night/styles.xml` — source/config/structure reviewed
- [x] **R** `apps/mobile/android/app/src/main/res/values/styles.xml` — source/config/structure reviewed
- [x] **R** `apps/mobile/android/app/src/profile/AndroidManifest.xml` — source/config/structure reviewed
- [x] **R** `apps/mobile/android/build.gradle.kts` — source/config/structure reviewed
- [x] **R** `apps/mobile/android/gradle.properties` — source/config/structure reviewed
- [x] **R** `apps/mobile/android/gradle/wrapper/gradle-wrapper.properties` — source/config/structure reviewed
- [x] **R** `apps/mobile/android/settings.gradle.kts` — source/config/structure reviewed
- [x] **B** `apps/mobile/assets/video/intro.mp4` — binary metadata only; no visual/playback/render verification
- [x] **R** `apps/mobile/env/development.json.example` — source/config/structure reviewed
- [x] **R** `apps/mobile/env/production.json.example` — source/config/structure reviewed
- [x] **R** `apps/mobile/env/staging.json.example` — source/config/structure reviewed
- [x] **R** `apps/mobile/integration_test/README.md` — source/config/structure reviewed
- [x] **R** `apps/mobile/ios/.gitignore` — source/config/structure reviewed
- [x] **R** `apps/mobile/ios/Flutter/AppFrameworkInfo.plist` — source/config/structure reviewed
- [x] **R** `apps/mobile/ios/Flutter/Debug.xcconfig` — source/config/structure reviewed
- [x] **R** `apps/mobile/ios/Flutter/Release.xcconfig` — source/config/structure reviewed
- [x] **R** `apps/mobile/ios/Runner.xcodeproj/project.pbxproj` — source/config/structure reviewed
- [x] **R** `apps/mobile/ios/Runner.xcodeproj/project.xcworkspace/contents.xcworkspacedata` — source/config/structure reviewed
- [x] **R** `apps/mobile/ios/Runner.xcodeproj/project.xcworkspace/xcshareddata/IDEWorkspaceChecks.plist` — source/config/structure reviewed
- [x] **R** `apps/mobile/ios/Runner.xcodeproj/project.xcworkspace/xcshareddata/WorkspaceSettings.xcsettings` — source/config/structure reviewed
- [x] **R** `apps/mobile/ios/Runner.xcodeproj/xcshareddata/xcschemes/Runner.xcscheme` — source/config/structure reviewed
- [x] **R** `apps/mobile/ios/Runner.xcworkspace/contents.xcworkspacedata` — source/config/structure reviewed
- [x] **R** `apps/mobile/ios/Runner.xcworkspace/xcshareddata/IDEWorkspaceChecks.plist` — source/config/structure reviewed
- [x] **R** `apps/mobile/ios/Runner.xcworkspace/xcshareddata/WorkspaceSettings.xcsettings` — source/config/structure reviewed
- [x] **R** `apps/mobile/ios/Runner/AppAttestPlugin.swift` — source/config/structure reviewed
- [x] **R** `apps/mobile/ios/Runner/AppDelegate.swift` — source/config/structure reviewed
- [x] **R** `apps/mobile/ios/Runner/Assets.xcassets/AppIcon.appiconset/Contents.json` — source/config/structure reviewed
- [x] **B** `apps/mobile/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-1024x1024@1x.png` — binary metadata only; no visual/playback/render verification
- [x] **B** `apps/mobile/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-20x20@1x.png` — binary metadata only; no visual/playback/render verification
- [x] **B** `apps/mobile/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-20x20@2x.png` — binary metadata only; no visual/playback/render verification
- [x] **B** `apps/mobile/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-20x20@3x.png` — binary metadata only; no visual/playback/render verification
- [x] **B** `apps/mobile/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-29x29@1x.png` — binary metadata only; no visual/playback/render verification
- [x] **B** `apps/mobile/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-29x29@2x.png` — binary metadata only; no visual/playback/render verification
- [x] **B** `apps/mobile/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-29x29@3x.png` — binary metadata only; no visual/playback/render verification
- [x] **B** `apps/mobile/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-40x40@1x.png` — binary metadata only; no visual/playback/render verification
- [x] **B** `apps/mobile/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-40x40@2x.png` — binary metadata only; no visual/playback/render verification
- [x] **B** `apps/mobile/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-40x40@3x.png` — binary metadata only; no visual/playback/render verification
- [x] **B** `apps/mobile/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-60x60@2x.png` — binary metadata only; no visual/playback/render verification
- [x] **B** `apps/mobile/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-60x60@3x.png` — binary metadata only; no visual/playback/render verification
- [x] **B** `apps/mobile/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-76x76@1x.png` — binary metadata only; no visual/playback/render verification
- [x] **B** `apps/mobile/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-76x76@2x.png` — binary metadata only; no visual/playback/render verification
- [x] **B** `apps/mobile/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-83.5x83.5@2x.png` — binary metadata only; no visual/playback/render verification
- [x] **R** `apps/mobile/ios/Runner/Assets.xcassets/LaunchImage.imageset/Contents.json` — source/config/structure reviewed
- [x] **B** `apps/mobile/ios/Runner/Assets.xcassets/LaunchImage.imageset/LaunchImage.png` — binary metadata only; no visual/playback/render verification
- [x] **B** `apps/mobile/ios/Runner/Assets.xcassets/LaunchImage.imageset/LaunchImage@2x.png` — binary metadata only; no visual/playback/render verification
- [x] **B** `apps/mobile/ios/Runner/Assets.xcassets/LaunchImage.imageset/LaunchImage@3x.png` — binary metadata only; no visual/playback/render verification
- [x] **R** `apps/mobile/ios/Runner/Assets.xcassets/LaunchImage.imageset/README.md` — source/config/structure reviewed
- [x] **R** `apps/mobile/ios/Runner/Base.lproj/LaunchScreen.storyboard` — source/config/structure reviewed
- [x] **R** `apps/mobile/ios/Runner/Base.lproj/Main.storyboard` — source/config/structure reviewed
- [x] **R** `apps/mobile/ios/Runner/Info.plist` — source/config/structure reviewed
- [x] **R** `apps/mobile/ios/Runner/PushNotificationsPlugin.swift` — source/config/structure reviewed
- [x] **R** `apps/mobile/ios/Runner/Runner-Bridging-Header.h` — source/config/structure reviewed
- [x] **R** `apps/mobile/ios/Runner/Runner.entitlements` — source/config/structure reviewed
- [x] **R** `apps/mobile/ios/Runner/RunnerRelease.entitlements` — source/config/structure reviewed
- [x] **R** `apps/mobile/ios/Runner/SceneDelegate.swift` — source/config/structure reviewed
- [x] **R** `apps/mobile/ios/RunnerTests/RunnerTests.swift` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/app/app.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/app/app_shell.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/app/bootstrap.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/app/intro_video_screen.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/app/router.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/core/auth/auth_providers.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/core/auth/auth_repository.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/core/auth/sign_out_service.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/core/config/env_config.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/core/config/flavor.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/core/errors/app_error.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/core/errors/error_reporter.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/core/location/location_service.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/core/network/supabase_providers.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/core/offline/README.md` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/core/offline/offline_queue_connectivity.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/core/offline/offline_queue_controller.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/core/offline/offline_queue_providers.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/core/offline/offline_queue_store.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/core/offline/pending_mutation.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/core/security/README.md` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/core/security/app_attest_providers.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/core/security/app_attest_service.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/core/storage/secure_local_storage.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/core/storage/secure_session_storage.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/core/theme/app_colors.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/core/theme/app_theme.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/core/theme/ops_colors.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/core/theme/theme_mode_provider.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/core/widgets/blueprint_grid.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/core/widgets/ops_panel.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/core/widgets/state_views.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/core/widgets/status_chip.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/ai/README.md` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/ai/application/ai_providers.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/ai/data/ai_repository.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/ai/domain/ai_models.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/ai/presentation/wrangler_assistant_screen.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/auth/reset_password_screen.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/auth/sign_in_screen.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/auth/sign_up_screen.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/billing/README.md` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/billing/application/billing_providers.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/billing/data/billing_repository.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/billing/domain/subscription.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/billing/presentation/billing_screen.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/chat/README.md` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/chat/application/chat_providers.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/chat/data/chat_repository.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/chat/domain/chat_message.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/chat/domain/conversation.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/chat/presentation/chat_screen.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/checklists/README.md` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/checklists/application/checklists_providers.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/checklists/data/checklists_repository.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/checklists/domain/checklist_template.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/checklists/domain/item_result.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/checklists/presentation/checklist_completion_screen.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/checklists/presentation/checklist_list_screen.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/crm/README.md` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/crm/application/crm_providers.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/crm/data/crm_repository.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/crm/domain/crm_beo.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/crm/domain/crm_beo_charge.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/crm/domain/crm_contract.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/crm/domain/crm_lead.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/crm/presentation/crm_beo_detail_screen.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/crm/presentation/crm_lead_detail_screen.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/crm/presentation/crm_screen.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/dashboard/README.md` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/dashboard/presentation/dashboard_screen.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/dashboard/presentation/more_screen.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/documents/README.md` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/documents/application/document_picker_service.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/documents/application/documents_providers.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/documents/data/documents_repository.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/documents/domain/venue_document.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/documents/presentation/documents_screen.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/employee/application/employee_providers.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/employee/domain/employee_day.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/employee/presentation/employee_home_screen.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/employee/presentation/profile_screen.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/events/README.md` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/events/application/events_providers.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/events/data/events_repository.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/events/domain/event.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/events/presentation/event_list_screen.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/floor/README.md` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/floor/application/floor_editor_controller.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/floor/application/floor_providers.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/floor/data/floor_repository.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/floor/domain/editor_table.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/floor/domain/floor_plan.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/floor/domain/floor_table.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/floor/domain/table_status_style.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/floor/presentation/floor_plan_editor_screen.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/floor/presentation/floor_plan_screen.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/floor/presentation/live_floor_map.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/guests_reservations/README.md` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/guests_reservations/application/guests_reservations_providers.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/guests_reservations/data/guests_reservations_repository.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/guests_reservations/domain/guest.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/guests_reservations/domain/reservation.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/guests_reservations/presentation/reservations_screen.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/incidents/README.md` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/incidents/application/incidents_providers.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/incidents/data/incidents_repository.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/incidents/domain/incident.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/incidents/presentation/incident_list_screen.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/insights/README.md` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/insights/application/insights_providers.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/insights/data/insights_repository.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/insights/domain/shift_insight.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/insights/presentation/shift_insights_screen.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/integrations/README.md` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/integrations/application/integrations_providers.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/integrations/data/integrations_repository.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/integrations/domain/payroll_connection.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/integrations/presentation/integrations_screen.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/inventory/README.md` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/inventory/application/inventory_providers.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/inventory/data/inventory_repository.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/inventory/domain/inventory_item.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/inventory/domain/inventory_v2.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/inventory/presentation/inventory_action_sheet.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/inventory/presentation/inventory_admin_screen.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/inventory/presentation/inventory_count_screen.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/inventory/presentation/inventory_import_screen.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/inventory/presentation/inventory_item_screen.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/inventory/presentation/inventory_list_screen.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/inventory/presentation/inventory_widgets.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/media/README.md` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/media/application/image_picker_service.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/media/application/media_providers.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/media/application/photo_annotator.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/media/data/media_repository.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/media/domain/annotation.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/media/presentation/photo_annotation_screen.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/notifications/README.md` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/notifications/application/notification_routing.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/notifications/application/notification_tap_service.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/notifications/application/notifications_providers.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/notifications/application/push_registration_service.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/notifications/data/notifications_repository.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/notifications/domain/notification_event.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/notifications/presentation/notifications_screen.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/organizations/README.md` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/organizations/application/organizations_providers.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/organizations/application/workspace_provisioning.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/organizations/data/organizations_repository.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/organizations/domain/organization.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/organizations/domain/workspace_name.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/organizations/domain/workspace_timezones.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/organizations/presentation/create_workspace_dialog.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/organizations/presentation/organization_venue_switcher_screen.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/pos/README.md` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/pos/application/pos_providers.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/pos/data/pos_repository.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/pos/domain/pos_check.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/pos/domain/pos_connection.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/pos/presentation/pos_management_screen.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/schedules/README.md` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/schedules/application/schedules_providers.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/schedules/data/schedules_repository.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/schedules/domain/schedule_timeline.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/schedules/domain/shift.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/schedules/presentation/schedule_list_screen.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/schedules/presentation/schedule_timeline_screen.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/settings/README.md` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/settings/application/settings_providers.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/settings/data/settings_repository.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/settings/domain/profile.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/settings/presentation/delete_account_button.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/settings/presentation/settings_screen.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/shift_mode/domain/shift_mode.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/shift_mode/presentation/shift_mode_screen.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/shift_mode/presentation/shift_widgets.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/staff_requests/README.md` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/staff_requests/application/staff_requests_providers.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/staff_requests/data/staff_requests_repository.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/staff_requests/domain/staff_request.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/staff_requests/presentation/staff_requests_screen.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/tasks/README.md` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/tasks/application/task_status_change.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/tasks/application/tasks_providers.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/tasks/data/tasks_repository.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/tasks/domain/operational_task.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/tasks/domain/task_board.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/tasks/presentation/task_board_screen.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/tasks/presentation/task_list_screen.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/time_clock/README.md` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/time_clock/application/time_clock_providers.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/time_clock/data/time_clock_repository.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/time_clock/domain/geofence_helper.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/time_clock/domain/time_entry.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/time_clock/presentation/time_clock_screen.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/venues/README.md` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/venues/application/venues_providers.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/venues/data/venues_repository.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/venues/domain/venue.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/workforce/README.md` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/workforce/application/employee_profiles_providers.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/workforce/application/workforce_providers.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/workforce/data/employee_profiles_repository.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/workforce/data/workforce_repository.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/workforce/domain/employee_hr_profile.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/workforce/domain/workforce_models.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/workforce/presentation/employee_profile_widgets.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/features/workforce/presentation/workforce_roster_screen.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/main_development.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/main_production.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/lib/main_staging.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/pubspec.lock` — source/config/structure reviewed
- [x] **R** `apps/mobile/pubspec.yaml` — source/config/structure reviewed
- [x] **R** `apps/mobile/test/app/navigation_test.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/test/core/auth/session_isolation_test.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/test/core/config/flavor_test.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/test/core/offline/offline_queue_controller_test.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/test/core/offline/offline_queue_store_test.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/test/core/offline/secure_storage_offline_queue_store_test.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/test/core/security/app_attest_service_test.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/test/core/theme/app_theme_test.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/test/features/auth/reset_password_test.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/test/features/auth/sign_in_screen_test.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/test/features/auth/sign_up_screen_test.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/test/features/billing/billing_screen_test.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/test/features/chat/chat_screen_test.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/test/features/checklists/checklist_completion_screen_test.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/test/features/checklists/checklist_list_screen_test.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/test/features/crm/add_beo_charge_dialog_test.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/test/features/crm/crm_screen_test.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/test/features/employee/employee_home_test.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/test/features/floor/floor_editor_controller_test.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/test/features/floor/floor_plan_editor_screen_test.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/test/features/floor/floor_plan_screen_test.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/test/features/guests_reservations/reservations_screen_test.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/test/features/incidents/incident_list_screen_test.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/test/features/insights/shift_insights_screen_test.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/test/features/inventory/inventory_repository_test.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/test/features/inventory/inventory_screens_test.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/test/features/inventory/inventory_v2_test.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/test/features/media/media_providers_test.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/test/features/media/photo_annotation_test.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/test/features/notifications/notification_routing_test.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/test/features/notifications/notifications_screen_test.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/test/features/organizations/organization_venue_switcher_screen_test.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/test/features/organizations/workspace_provisioning_test.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/test/features/organizations/workspace_timezones_test.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/test/features/pos/pos_management_screen_test.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/test/features/schedules/schedule_timeline_test.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/test/features/settings/delete_account_button_test.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/test/features/shift_mode/shift_mode_test.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/test/features/staff_requests/staff_requests_screen_test.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/test/features/tasks/task_board_screen_test.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/test/features/tasks/task_list_screen_test.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/test/features/time_clock/time_clock_screen_test.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/test/features/time_clock/time_entry_domain_test.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/test/features/workforce/employee_profiles_test.dart` — source/config/structure reviewed
- [x] **R** `apps/mobile/test/features/workforce/roster_member_test.dart` — source/config/structure reviewed
- [x] **B** `apps/mobile/web/favicon.png` — binary metadata only; no visual/playback/render verification
- [x] **R** `apps/mobile/web/flutter_bootstrap.js` — source/config/structure reviewed
- [x] **B** `apps/mobile/web/icons/Icon-192.png` — binary metadata only; no visual/playback/render verification
- [x] **B** `apps/mobile/web/icons/Icon-512.png` — binary metadata only; no visual/playback/render verification
- [x] **B** `apps/mobile/web/icons/Icon-maskable-192.png` — binary metadata only; no visual/playback/render verification
- [x] **B** `apps/mobile/web/icons/Icon-maskable-512.png` — binary metadata only; no visual/playback/render verification
- [x] **R** `apps/mobile/web/index.html` — source/config/structure reviewed
- [x] **R** `apps/mobile/web/manifest.json` — source/config/structure reviewed
- [x] **R** `codemagic.yaml` — source/config/structure reviewed
- [ ] **N** `docs/ANTIGRAVITY_HANDOFF_BILLING.md` — reference/governance document inventoried; not current implementation/compliance evidence
- [ ] **N** `docs/CLAUDE_HANDOFF_REPO_REVIEW_FIXES.md` — reference/governance document inventoried; not current implementation/compliance evidence
- [ ] **N** `docs/HANDOFF_CODE_REVIEW_FIXES.md` — reference/governance document inventoried; not current implementation/compliance evidence
- [ ] **N** `docs/HANDOFF_GROK_AUDIT_FIXES.md` — reference/governance document inventoried; not current implementation/compliance evidence
- [ ] **N** `docs/cloud-security-triage-2026-09-08.md` — reference/governance document inventoried; not current implementation/compliance evidence
- [x] **R** `docs/code-review-2026-10-07.md` — source/config/structure reviewed
- [x] **R** `docs/integrations/pos-webhook.md` — source/config/structure reviewed
- [ ] **N** `docs/inventory-recipes-and-units.md` — reference/governance document inventoried; not current implementation/compliance evidence
- [ ] **N** `docs/inventory-v2.md` — reference/governance document inventoried; not current implementation/compliance evidence
- [ ] **N** `docs/luxury-command-system.md` — reference/governance document inventoried; not current implementation/compliance evidence
- [x] **R** `docs/migration/account-deletion-dispatch-setup.md` — source/config/structure reviewed
- [ ] **N** `docs/migration/flutter-cutover-closeout-2026-10-03.md` — reference/governance document inventoried; not current implementation/compliance evidence
- [ ] **N** `docs/migration/flutter-supabase-rebuild-plan.md` — reference/governance document inventoried; not current implementation/compliance evidence
- [ ] **N** `docs/migration/phase4-handoff-batch2.txt` — reference/governance document inventoried; not current implementation/compliance evidence
- [ ] **N** `docs/migration/phase4-port-remaining-modules-handoff.md` — reference/governance document inventoried; not current implementation/compliance evidence
- [ ] **N** `docs/migration/phase4-validation-report.md` — reference/governance document inventoried; not current implementation/compliance evidence
- [ ] **N** `docs/migration/phase5-validation-report.md` — reference/governance document inventoried; not current implementation/compliance evidence
- [x] **R** `docs/migration/pos-schedule-platform-rollback.sql` — source/config/structure reviewed
- [x] **R** `docs/migration/push-dispatch-setup.md` — source/config/structure reviewed
- [ ] **N** `docs/pos-integration-platform.md` — reference/governance document inventoried; not current implementation/compliance evidence
- [ ] **N** `docs/privacy-policy.md` — reference/governance document inventoried; not current implementation/compliance evidence
- [x] **R** `docs/production-operations.md` — source/config/structure reviewed
- [ ] **N** `docs/production-readiness-2026-09-18.md` — reference/governance document inventoried; not current implementation/compliance evidence
- [ ] **N** `docs/release-quality-gates.md` — reference/governance document inventoried; not current implementation/compliance evidence
- [ ] **N** `docs/reviews/flutter-ui-profiles-correction-2026-10-06.md` — reference/governance document inventoried; not current implementation/compliance evidence
- [ ] **N** `docs/reviews/repo-review-2026-10-06.md` — reference/governance document inventoried; not current implementation/compliance evidence
- [ ] **N** `docs/security/REMEDIATION-HANDOFF.md` — reference/governance document inventoried; not current implementation/compliance evidence
- [x] **R** `docs/soc2/README.md` — source/config/structure reviewed
- [ ] **N** `docs/soc2/access-control-policy.md` — reference/governance document inventoried; not current implementation/compliance evidence
- [ ] **N** `docs/soc2/business-continuity-disaster-recovery.md` — reference/governance document inventoried; not current implementation/compliance evidence
- [ ] **N** `docs/soc2/data-retention-disposal-policy.md` — reference/governance document inventoried; not current implementation/compliance evidence
- [ ] **N** `docs/soc2/incident-response-plan.md` — reference/governance document inventoried; not current implementation/compliance evidence
- [ ] **N** `docs/soc2/information-security-policy.md` — reference/governance document inventoried; not current implementation/compliance evidence
- [ ] **N** `docs/soc2/prowler-guide.md` — reference/governance document inventoried; not current implementation/compliance evidence
- [ ] **N** `docs/soc2/soc2-controls-matrix.md` — reference/governance document inventoried; not current implementation/compliance evidence
- [ ] **N** `docs/soc2/vendor-management-policy.md` — reference/governance document inventoried; not current implementation/compliance evidence
- [ ] **N** `docs/tenant-isolation.md` — reference/governance document inventoried; not current implementation/compliance evidence
- [ ] **N** `docs/ui-redesign-progress.md` — reference/governance document inventoried; not current implementation/compliance evidence
- [ ] **N** `docs/wrangler-engine-v1.md` — reference/governance document inventoried; not current implementation/compliance evidence
- [ ] **N** `docs/wrangler-home-ui.md` — reference/governance document inventoried; not current implementation/compliance evidence
- [x] **R** `flutter-version.txt` — source/config/structure reviewed
- [x] **R** `package-lock.json` — source/config/structure reviewed
- [x] **R** `package.json` — source/config/structure reviewed
- [x] **R** `packages/marketing/README.md` — source/config/structure reviewed
- [x] **R** `packages/marketing/index.html` — source/config/structure reviewed
- [x] **R** `packages/marketing/package.json` — source/config/structure reviewed
- [x] **R** `packages/marketing/src/App.tsx` — source/config/structure reviewed
- [x] **R** `packages/marketing/src/main.tsx` — source/config/structure reviewed
- [x] **R** `packages/marketing/src/styles.css` — source/config/structure reviewed
- [x] **R** `packages/marketing/src/vite-env.d.ts` — source/config/structure reviewed
- [x] **R** `packages/marketing/tsconfig.json` — source/config/structure reviewed
- [x] **R** `packages/marketing/vite.config.ts` — source/config/structure reviewed
- [x] **B** `public/Venue_Wrangler_Sales_Deck.pdf` — binary metadata only; no visual/playback/render verification
- [x] **B** `public/images/vw_ai_inventory_ui.png` — binary metadata only; no visual/playback/render verification
- [x] **B** `public/images/vw_command_center_ui.png` — binary metadata only; no visual/playback/render verification
- [x] **B** `public/images/vw_floor_plan_ui.png` — binary metadata only; no visual/playback/render verification
- [x] **B** `public/images/vw_live_chat_ui.png` — binary metadata only; no visual/playback/render verification
- [x] **R** `public/sales-deck.html` — source/config/structure reviewed
- [x] **R** `public/support/index.html` — source/config/structure reviewed
- [x] **R** `scripts/audit-gate.mjs` — source/config/structure reviewed
- [x] **R** `scripts/build-site.mjs` — source/config/structure reviewed
- [x] **R** `scripts/make-appstore-screenshots.py` — source/config/structure reviewed
- [x] **R** `scripts/make-ipad-appstore-screenshots.py` — source/config/structure reviewed
- [x] **R** `scripts/make-review-screenshot.py` — source/config/structure reviewed
- [x] **R** `scripts/make-subscription-images.py` — source/config/structure reviewed
- [x] **R** `scripts/make-zeroed-appstore-screenshots.py` — source/config/structure reviewed
- [x] **R** `scripts/site-build-files.mjs` — source/config/structure reviewed
- [x] **R** `site/.well-known/apple-app-site-association` — source/config/structure reviewed
- [x] **R** `site/.well-known/assetlinks.json` — source/config/structure reviewed
- [x] **R** `site/.well-known/assetlinks.json.NEEDS_REAL_FINGERPRINT.md` — source/config/structure reviewed
- [x] **R** `site/404.html` — source/config/structure reviewed
- [x] **R** `site/_headers` — source/config/structure reviewed
- [x] **R** `site/_redirects` — source/config/structure reviewed
- [x] **R** `site/_routes.json` — source/config/structure reviewed
- [x] **R** `site/_worker.js` — source/config/structure reviewed
- [x] **B** `site/assets/01-dashboard.png` — binary metadata only; no visual/playback/render verification
- [x] **B** `site/assets/02-schedule.png` — binary metadata only; no visual/playback/render verification
- [x] **B** `site/assets/03-timeclock.png` — binary metadata only; no visual/playback/render verification
- [x] **B** `site/assets/04-floorplan.png` — binary metadata only; no visual/playback/render verification
- [x] **B** `site/assets/05-chat.png` — binary metadata only; no visual/playback/render verification
- [x] **B** `site/assets/logo.jpg` — binary metadata only; no visual/playback/render verification
- [x] **B** `site/assets/screen-availability.png` — binary metadata only; no visual/playback/render verification
- [x] **B** `site/assets/screen-command.png` — binary metadata only; no visual/playback/render verification
- [x] **B** `site/assets/screen-floor.png` — binary metadata only; no visual/playback/render verification
- [x] **B** `site/assets/screen-inventory.png` — binary metadata only; no visual/playback/render verification
- [x] **B** `site/assets/screen-reports.png` — binary metadata only; no visual/playback/render verification
- [x] **B** `site/assets/screen-reservations.png` — binary metadata only; no visual/playback/render verification
- [x] **B** `site/assets/venue-wrangler-ad.mp4` — binary metadata only; no visual/playback/render verification
- [x] **R** `site/billing/index.html` — source/config/structure reviewed
- [x] **R** `site/faq/index.html` — source/config/structure reviewed
- [ ] **G** `site/index.html` — generated output excluded; authored source reviewed
- [x] **R** `site/join/index.html` — source/config/structure reviewed
- [x] **R** `site/join/success/index.html` — source/config/structure reviewed
- [ ] **G** `site/marketing-assets/index-BD29tyyz.js` — generated output excluded; authored source reviewed
- [ ] **G** `site/marketing-assets/index-CKT30Hkh.js` — generated output excluded; authored source reviewed
- [ ] **G** `site/marketing-assets/index-CT2XBtsO.js` — generated output excluded; authored source reviewed
- [ ] **G** `site/marketing-assets/index-D4wbbrvQ.css` — generated output excluded; authored source reviewed
- [x] **R** `site/onboarding.spec.ts` — source/config/structure reviewed
- [ ] **G** `site/opener.js` — generated output excluded; authored source reviewed
- [x] **R** `site/opener.src.jsx` — source/config/structure reviewed
- [x] **R** `site/privacy/index.html` — source/config/structure reviewed
- [x] **R** `site/robots.txt` — source/config/structure reviewed
- [x] **R** `site/sitemap.xml` — source/config/structure reviewed
- [x] **R** `site/support/index.html` — source/config/structure reviewed
- [x] **R** `site/terms/index.html` — source/config/structure reviewed
- [x] **R** `store/README.md` — source/config/structure reviewed
- [x] **R** `store/app-store-connect.md` — source/config/structure reviewed
- [x] **B** `store/google-play-feature-graphic.png` — binary metadata only; no visual/playback/render verification
- [x] **R** `store/google-play.md` — source/config/structure reviewed
- [x] **R** `supabase/.env.example` — source/config/structure reviewed
- [x] **R** `supabase/config.toml` — source/config/structure reviewed
- [x] **R** `supabase/functions/_shared/apns.ts` — source/config/structure reviewed
- [x] **R** `supabase/functions/_shared/app-attest.ts` — source/config/structure reviewed
- [x] **R** `supabase/functions/_shared/cbor.ts` — source/config/structure reviewed
- [x] **R** `supabase/functions/_shared/clamav.ts` — source/config/structure reviewed
- [x] **R** `supabase/functions/_shared/cors.ts` — source/config/structure reviewed
- [x] **R** `supabase/functions/_shared/crypto.ts` — source/config/structure reviewed
- [x] **R** `supabase/functions/_shared/crypto_test.ts` — source/config/structure reviewed
- [x] **R** `supabase/functions/_shared/der.ts` — source/config/structure reviewed
- [x] **R** `supabase/functions/_shared/document-bytes.ts` — source/config/structure reviewed
- [x] **R** `supabase/functions/_shared/document-bytes_test.ts` — source/config/structure reviewed
- [x] **R** `supabase/functions/_shared/google-auth.ts` — source/config/structure reviewed
- [x] **R** `supabase/functions/_shared/groq.ts` — source/config/structure reviewed
- [x] **R** `supabase/functions/_shared/malware-scan.ts` — source/config/structure reviewed
- [x] **R** `supabase/functions/_shared/observability.ts` — source/config/structure reviewed
- [x] **R** `supabase/functions/_shared/play-integrity.ts` — source/config/structure reviewed
- [x] **R** `supabase/functions/_shared/play-integrity_test.ts` — source/config/structure reviewed
- [x] **R** `supabase/functions/_shared/push-delivery.ts` — source/config/structure reviewed
- [x] **R** `supabase/functions/_shared/stripe.ts` — source/config/structure reviewed
- [x] **R** `supabase/functions/_shared/supabase-clients.ts` — source/config/structure reviewed
- [x] **R** `supabase/functions/_shared/venue-auth.ts` — source/config/structure reviewed
- [x] **R** `supabase/functions/account-deletion-worker/index.ts` — source/config/structure reviewed
- [x] **R** `supabase/functions/ai-assistant/index.ts` — source/config/structure reviewed
- [x] **R** `supabase/functions/ai-assistant/prompts.ts` — source/config/structure reviewed
- [x] **R** `supabase/functions/crm-send-email/index.ts` — source/config/structure reviewed
- [x] **R** `supabase/functions/deno.json` — source/config/structure reviewed
- [x] **R** `supabase/functions/deno.lock` — source/config/structure reviewed
- [x] **R** `supabase/functions/device-attestation/index.ts` — source/config/structure reviewed
- [x] **R** `supabase/functions/documents-upload/index.ts` — source/config/structure reviewed
- [x] **R** `supabase/functions/gusto-oauth/index.ts` — source/config/structure reviewed
- [x] **R** `supabase/functions/notifications-dispatch/index.ts` — source/config/structure reviewed
- [x] **R** `supabase/functions/notifications-send/index.ts` — source/config/structure reviewed
- [x] **R** `supabase/functions/quickbooks-oauth/index.ts` — source/config/structure reviewed
- [x] **R** `supabase/functions/square-oauth/index.ts` — source/config/structure reviewed
- [x] **R** `supabase/functions/stripe-create-checkout/index.ts` — source/config/structure reviewed
- [x] **R** `supabase/functions/stripe-create-portal/index.ts` — source/config/structure reviewed
- [x] **R** `supabase/functions/stripe-webhook/index.ts` — source/config/structure reviewed
- [x] **R** `supabase/functions/toast-pos/index.ts` — source/config/structure reviewed
- [x] **R** `supabase/migrations/20261002154052_foundation_schema.sql` — source/config/structure reviewed
- [x] **R** `supabase/migrations/20261002154114_tasks_schema.sql` — source/config/structure reviewed
- [x] **R** `supabase/migrations/20261002154143_checklists_schema.sql` — source/config/structure reviewed
- [x] **R** `supabase/migrations/20261002154205_incidents_schema.sql` — source/config/structure reviewed
- [x] **R** `supabase/migrations/20261002154223_storage_buckets.sql` — source/config/structure reviewed
- [x] **R** `supabase/migrations/20261002154238_incident_attachments.sql` — source/config/structure reviewed
- [x] **R** `supabase/migrations/20261002154307_harden_try_cast_uuid_search_path.sql` — source/config/structure reviewed
- [x] **R** `supabase/migrations/20261002154310_harden_rls_performance.sql` — source/config/structure reviewed
- [x] **R** `supabase/migrations/20261002171532_ai_usage.sql` — source/config/structure reviewed
- [x] **R** `supabase/migrations/20261002172436_ai_usage_events_user_id_index.sql` — source/config/structure reviewed
- [x] **R** `supabase/migrations/20261002174928_workforce_invites.sql` — source/config/structure reviewed
- [x] **R** `supabase/migrations/20261002175142_inventory_schema.sql` — source/config/structure reviewed
- [x] **R** `supabase/migrations/20261002175340_schedules_schema.sql` — source/config/structure reviewed
- [x] **R** `supabase/migrations/20261002182117_subscriptions_schema.sql` — source/config/structure reviewed
- [x] **R** `supabase/migrations/20261002182919_payroll_connections_schema.sql` — source/config/structure reviewed
- [x] **R** `supabase/migrations/20261002183723_invite_redemption.sql` — source/config/structure reviewed
- [x] **R** `supabase/migrations/20261002184109_shift_swaps_schema.sql` — source/config/structure reviewed
- [x] **R** `supabase/migrations/20261002184420_device_attestation.sql` — source/config/structure reviewed
- [x] **R** `supabase/migrations/20261002184707_events_schema.sql` — source/config/structure reviewed
- [x] **R** `supabase/migrations/20261002185029_harden_subscription_is_entitled.sql` — source/config/structure reviewed
- [x] **R** `supabase/migrations/20261002205115_staff_requests_schema.sql` — source/config/structure reviewed
- [x] **R** `supabase/migrations/20261002233843_shift_insights_schema.sql` — source/config/structure reviewed
- [x] **R** `supabase/migrations/20261002233921_time_clock_schema.sql` — source/config/structure reviewed
- [x] **R** `supabase/migrations/20261002233940_ensure_public_grants.sql` — source/config/structure reviewed
- [x] **R** `supabase/migrations/20261002234421_storage_deletion_jobs_schema.sql` — source/config/structure reviewed
- [x] **R** `supabase/migrations/20261002235811_notifications_schema.sql` — source/config/structure reviewed
- [x] **R** `supabase/migrations/20261002235847_guests_reservations_schema.sql` — source/config/structure reviewed
- [x] **R** `supabase/migrations/20261002235927_floor_schema.sql` — source/config/structure reviewed
- [x] **R** `supabase/migrations/20261003000000_pos_schema.sql` — source/config/structure reviewed
- [x] **R** `supabase/migrations/20261003000037_chat_schema.sql` — source/config/structure reviewed
- [x] **R** `supabase/migrations/20261003000100_harden_batch2_search_path_and_rpc_grants.sql` — source/config/structure reviewed
- [x] **R** `supabase/migrations/20261003001000_storage_deletion_worker_and_schedule.sql` — source/config/structure reviewed
- [x] **R** `supabase/migrations/20261003005913_crm_schema.sql` — source/config/structure reviewed
- [x] **R** `supabase/migrations/20261003043737_documents_schema.sql` — source/config/structure reviewed
- [x] **R** `supabase/migrations/20261003113416_attestation_challenges_schema.sql` — source/config/structure reviewed
- [x] **R** `supabase/migrations/20261004023154_payment_and_notification_hardening.sql` — source/config/structure reviewed
- [x] **R** `supabase/migrations/20261004144042_remove_beo_deposit_and_stripe_connect.sql` — source/config/structure reviewed
- [x] **R** `supabase/migrations/20261005115202_chat_storage_conversation_scoping.sql` — source/config/structure reviewed
- [x] **R** `supabase/migrations/20261005115215_ai_budget_atomic_reservation.sql` — source/config/structure reviewed
- [x] **R** `supabase/migrations/20261005115222_stripe_webhook_idempotency.sql` — source/config/structure reviewed
- [x] **R** `supabase/migrations/20261005115231_storage_bucket_limits.sql` — source/config/structure reviewed
- [x] **R** `supabase/migrations/20261005115245_invite_redemption_confirmed_email.sql` — source/config/structure reviewed
- [x] **R** `supabase/migrations/20261005115252_drop_debug_helpers.sql` — source/config/structure reviewed
- [x] **R** `supabase/migrations/20261005214454_restrict_reserve_ai_budget.sql` — source/config/structure reviewed
- [x] **R** `supabase/migrations/20261005220028_notification_triggers_and_dispatch.sql` — source/config/structure reviewed
- [x] **R** `supabase/migrations/20261006150753_floor_layout_managers_and_atomic_publish.sql` — source/config/structure reviewed
- [x] **R** `supabase/migrations/20261006160946_staff_section_and_reservation_assignment.sql` — source/config/structure reviewed
- [x] **R** `supabase/migrations/20261006203252_harden_time_entry_integrity.sql` — source/config/structure reviewed
- [x] **R** `supabase/migrations/20261006203635_time_entry_breaks_comparison_fix.sql` — source/config/structure reviewed
- [x] **R** `supabase/migrations/20261006203829_time_entry_breaks_equal_hardening.sql` — source/config/structure reviewed
- [x] **R** `supabase/migrations/20261006212133_flutter_staff_hr_and_photos.sql` — source/config/structure reviewed
- [x] **R** `supabase/migrations/20261007021641_pos_schedule_platform.sql` — source/config/structure reviewed
- [x] **R** `supabase/migrations/20261007021847_pos_schedule_fk_indexes.sql` — source/config/structure reviewed
- [x] **R** `supabase/migrations/20261007131539_create_workspace_self_serve_signup.sql` — source/config/structure reviewed
- [x] **R** `supabase/migrations/20261007160000_crm_beo_charges.sql` — source/config/structure reviewed
- [x] **R** `supabase/migrations/20261007180000_account_deletion.sql` — source/config/structure reviewed
- [x] **R** `supabase/migrations/20261007190000_account_deletion_fixes.sql` — source/config/structure reviewed
- [x] **R** `supabase/migrations/20261007191000_create_workspace_timezone_validation.sql` — source/config/structure reviewed
- [x] **R** `supabase/migrations/20261007192000_venue_roster_rpc.sql` — source/config/structure reviewed
- [x] **R** `supabase/migrations/20261007193000_apply_stripe_subscription_state.sql` — source/config/structure reviewed
- [x] **R** `supabase/migrations/20261007200621_restaurant_inventory_v2.sql` — source/config/structure reviewed
- [x] **R** `supabase/migrations/20261007201000_review_fixes_stripe_inventory_roster.sql` — source/config/structure reviewed
- [x] **R** `supabase/migrations/20261007202000_review_tenant_guards.sql` — source/config/structure reviewed
- [x] **R** `supabase/migrations/20261007210000_fix_review_guard_record_fields.sql` — source/config/structure reviewed
- [x] **R** `supabase/migrations/20261010120000_retention_cleanup_in_database.sql` — source/config/structure reviewed
- [x] **R** `supabase/rollbacks/20261007131539_create_workspace_self_serve_signup.sql` — source/config/structure reviewed
- [x] **R** `supabase/rollbacks/20261007160000_crm_beo_charges.sql` — source/config/structure reviewed
- [x] **R** `supabase/rollbacks/20261007180000_account_deletion.sql` — source/config/structure reviewed
- [x] **R** `supabase/rollbacks/20261007190000_account_deletion_fixes.sql` — source/config/structure reviewed
- [x] **R** `supabase/rollbacks/20261007191000_create_workspace_timezone_validation.sql` — source/config/structure reviewed
- [x] **R** `supabase/rollbacks/20261007192000_venue_roster_rpc.sql` — source/config/structure reviewed
- [x] **R** `supabase/rollbacks/20261007193000_apply_stripe_subscription_state.sql` — source/config/structure reviewed
- [x] **R** `supabase/rollbacks/20261007201000_review_fixes_stripe_inventory_roster.sql` — source/config/structure reviewed
- [x] **R** `supabase/rollbacks/20261007210000_fix_review_guard_record_fields.sql` — source/config/structure reviewed
- [x] **R** `supabase/rollbacks/20261010120000_retention_cleanup_in_database.sql` — source/config/structure reviewed
- [x] **R** `supabase/seed.sql` — source/config/structure reviewed
- [x] **R** `supabase/tests/README.md` — source/config/structure reviewed
- [x] **R** `supabase/tests/ci_auth_stub.sql` — source/config/structure reviewed
- [x] **R** `supabase/tests/ci_grants_stub.sql` — source/config/structure reviewed
- [x] **R** `supabase/tests/ci_storage_stub.sql` — source/config/structure reviewed
- [x] **R** `supabase/tests/database/account_deletion.test.sql` — source/config/structure reviewed
- [x] **R** `supabase/tests/database/ai_usage_rls.test.sql` — source/config/structure reviewed
- [x] **R** `supabase/tests/database/attestation_challenges_rls.test.sql` — source/config/structure reviewed
- [x] **R** `supabase/tests/database/chat_rls.test.sql` — source/config/structure reviewed
- [x] **R** `supabase/tests/database/checklists_rls.test.sql` — source/config/structure reviewed
- [x] **R** `supabase/tests/database/create_workspace.test.sql` — source/config/structure reviewed
- [x] **R** `supabase/tests/database/crm_beo_charges.test.sql` — source/config/structure reviewed
- [x] **R** `supabase/tests/database/crm_rls.test.sql` — source/config/structure reviewed
- [x] **R** `supabase/tests/database/device_attestation_rls.test.sql` — source/config/structure reviewed
- [x] **R** `supabase/tests/database/documents_rls.test.sql` — source/config/structure reviewed
- [x] **R** `supabase/tests/database/employee_hr_profiles_rls.test.sql` — source/config/structure reviewed
- [x] **R** `supabase/tests/database/events_rls.test.sql` — source/config/structure reviewed
- [x] **R** `supabase/tests/database/floor_rls.test.sql` — source/config/structure reviewed
- [x] **R** `supabase/tests/database/foundation_rls.test.sql` — source/config/structure reviewed
- [x] **R** `supabase/tests/database/guests_reservations_rls.test.sql` — source/config/structure reviewed
- [x] **R** `supabase/tests/database/incident_attachments_rls.test.sql` — source/config/structure reviewed
- [x] **R** `supabase/tests/database/incidents_rls.test.sql` — source/config/structure reviewed
- [x] **R** `supabase/tests/database/inventory_rls.test.sql` — source/config/structure reviewed
- [x] **R** `supabase/tests/database/inventory_v2.test.sql` — source/config/structure reviewed
- [x] **R** `supabase/tests/database/invite_redemption.test.sql` — source/config/structure reviewed
- [x] **R** `supabase/tests/database/invites_rls.test.sql` — source/config/structure reviewed
- [x] **R** `supabase/tests/database/notification_receipts.test.sql` — source/config/structure reviewed
- [x] **R** `supabase/tests/database/notifications_rls.test.sql` — source/config/structure reviewed
- [x] **R** `supabase/tests/database/operational_tasks_rls.test.sql` — source/config/structure reviewed
- [x] **R** `supabase/tests/database/payroll_connections_rls.test.sql` — source/config/structure reviewed
- [x] **R** `supabase/tests/database/pos_rls.test.sql` — source/config/structure reviewed
- [x] **R** `supabase/tests/database/pos_schedule_platform.test.sql` — source/config/structure reviewed
- [x] **R** `supabase/tests/database/retention_cleanup.test.sql` — source/config/structure reviewed
- [x] **R** `supabase/tests/database/shift_insights_rls.test.sql` — source/config/structure reviewed
- [x] **R** `supabase/tests/database/shift_swaps_rls.test.sql` — source/config/structure reviewed
- [x] **R** `supabase/tests/database/shifts_rls.test.sql` — source/config/structure reviewed
- [x] **R** `supabase/tests/database/staff_requests_rls.test.sql` — source/config/structure reviewed
- [x] **R** `supabase/tests/database/storage_deletion_jobs_rls.test.sql` — source/config/structure reviewed
- [x] **R** `supabase/tests/database/storage_policies.test.sql` — source/config/structure reviewed
- [x] **R** `supabase/tests/database/stripe_subscription_state.test.sql` — source/config/structure reviewed
- [x] **R** `supabase/tests/database/subscriptions_rls.test.sql` — source/config/structure reviewed
- [x] **R** `supabase/tests/database/time_clock_rls.test.sql` — source/config/structure reviewed
- [x] **R** `supabase/tests/database/venue_roster.test.sql` — source/config/structure reviewed
- [x] **R** `supabase/tests/fixtures/inventory_v2_legacy.sql` — source/config/structure reviewed
- [x] **R** `supabase/tests/fixtures/inventory_v2_legacy_assertions.sql` — source/config/structure reviewed
- [x] **R** `tests/workflow-security.spec.ts` — source/config/structure reviewed
- [x] **R** `tool/test_inventory_v2_database.py` — source/config/structure reviewed
- [x] **R** `tsconfig.json` — source/config/structure reviewed
- [x] **R** `vitest.config.mts` — source/config/structure reviewed

## 3. Findings

Rows are sorted by severity, then category. **Needs verification** identifies product/platform-dependent items and unproven deployed outcomes. Suggested fixes are proposals only.

| ID | Severity | Category | File path and line number(s) | Description | Why it matters / how it could fail | Suggested fix | Effort |
|---|---|---|---|---|---|---|---|
| VW-001 | High | Database/booking integrity | [apps/mobile/lib/features/venues/domain/venue.dart:4-20](C:/Users/lwhob/OneDrive/Downloads/a0-project/apps/mobile/lib/features/venues/domain/venue.dart:4)<br>[apps/mobile/lib/features/schedules/domain/schedule_timeline.dart:9-31](C:/Users/lwhob/OneDrive/Downloads/a0-project/apps/mobile/lib/features/schedules/domain/schedule_timeline.dart:9)<br>[apps/mobile/lib/features/guests_reservations/domain/reservation.dart:44-45](C:/Users/lwhob/OneDrive/Downloads/a0-project/apps/mobile/lib/features/guests_reservations/domain/reservation.dart:44)<br>[apps/mobile/lib/features/crm/presentation/crm_screen.dart:295-302](C:/Users/lwhob/OneDrive/Downloads/a0-project/apps/mobile/lib/features/crm/presentation/crm_screen.dart:295) | Venue timezone is collected/stored at workspace creation but omitted from Venue and all operational date/time calculations use the device timezone. | A manager in a different timezone creates a reservation/BEO/shift at the wrong venue time; business-day filtering and DST behavior depend on the device. Exact production exposure needs verification. | Carry the IANA venue zone into domain objects and use timezone-aware creation/display/day windows consistently, with DST and remote-venue tests. | L |
| VW-002 | High | Database/booking integrity | [apps/mobile/lib/features/floor/application/floor_editor_controller.dart:318-340,361-377](C:/Users/lwhob/OneDrive/Downloads/a0-project/apps/mobile/lib/features/floor/application/floor_editor_controller.dart:318)<br>[supabase/migrations/20261006150753_floor_layout_managers_and_atomic_publish.sql:78-90](C:/Users/lwhob/OneDrive/Downloads/a0-project/supabase/migrations/20261006150753_floor_layout_managers_and_atomic_publish.sql:78) | Restoring an old draft treats tables added since the draft as deletions. | Manager A saves a draft; B adds an available table; A reloads live state and restores the draft. The new table is absent from the draft but present in published, so publishing deletes B's table. | Store a base revision/snapshot with the draft; merge newly added rows and reject stale updates/removals in save_floor_layout. DB migration and controller changes. | M |
| VW-003 | High | Database/booking integrity | [supabase/migrations/20261002235927_floor_schema.sql:152-169,302-350](C:/Users/lwhob/OneDrive/Downloads/a0-project/supabase/migrations/20261002235927_floor_schema.sql:152)<br>[supabase/migrations/20261007202000_review_tenant_guards.sql:194-229](C:/Users/lwhob/OneDrive/Downloads/a0-project/supabase/migrations/20261007202000_review_tenant_guards.sql:194) | Table assignments have no exclusion constraint or overlap check, and the assignment RPC inserts after locking without inspecting existing intervals. | Two bookings can reserve the same table for overlapping unreleased intervals. Advisory serialization alone does not reject the second assignment; direct authorized writes are also allowed. Verified statically, not against live data. | Add a partial interval exclusion constraint for unreleased assignments and validate/reconcile existing overlaps before migration; make RPC reject conflicts with useful UI errors. DB and app changes. | M |
| VW-004 | High | Offline/recovery | [apps/mobile/lib/core/offline/offline_queue_controller.dart:156-183](C:/Users/lwhob/OneDrive/Downloads/a0-project/apps/mobile/lib/core/offline/offline_queue_controller.dart:156) | Definitive conflicts are removed from the persisted queue and retained only in memory. | Restart discards unsynced task/checklist/incident conflicts; the user cannot recover or retry the lost mutation. | Persist conflict state and its reason until the user resolves or dismisses it. | M |
| VW-005 | High | Privacy/data handling | [supabase/migrations/20261007202000_review_tenant_guards.sql:708-736](C:/Users/lwhob/OneDrive/Downloads/a0-project/supabase/migrations/20261007202000_review_tenant_guards.sql:708) | Storage deletion marks jobs completed after deleting metadata with SQL. | Supabase documents that SQL deletes do not remove stored bytes; account/document cleanup leaves inaccessible objects and ongoing storage costs. | Use a Storage API worker; mark completed only after a successful remove response. DB change plus worker. | M |
| VW-006 | High | Privacy/data handling | [supabase/functions/_shared/push-delivery.ts:34-51](C:/Users/lwhob/OneDrive/Downloads/a0-project/supabase/functions/_shared/push-delivery.ts:34)<br>[supabase/migrations/20261007202000_review_tenant_guards.sql:531-554](C:/Users/lwhob/OneDrive/Downloads/a0-project/supabase/migrations/20261007202000_review_tenant_guards.sql:531) | Venue-wide and direct push delivery do not recheck current membership for every registered recipient. | Removing a staff membership leaves its enabled push token. venue_staff queries all venue tokens and user targets query IDs, so the removed person can continue receiving venue notifications although database reads are denied. | Join/filter tokens against current membership for every audience and invalidate registrations on membership changes; test removal and shared-device account changes. DB/function changes. | M |
| VW-007 | High | Security/authorization | [supabase/functions/square-oauth/index.ts:125-161](C:/Users/lwhob/OneDrive/Downloads/a0-project/supabase/functions/square-oauth/index.ts:125)<br>[supabase/functions/quickbooks-oauth/index.ts:125-166](C:/Users/lwhob/OneDrive/Downloads/a0-project/supabase/functions/quickbooks-oauth/index.ts:125)<br>[supabase/functions/gusto-oauth/index.ts:117-158](C:/Users/lwhob/OneDrive/Downloads/a0-project/supabase/functions/gusto-oauth/index.ts:117) | OAuth callbacks do not recheck the initiating user's current venue authorization. | A manager can initiate OAuth, lose their role, and complete consent within the signed state's ten-minute window; service-role upsert still replaces payroll credentials. Database read policies cannot stop service-role writes. | Recheck current membership and manager role before token exchange/persistence; bind provider and a single-use nonce to persisted OAuth state. DB/function changes. | M |
| VW-008 | Medium | AI/accounting | [supabase/functions/ai-assistant/index.ts:260-282](C:/Users/lwhob/OneDrive/Downloads/a0-project/supabase/functions/ai-assistant/index.ts:260)<br>[supabase/migrations/20261002171532_ai_usage.sql:45-64](C:/Users/lwhob/OneDrive/Downloads/a0-project/supabase/migrations/20261002171532_ai_usage.sql:45) | Committing AI reservations and recording actual spend are separate, unchecked writes. | If commit succeeds but usage insert fails, spend function counts neither the committed reservation nor a usage event. Concurrent budget checks can also run in the gap, allowing requests beyond the configured budget. | Atomically commit reservation plus usage in a service-only RPC, with idempotent request ID; return a controlled failure/reconciliation signal if accounting fails. DB/function changes. | M |
| VW-009 | Medium | Billing/accounting | [supabase/functions/stripe-create-checkout/index.ts:99-144](C:/Users/lwhob/OneDrive/Downloads/a0-project/supabase/functions/stripe-create-checkout/index.ts:99) | Concurrent checkout requests can create multiple subscription Checkout Sessions for one organization. | The existing-subscription guard runs before payment/webhook state; two requests see no active subscription and create independent sessions without a shared idempotency key. Completing both can create duplicate subscriptions, while the DB keeps only one subscription ID. Provider behavior needs integration verification. | Persist/reuse a single pending Checkout Session under an organization lock and reconcile duplicate subscriptions; test concurrent requests and abandoned sessions. DB/function changes. | M |
| VW-010 | Medium | Correctness/workflow | [apps/mobile/lib/app/router.dart:416-426](C:/Users/lwhob/OneDrive/Downloads/a0-project/apps/mobile/lib/app/router.dart:416) | Push routing uses kind only and ignores venue/organization identifiers. | Tapping a push from venue A while venue B is selected opens B's generic screen; the intended notification may appear absent. | Resolve authorized venue and target object from payload before navigation; test cross-venue taps. | M |
| VW-011 | Medium | Correctness/workflow | [apps/mobile/lib/features/schedules/data/schedules_repository.dart:127-178](C:/Users/lwhob/OneDrive/Downloads/a0-project/apps/mobile/lib/features/schedules/data/schedules_repository.dart:127)<br>[apps/mobile/lib/features/staff_requests/data/staff_requests_repository.dart:69-85](C:/Users/lwhob/OneDrive/Downloads/a0-project/apps/mobile/lib/features/staff_requests/data/staff_requests_repository.dart:69)<br>[apps/mobile/lib/features/events/data/events_repository.dart:58-66](C:/Users/lwhob/OneDrive/Downloads/a0-project/apps/mobile/lib/features/events/data/events_repository.dart:58) | Several mutations still treat a zero-row RLS-denied UPDATE/DELETE as success. | A supervisor or user whose permissions changed can see a success snackbar although schedules, swaps, requests or events did not change; tasks/incidents already handle this. | Require a returned row or authorized RPC with an explicit result; add denied-write tests. | M |
| VW-012 | Medium | Correctness/workflow | [apps/mobile/lib/features/employee/presentation/employee_home_screen.dart:79-80,214-240](C:/Users/lwhob/OneDrive/Downloads/a0-project/apps/mobile/lib/features/employee/presentation/employee_home_screen.dart:79)<br>[apps/mobile/lib/features/employee/presentation/profile_screen.dart:62-78](C:/Users/lwhob/OneDrive/Downloads/a0-project/apps/mobile/lib/features/employee/presentation/profile_screen.dart:62) | Employee home/profile convert failed operational queries into empty lists or zero KPIs. | Reservations/tasks/floor failures appear as no assignments or no tables; shift failures can show zero scheduled hours, masking a failed service during operations. | Preserve AsyncValue error states and show retry/unavailable labels rather than empty/zero. | S |
| VW-013 | Medium | Correctness/workflow | [apps/mobile/lib/features/guests_reservations/presentation/reservations_screen.dart:54-58,141-148](C:/Users/lwhob/OneDrive/Downloads/a0-project/apps/mobile/lib/features/guests_reservations/presentation/reservations_screen.dart:54) | Reservation assignment/status mutations have no exception handling or busy guard. | Offline, RLS denial or validation failures escape async menu callbacks with no visible recovery; rapid actions can race. | Await mutations in guarded stateful actions; preserve selection and show actionable error feedback. | S |
| VW-014 | Medium | Correctness/workflow | [apps/mobile/lib/features/employee/presentation/profile_screen.dart:190-244](C:/Users/lwhob/OneDrive/Downloads/a0-project/apps/mobile/lib/features/employee/presentation/profile_screen.dart:190)<br>[apps/mobile/lib/app/router.dart:130-178](C:/Users/lwhob/OneDrive/Downloads/a0-project/apps/mobile/lib/app/router.dart:130)<br>[apps/mobile/lib/features/settings/presentation/settings_screen.dart:120](C:/Users/lwhob/OneDrive/Downloads/a0-project/apps/mobile/lib/features/settings/presentation/settings_screen.dart:120) | Staff profile has no account-deletion action, while the employee route guard excludes the Settings screen containing it. | A staff user cannot reach the in-app account-deletion workflow from their assigned UI. | Expose the existing DeleteAccountButton in employee profile; preserve ownership checks on the server. | S |
| VW-015 | Medium | Correctness/workflow | [supabase/functions/account-deletion-worker/index.ts:74-102](C:/Users/lwhob/OneDrive/Downloads/a0-project/supabase/functions/account-deletion-worker/index.ts:74) | Worker ignores database errors when claiming and completing deletion jobs. | A failed claim still proceeds to Auth deletion; failed completion still returns ok. Concurrent dispatches also read the same attempt count, reducing retry accounting accuracy. | Use an atomic claim with lease and check each persistence result; only acknowledge durable completion. DB/function changes. | M |
| VW-016 | Medium | Correctness/workflow | [apps/mobile/lib/features/floor/application/floor_editor_controller.dart:301-307](C:/Users/lwhob/OneDrive/Downloads/a0-project/apps/mobile/lib/features/floor/application/floor_editor_controller.dart:301)<br>[apps/mobile/lib/features/floor/presentation/floor_plan_editor_screen.dart:265-269](C:/Users/lwhob/OneDrive/Downloads/a0-project/apps/mobile/lib/features/floor/presentation/floor_plan_editor_screen.dart:265) | Draft persistence failures are swallowed while the screen always says Draft saved. | Secure-storage failures leave no new draft, and the operator may close the editor believing work is preserved. | Return/throw persistence failures and show retry; guard post-await UI access with mounted. | S |
| VW-017 | Medium | Correctness/workflow | [apps/mobile/lib/features/incidents/presentation/incident_list_screen.dart:290-302,417-455](C:/Users/lwhob/OneDrive/Downloads/a0-project/apps/mobile/lib/features/incidents/presentation/incident_list_screen.dart:290)<br>[apps/mobile/lib/features/media/data/media_repository.dart:20-34](C:/Users/lwhob/OneDrive/Downloads/a0-project/apps/mobile/lib/features/media/data/media_repository.dart:20)<br>[apps/mobile/lib/features/incidents/README.md:25-29](C:/Users/lwhob/OneDrive/Downloads/a0-project/apps/mobile/lib/features/incidents/README.md:25) | Incident evidence can be uploaded but there is no app read/display path for its attachments. | After submission, operators cannot open the evidence from the incident list; the shared media repository exposes uploads only and there is no incident detail viewer. Photos become operationally inaccessible from the reviewed app. | Add a role-authorized incident detail/evidence query and short-lived signed URLs with loading/error states; test native and browser viewing. | M |
| VW-018 | Medium | Database/booking integrity | [apps/mobile/lib/features/guests_reservations/presentation/reservations_screen.dart:112-116,415-416,473-477](C:/Users/lwhob/OneDrive/Downloads/a0-project/apps/mobile/lib/features/guests_reservations/presentation/reservations_screen.dart:112)<br>[apps/mobile/lib/features/guests_reservations/data/guests_reservations_repository.dart:111-137](C:/Users/lwhob/OneDrive/Downloads/a0-project/apps/mobile/lib/features/guests_reservations/data/guests_reservations_repository.dart:111) | Reservation list spans many dates but shows only time-of-day, with no date filter or date headings. | Identical 7pm bookings months apart appear indistinguishable, making seating/cancellation of the wrong booking likely. | Show venue-local date headings and selected business-day navigation, with deliberate history access. | M |
| VW-019 | Medium | Database/booking integrity | [supabase/migrations/20261002235927_floor_schema.sql:77,302-350](C:/Users/lwhob/OneDrive/Downloads/a0-project/supabase/migrations/20261002235927_floor_schema.sql:77)<br>[supabase/migrations/20261002235847_guests_reservations_schema.sql:144](C:/Users/lwhob/OneDrive/Downloads/a0-project/supabase/migrations/20261002235847_guests_reservations_schema.sql:144) | Party sizes are positive but table-assignment capacity is never enforced. | A reservation larger than the sum of selected tables' capacity is accepted by the server. Needs verification: whether intentional manager overrides or standing events should be allowed. | Define seated-capacity policy, validate aggregate capacity in assignment RPC, and model explicit audited overrides if required. DB/app changes. | M |
| VW-020 | Medium | Database/booking integrity | [supabase/migrations/20261007202000_review_tenant_guards.sql:423-437](C:/Users/lwhob/OneDrive/Downloads/a0-project/supabase/migrations/20261007202000_review_tenant_guards.sql:423)<br>[supabase/migrations/20261002235847_guests_reservations_schema.sql:179-208](C:/Users/lwhob/OneDrive/Downloads/a0-project/supabase/migrations/20261002235847_guests_reservations_schema.sql:179) | BEO blocking-window conflict enforcement applies only when confirming or changing a BEO. | Once a BEO is confirmed, inserting/updating an ordinary reservation can overlap its four-hour blocking reservation because the reservation trigger does not check it. Venue_space is also absent from the conflict predicate. Needs verification: exclusivity by room versus whole venue. | Apply one shared resource/time-window rule in both write directions, with locking and intentional room scope; test reservation-before-BEO and BEO-before-reservation. DB changes. | M |
| VW-021 | Medium | Database/booking integrity | [supabase/migrations/20261002235847_guests_reservations_schema.sql:140,179-208](C:/Users/lwhob/OneDrive/Downloads/a0-project/supabase/migrations/20261002235847_guests_reservations_schema.sql:140)<br>[supabase/migrations/20261003005913_crm_schema.sql:42](C:/Users/lwhob/OneDrive/Downloads/a0-project/supabase/migrations/20261003005913_crm_schema.sql:42)<br>[supabase/migrations/20261007210000_fix_review_guard_record_fields.sql:65-84](C:/Users/lwhob/OneDrive/Downloads/a0-project/supabase/migrations/20261007210000_fix_review_guard_record_fields.sql:65) | Reservation and CRM lead guest references constrain only guest ID, not matching venue. | An authorized writer can attach a known guest ID from another venue to its own reservation/lead. Existing guards validate BEO/lead links but not guest links. This is cross-tenant relationship corruption, not a demonstrated ability to read another tenant's guest data. | Add same-venue guest-reference guards or composite FKs after checking existing mismatches; add insert/update isolation tests. DB changes. | M |
| VW-022 | Medium | Database/booking integrity | [supabase/migrations/20261004144042_remove_beo_deposit_and_stripe_connect.sql:38-65](C:/Users/lwhob/OneDrive/Downloads/a0-project/supabase/migrations/20261004144042_remove_beo_deposit_and_stripe_connect.sql:38)<br>[supabase/migrations/20261003005913_crm_schema.sql:509](C:/Users/lwhob/OneDrive/Downloads/a0-project/supabase/migrations/20261003005913_crm_schema.sql:509) | BEO-to-contract conversion checks for an existing contract without locking or unique live-contract constraint. | Two concurrent conversion calls can both see no contract and insert separate draft contracts for one BEO; unique venue contract number does not protect beo_id. Needs verification: whether multiple active contracts per BEO are ever intended. | Lock the BEO before lookup and add a partial unique index on non-cancelled beo_id if one active contract is the rule. DB changes. | M |
| VW-023 | Medium | Database/booking integrity | [supabase/migrations/20261006160946_staff_section_and_reservation_assignment.sql:7-11](C:/Users/lwhob/OneDrive/Downloads/a0-project/supabase/migrations/20261006160946_staff_section_and_reservation_assignment.sql:7)<br>[supabase/migrations/20261002175340_schedules_schema.sql:1-21](C:/Users/lwhob/OneDrive/Downloads/a0-project/supabase/migrations/20261002175340_schedules_schema.sql:1) | Staff assignment foreign keys point at auth users without verifying membership in the row's venue. | Authorized venue writers can assign reservations or shifts to unrelated accounts. The database enforces actor permission but not eligible assignee, so UI roster filtering can be bypassed. Live orphaned assignments were not inspected. | Validate same-venue or authorized organization membership on assignment inserts/updates, reconcile existing rows, and define removal/unassignment policy. DB changes. | M |
| VW-024 | Medium | Environment isolation | [apps/mobile/env/development.json:2](C:/Users/lwhob/OneDrive/Downloads/a0-project/apps/mobile/env/development.json:2)<br>[apps/mobile/env/production.json:2](C:/Users/lwhob/OneDrive/Downloads/a0-project/apps/mobile/env/production.json:2)<br>[apps/mobile/lib/main_development.dart:1-4](C:/Users/lwhob/OneDrive/Downloads/a0-project/apps/mobile/lib/main_development.dart:1) | Ignored local development and production configs point at the same Supabase origin. | A read-only comparison of SUPABASE_URL confirmed equality without printing keys. Developers using this development config can modify the same backend as production; actual live project designation remains unverified due connector permissions. | Create an isolated development project and validated non-production config; add a release/config check rejecting production origins for development. Configuration plus DB environment work. | M |
| VW-025 | Medium | Lifecycle/navigation | [apps/mobile/lib/features/insights/presentation/shift_insights_screen.dart:153-159,365-398](C:/Users/lwhob/OneDrive/Downloads/a0-project/apps/mobile/lib/features/insights/presentation/shift_insights_screen.dart:153)<br>[apps/mobile/lib/features/incidents/presentation/incident_list_screen.dart:155-157](C:/Users/lwhob/OneDrive/Downloads/a0-project/apps/mobile/lib/features/incidents/presentation/incident_list_screen.dart:155)<br>[apps/mobile/lib/features/documents/presentation/documents_screen.dart:157-164](C:/Users/lwhob/OneDrive/Downloads/a0-project/apps/mobile/lib/features/documents/presentation/documents_screen.dart:157)<br>[apps/mobile/lib/features/time_clock/presentation/time_clock_screen.dart:38-50,73-85,108-138,156-182](C:/Users/lwhob/OneDrive/Downloads/a0-project/apps/mobile/lib/features/time_clock/presentation/time_clock_screen.dart:38) | Async UI callbacks use ref/setState after dialog dismissal or navigation without mounted guards. | AI generation dialog is barrier-dismissible while in flight; a later failure calls setState after dispose, and success reads a disposed ref. Incident annotator return also updates a dismissed dialog. Document upload completion also invalidates a WidgetRef after navigation without checking context.mounted. | AI generation dialog is barrier-dismissible while in flight; a later failure calls setState after dispose, and success reads a disposed ref. Incident annotator return also updates a dismissed dialog. Document upload completion invalidates a WidgetRef after navigation. Clock-in/out/break completions call _refresh after navigation, which invalidates a disposed WidgetRef; Start Break also calls setState after its dialog returns without checking mounted. | S |
| VW-026 | Medium | Lifecycle/navigation | [apps/mobile/lib/app/router.dart:50-69](C:/Users/lwhob/OneDrive/Downloads/a0-project/apps/mobile/lib/app/router.dart:50)<br>[apps/mobile/lib/features/employee/presentation/employee_home_screen.dart:59-63](C:/Users/lwhob/OneDrive/Downloads/a0-project/apps/mobile/lib/features/employee/presentation/employee_home_screen.dart:59) | Riverpod recreates GoRouter and its navigator key on role/venue changes without disposing previous routers. | Refreshing the role provider creates fresh navigation infrastructure; old GoRouter listeners/delegates have no provider cleanup. Exact history/draft disruption needs a navigation lifecycle test. | Keep routing infrastructure stable with explicit auth/role refresh notifications, and register router disposal; test role refresh while editing and venue switches. | M |
| VW-027 | Medium | Performance | [apps/mobile/lib/features/guests_reservations/data/guests_reservations_repository.dart:111-137](C:/Users/lwhob/OneDrive/Downloads/a0-project/apps/mobile/lib/features/guests_reservations/data/guests_reservations_repository.dart:111)<br>[apps/mobile/lib/features/guests_reservations/presentation/reservations_screen.dart:104-117](C:/Users/lwhob/OneDrive/Downloads/a0-project/apps/mobile/lib/features/guests_reservations/presentation/reservations_screen.dart:104) | Default reservation loading fetches the entire 395-day window before returning. | The pageSize=500 loop has no total cap or incremental UI; busy venues require many sequential requests and retain a large list before any reservation appears. Actual latency/memory cost needs profiling. | Default to a selected venue business day/week and fetch further pages on demand; coordinate with the date-heading/timezone fixes. | M |
| VW-028 | Medium | Platform/build | [apps/mobile/lib/core/security/app_attest_service.dart:54-70](C:/Users/lwhob/OneDrive/Downloads/a0-project/apps/mobile/lib/core/security/app_attest_service.dart:54) | Android Play Integrity client acquisition/submission is absent. | Server-side Android verification exists but the Flutter service always returns unsupported outside iOS. Needs verification: whether attestation is required for Android release. | Implement and test Android challenge/token flow against the existing server verifier. | L |
| VW-029 | Medium | Platform/build | [apps/mobile/lib/features/incidents/presentation/incident_list_screen.dart:143-144](C:/Users/lwhob/OneDrive/Downloads/a0-project/apps/mobile/lib/features/incidents/presentation/incident_list_screen.dart:143)<br>[apps/mobile/lib/features/media/presentation/photo_annotation_screen.dart:68-69,196-201](C:/Users/lwhob/OneDrive/Downloads/a0-project/apps/mobile/lib/features/media/presentation/photo_annotation_screen.dart:68) | Needs verification: incident photo evidence is deliberately disabled on Flutter web. | The camera/attachment action is hidden for web, while annotation/upload use native File APIs. Web users cannot add evidence; confirm whether this capability gap is intended. | If browser evidence is required, add XFile/byte picking, browser export and uploadBinary; otherwise make the platform limitation visible. | M |
| VW-030 | Medium | Platform/build | [site/.well-known/assetlinks.json:7-9](C:/Users/lwhob/OneDrive/Downloads/a0-project/site/.well-known/assetlinks.json:7)<br>[site/.well-known/assetlinks.json.NEEDS_REAL_FINGERPRINT.md:3-10](C:/Users/lwhob/OneDrive/Downloads/a0-project/site/.well-known/assetlinks.json.NEEDS_REAL_FINGERPRINT.md:3) | Needs verification: Android App Links publish only the upload-key fingerprint. | Repository notes identify this as an upload certificate. A Google Play build re-signed by Play requires its app-signing certificate; otherwise verified links can open the browser instead of the app. Play release/signing state was not accessed. | Obtain the authoritative Play app-signing SHA-256 and add it alongside approved certificates; verify on a Play-delivered device. | S |
| VW-031 | Medium | Privacy/data handling | [apps/mobile/lib/core/auth/sign_out_service.dart:12-31](C:/Users/lwhob/OneDrive/Downloads/a0-project/apps/mobile/lib/core/auth/sign_out_service.dart:12) | Offline sign-out discards the remembered push token even when server unregistration fails. | The server can continue sending the prior user's pushes to a shared device; a new user at another venue does not disable the old venue registration. | Persist a pending revocation and bind notification delivery to the current device session; test offline sign-out and cross-venue account switch. DB/API change. | M |
| VW-032 | Medium | Privacy/data handling | [apps/mobile/lib/features/incidents/presentation/incident_list_screen.dart:38-43](C:/Users/lwhob/OneDrive/Downloads/a0-project/apps/mobile/lib/features/incidents/presentation/incident_list_screen.dart:38) | Offline incident draft titles are rendered without filtering to the active venue or actor. | Switching venues exposes another venue's cached incident titles in the current list; cross-user exposure needs verification against sign-out clearing. | Filter by mutation userId and venueId and isolate cached presentation state per authenticated scope. | S |
| VW-033 | Medium | Privacy/data handling | [supabase/functions/_shared/observability.ts:70-77,88-96](C:/Users/lwhob/OneDrive/Downloads/a0-project/supabase/functions/_shared/observability.ts:70)<br>[supabase/functions/square-oauth/index.ts:60-62](C:/Users/lwhob/OneDrive/Downloads/a0-project/supabase/functions/square-oauth/index.ts:60) | Exception context sends raw OAuth callback URLs to Sentry extras. | Callbacks pass req.url containing code/state to captureException; scrubber handles event.request but leaves event.extra.url intact. Unexpected callback errors can disclose authentication artifacts to telemetry. | Redact URLs before adding extras; remove code/state and scrub error payloads in one tested sanitizer. | S |
| VW-034 | Medium | Privacy/data handling | [supabase/functions/ai-assistant/index.ts:247-253](C:/Users/lwhob/OneDrive/Downloads/a0-project/supabase/functions/ai-assistant/index.ts:247) | Malformed AI responses are written in full to Edge console logs. | AI-generated content can repeat guest contact details or incident narratives included in prompts; invalid JSON logs those contents outside the application's data-access and deletion paths. Actual retained production content needs verification. | Log correlation ID, parsing error and bounded metadata only; redact provider errors and review existing log retention. | S |
| VW-035 | Medium | Privacy/data handling | [site/privacy/index.html:37-38](C:/Users/lwhob/OneDrive/Downloads/a0-project/site/privacy/index.html:37)<br>[supabase/functions/_shared/groq.ts:5,35-55](C:/Users/lwhob/OneDrive/Downloads/a0-project/supabase/functions/_shared/groq.ts:5)<br>[supabase/functions/ai-assistant/index.ts:227-240](C:/Users/lwhob/OneDrive/Downloads/a0-project/supabase/functions/ai-assistant/index.ts:227) | Published service-provider disclosure omits Groq although AI prompts are sent to Groq. | The reviewed processor description names Gemini but not the actual callGroqJson data path. Users and operators do not receive an accurate description of where AI task inputs are processed. Deployed page/provider usage needs verification. | Align the published processor/data-flow description with actual enabled AI features and authoritative vendor arrangements; review generated-content logging separately. | S |
| VW-036 | Medium | Security/authorization | [apps/mobile/lib/core/offline/offline_queue_store.dart:20-77](C:/Users/lwhob/OneDrive/Downloads/a0-project/apps/mobile/lib/core/offline/offline_queue_store.dart:20)<br>[apps/mobile/lib/core/offline/offline_queue_providers.dart:10-14](C:/Users/lwhob/OneDrive/Downloads/a0-project/apps/mobile/lib/core/offline/offline_queue_providers.dart:10) | Native offline queue stores incident narratives and other pending payloads as plaintext JSON. | Sensitive unsynced data remains in application support and .bak files without the secure-storage protection used for sessions. | Encrypt native queue storage and retire/recover plaintext backups. | M |
| VW-037 | Medium | Security/authorization | [supabase/functions/_shared/cbor.ts:25-46,51-82,108-110](C:/Users/lwhob/OneDrive/Downloads/a0-project/supabase/functions/_shared/cbor.ts:25)<br>[supabase/functions/_shared/der.ts:42-71](C:/Users/lwhob/OneDrive/Downloads/a0-project/supabase/functions/_shared/der.ts:42) | Attestation parsers accept truncated input and unchecked declared lengths; DER arithmetic can yield a node that does not advance. | A bounded, read-only Node probe decoded [0x83] as [0,0,0] and DER [0x30,0x84,0xff,0xff,0xff,0xfa] produced end=0 at start=0. parseDerChildren then cannot advance; large CBOR array lengths exhaust CPU/memory. End-to-end Edge-runtime resource impact needs verification. | Reject out-of-bounds headers/content, cap container sizes/depth, avoid signed bitwise length accumulation, require cursor progress and complete input; add malformed-input tests. | M |
| VW-038 | Medium | Security/authorization | [supabase/functions/device-attestation/index.ts:52-71,149-164,298-311](C:/Users/lwhob/OneDrive/Downloads/a0-project/supabase/functions/device-attestation/index.ts:52) | iOS attestation accepts untracked challenges when challenge storage or consumption fails. | DB failures return not_found, which passes through iOS verification instead of enforcing one-time use. This weakens replay assurance; observe mode is advisory and this is not demonstrated authentication bypass. | Require durable challenge issuance and consumed result for a verified verdict; report infrastructure failures separately. Test failed issue/consume and replay. | M |
| VW-039 | Medium | UI/accessibility | [apps/mobile/lib/features/media/presentation/photo_annotation_screen.dart:380-421](C:/Users/lwhob/OneDrive/Downloads/a0-project/apps/mobile/lib/features/media/presentation/photo_annotation_screen.dart:380) | Annotation toolbar places six 44px colour cells plus stroke buttons and padding in one non-scrolling Row. | Minimum width exceeds a typical 390px phone; controls overflow/clipped, further increased by text scaling. All colours have identical semantic label. | Wrap or horizontally scroll both groups, use labelled 48px controls; add narrow-phone/text-scale verification. | S |
| VW-040 | Low | Documentation/product | [site/billing/index.html:23-30](C:/Users/lwhob/OneDrive/Downloads/a0-project/site/billing/index.html:23)<br>[supabase/migrations/20261004144042_remove_beo_deposit_and_stripe_connect.sql:1-9](C:/Users/lwhob/OneDrive/Downloads/a0-project/supabase/migrations/20261004144042_remove_beo_deposit_and_stripe_connect.sql:1) | Public billing fallback still instructs users to configure Stripe Connect and collect event deposits. | Old or manually supplied query parameters display instructions for features explicitly removed from this subscription-only product. | Remove retired connect/deposit branches and verify subscription return/cancel messaging. | S |
| VW-041 | Low | Documentation/product | [packages/marketing/src/App.tsx:20-25](C:/Users/lwhob/OneDrive/Downloads/a0-project/packages/marketing/src/App.tsx:20)<br>[apps/mobile/lib/features/inventory/presentation/inventory_import_screen.dart:45-83](C:/Users/lwhob/OneDrive/Downloads/a0-project/apps/mobile/lib/features/inventory/presentation/inventory_import_screen.dart:45)<br>[public/sales-deck.html:565-568](C:/Users/lwhob/OneDrive/Downloads/a0-project/public/sales-deck.html:565) | Marketing advertises camera-assisted bottle counts and barcode capture, but the active Flutter inventory workflow exposes text-based invoice/count-sheet review. | Prospects are promised capture features absent from the reviewed app. Needs verification: whether these statements refer to another currently supported released app. | Align copy to supported Flutter capabilities or separately scope and validate the promised capture workflow. | S |
| VW-042 | Low | Documentation/product | [docs/production-operations.md:5-24,51-55,68-74,94](C:/Users/lwhob/OneDrive/Downloads/a0-project/docs/production-operations.md:5)<br>[docs/integrations/pos-webhook.md:3-13](C:/Users/lwhob/OneDrive/Downloads/a0-project/docs/integrations/pos-webhook.md:3)<br>[CLAUDE.md:1-11](C:/Users/lwhob/OneDrive/Downloads/a0-project/CLAUDE.md:1)<br>[apps/mobile/README.md:19-23](C:/Users/lwhob/OneDrive/Downloads/a0-project/apps/mobile/README.md:19)<br>[packages/marketing/README.md:7-11](C:/Users/lwhob/OneDrive/Downloads/a0-project/packages/marketing/README.md:7) | Active operations/integration guides mix retired Cloud Run/Expo API instructions with the Flutter/Supabase deployment. App README still says web queue persistence is absent, although a browser secure-storage queue is implemented. | Release checklist names absent deploy-api.yml and API CI, while POS guide names retired /api/v1 endpoints. Operators can follow the wrong health, deployment, scanner or webhook procedure; historical notes elsewhere are not substitutes for a current runbook. | Rewrite the current runbook around Supabase functions/cron and Flutter release paths; mark retained legacy procedures explicitly and verify authoritative live settings. | M |
| VW-043 | Low | Maintainability/dependencies | [apps/mobile/lib/features/documents/application/documents_providers.dart:8-10](C:/Users/lwhob/OneDrive/Downloads/a0-project/apps/mobile/lib/features/documents/application/documents_providers.dart:8) | Documents repository uses Supabase.instance instead of the shared client provider. | Composition-root overrides are bypassed, complicating tests and future alternate-client configuration. | Inject supabaseClientProvider consistently. | S |
| VW-044 | Low | Maintainability/dependencies | [apps/mobile/lib/features/documents/presentation/documents_screen.dart:95-169](C:/Users/lwhob/OneDrive/Downloads/a0-project/apps/mobile/lib/features/documents/presentation/documents_screen.dart:95) | Per-upload TextEditingController is never disposed, including cancellation and success paths. | Repeated document uploads retain controller/listener resources. | Capture title and dispose controller in finally; ensure post-upload invalidation only while mounted. | S |
| VW-045 | Low | Maintainability/dependencies | [apps/mobile/pubspec.lock:337-344,579-586](C:/Users/lwhob/OneDrive/Downloads/a0-project/apps/mobile/pubspec.lock:337)<br>[apps/mobile/pubspec.yaml:25-26](C:/Users/lwhob/OneDrive/Downloads/a0-project/apps/mobile/pubspec.yaml:25) | Locked dependency graph includes two transitive packages reported discontinued by flutter pub outdated. | flutter_secure_storage_macos and js increase maintenance risk; no vulnerability or current runtime failure is demonstrated. | Plan a tested secure-storage/platform dependency update, preserving migrated credentials; review web/native compatibility before selecting versions. | M |
| VW-046 | Low | Performance | [apps/mobile/lib/features/time_clock/presentation/time_clock_screen.dart:24-35](C:/Users/lwhob/OneDrive/Downloads/a0-project/apps/mobile/lib/features/time_clock/presentation/time_clock_screen.dart:24) | One-second ticker rebuilds the whole time-clock screen even when clocked out or viewing Clock Board. | Unnecessary rebuilds continue throughout this screen's lifetime. Actual CPU/battery cost needs device profiling; timer itself is correctly cancelled. | Move elapsed-time ticking into a small leaf widget and run only for an active punch. | S |
| VW-047 | Low | UI/accessibility | [public/sales-deck.html:823-855,901-918](C:/Users/lwhob/OneDrive/Downloads/a0-project/public/sales-deck.html:823) | Sales-deck ROI calculator ignores its staff-size slider and labels gross assumed savings as net savings. | Staff size changes only its displayed label. Total is covers times a fixed fee plus fixed software savings, without subtracting Venue Wrangler subscription cost; changing staff size leaves results unchanged. | Use stated, editable assumptions and a real staff-dependent calculation; subtract selected plan cost or label the output gross illustrative savings. | S |

Supabase's supported deletion behavior is relevant to VW-005: deleting from Storage's SQL metadata does not delete the underlying object bytes. See the official [Storage deletion guide](https://supabase.com/docs/guides/storage/management/delete-objects) and [Storage schema design guidance](https://supabase.com/docs/guides/storage/schema/design). The existing cleanup SQL is therefore insufficient even when its metadata statements succeed.

## 4. Proposed fix order and dependencies

Nothing in this sequence authorizes implementation. Approve the finding IDs you want addressed.

1. **Close service-role authorization/privacy paths first:** VW-007 OAuth callback membership/role recheck, single-use provider-bound state; VW-006 push eligibility after membership removal. **Database/function changes** for durable OAuth state and registration invalidation; delivery authorization belongs in the shared helper. Follow with VW-033 URL telemetry redaction and VW-031 durable sign-out token revocation. Coordinate revocation with shared-device account switches.
2. **Protect existing operational data:** VW-004 persist conflicts, VW-002 revision-aware floor drafts/publish and VW-016 truthful draft-save results. **DB migration required for floor base revision/concurrency checks; local queue migration required for conflict persistence.** Design recovery before retiring existing stored drafts/queue files.
3. **Repair file/account cleanup:** VW-005 use Storage API removal for actual bytes, VW-015 atomic deletion-job claims/completion and VW-014 employee deletion access. **DB/function changes** and durable retries come before exposing stronger deletion promises. Verify leftover byte cleanup and account-deletion behavior for final owners.
4. **Choose booking resource policies, then migrate invariants:** VW-003 overlap exclusion, VW-019 capacity, VW-020 symmetric BEO/resource blocking, VW-021 same-venue guest links, VW-022 one-active-contract concurrency and VW-023 eligible staff assignments. **DB changes needed.** Read-only preflight reports must identify existing overlaps, cross-venue links and duplicate contracts before constraints are added. Decide rooms, merged-table capacity and audited manager overrides first.
5. **Unify venue time and reservation browsing:** VW-001 carry IANA venue timezone through domain/date calculations, then VW-018 dates/business-day navigation and VW-027 bounded/lazy fetching. Usually **app changes**, with any DB reporting/day-window RPC adjusted consistently. Test DST gaps/folds and managers outside the venue timezone; do not silently reinterpret existing timestamps.
6. **Make accounting durable:** VW-008 atomic/idempotent AI spend commit and VW-009 one pending org Checkout Session. **DB/function changes needed.** Verify Stripe/provider behavior and live configuration separately; Stripe remains subscription-only. VW-034 logs and VW-035 processor disclosure follow the actual AI data path.
7. **Correct app state and lifecycle feedback:** VW-010 venue/record-aware push routing; VW-011 zero-row mutation errors; VW-012 visible fetch errors; VW-013 guarded reservation actions; VW-025 mounted/lifetime checks; VW-026 stable/disposed router; VW-032 scoped incident drafts; VW-017 readable incident evidence. Primarily **app/repository changes**; push payload and evidence queries must preserve server authorization.
8. **Platform/security/UI follow-up:** VW-036 encrypt native queue/backups; VW-037 bound parsers; VW-038 require durable consumed challenges. Confirm release scope before VW-028 Android integrity, VW-029 web photo capture and VW-030 Play signing App Links. Fix VW-039 phone/text-scale toolbar.
9. **Maintenance/content:** VW-040–VW-045 and VW-047; profile VW-046 before wider performance work. Dependency changes require separate compatibility checks and secure-storage migration tests. Update current docs/copy while preserving original app/store identity.

After selected fixes, appropriate tests should accompany the actual changes. SQL regression suites need an explicitly authorized isolated database; a live read-only re-audit should establish deployment parity before release. Native/browser/device and provider acceptance checks remain separate from unit-test success.

## 5. Open questions

1. Can read-only connector access be granted for the **intended** Supabase project `puttwjwmwrzmhpsjykuj`? Until then, which migration/cron/backup deployment evidence is authoritative, particularly `20261007210000` and `20261010120000`? This audit will not inspect another tenant/project as a substitute.
2. Are confirmed BEOs exclusive by **room/venue_space** or by whole venue? What duration should block the resource? Are over-capacity/overlap overrides allowed, and who may perform them? What capacity should merged tables contribute?
3. Is one active contract per BEO the intended rule? What should happen to future reservation/shift assignments when a staff membership is removed or their account is deleted?
4. Should Reservations default to a venue-local business day, upcoming week or another window? What defines the business-day cutoff, and how should historical reservations be accessed?
5. Which current release surfaces are supported: iOS, Android and browser? Is browser photo capture required? Is Android blocked on Play Integrity, and is Play App Signing enabled? The certificate must come from the authoritative signing settings.
6. Should App Attest remain advisory until physical-device validation? Which sensitive operations, if any, are intended to require attestation? A mode setting alone does not enforce authorization at every Supabase/API entrypoint.
7. What is the approved shared-device/offline conflict policy: retained encrypted drafts after logout, immediate local clearing, and pending push revocation? How should a user recover or explicitly discard a conflict?
8. Are public App Store/Apple-IAP support instructions for a still-supported legacy release, or should public documentation describe only this subscription-status Flutter build? Likewise, do camera/barcode/vision and POS claims refer to another supported product? Do not update public claims without confirming that release boundary.
9. Which AI processors are enabled in production and what data/retention arrangements apply? The source uses Groq. Existing telemetry/log contents, published policy and actual deployed provider settings are unverified.
10. Are APNs/FCM, OAuth callback origins/scopes, ClamAV, deletion dispatch/Vault entries and live Stripe webhook configuration provisioned and tested? Supply authoritative configuration evidence or status; do not paste private credential values.
11. Are ignored local private-key/signing/env files intentionally retained in this OneDrive workspace, and what access/backup controls protect them? Presence and ignore rules do not prove leakage or credential validity. The concurrent draft's printed values were redacted from this deliverable; rotation decisions require exposure evidence and the credential owner's approval.
12. Should the inventoried legacy/dormant schema and historical/governance docs be retained, archived or brought into a separately scoped operational/compliance review? Live dependencies must be checked before removal.
13. Should cron registration failures be surfaced as release failures rather than swallowed for fixture compatibility? Source schedules are conditional and some exception handlers intentionally suppress errors; actual scheduled cleanup/dispatch and successful run history need live verification.

## Appendix A. Full source/config/assets tree

Excluded: `.git/`, `node_modules/`, `build/`, `.dart_tool/`, `ios/Pods/`, `android/.gradle/`, plugin/tool caches, generated Flutter/native output, temporary exports, ignored screenshots/builds, private credential material and agent/tool work directories. Checked-in generated site outputs remain listed with G so their exclusion is visible. This tree is the 626-file audited snapshot; the new audit report is listed separately as the deliverable.

```text
a0-project/
├── .freebuff/
│   └── [I] project-id
├── .github/
│   ├── workflows/
│   │   ├── [R] codeql.yml
│   │   ├── [R] deploy-cloudflare-pages.yml
│   │   ├── [R] flutter-ci.yml
│   │   ├── [R] prowler-compliance.yml
│   │   ├── [R] supabase-ci.yml
│   │   ├── [R] supabase-database-backup.yml
│   │   └── [R] supabase-storage-backup.yml
│   └── [R] dependabot.yml
├── apps/
│   └── mobile/
│       ├── android/
│       │   ├── app/
│       │   │   ├── src/
│       │   │   │   ├── debug/
│       │   │   │   │   └── [R] AndroidManifest.xml
│       │   │   │   ├── main/
│       │   │   │   │   ├── kotlin/
│       │   │   │   │   │   └── com/
│       │   │   │   │   │       └── venuewrangler/
│       │   │   │   │   │           └── app/
│       │   │   │   │   │               └── [R] MainActivity.kt
│       │   │   │   │   ├── res/
│       │   │   │   │   │   ├── drawable/
│       │   │   │   │   │   │   └── [R] launch_background.xml
│       │   │   │   │   │   ├── drawable-v21/
│       │   │   │   │   │   │   └── [R] launch_background.xml
│       │   │   │   │   │   ├── mipmap-hdpi/
│       │   │   │   │   │   │   └── [B] ic_launcher.png
│       │   │   │   │   │   ├── mipmap-mdpi/
│       │   │   │   │   │   │   └── [B] ic_launcher.png
│       │   │   │   │   │   ├── mipmap-xhdpi/
│       │   │   │   │   │   │   └── [B] ic_launcher.png
│       │   │   │   │   │   ├── mipmap-xxhdpi/
│       │   │   │   │   │   │   └── [B] ic_launcher.png
│       │   │   │   │   │   ├── mipmap-xxxhdpi/
│       │   │   │   │   │   │   └── [B] ic_launcher.png
│       │   │   │   │   │   ├── values/
│       │   │   │   │   │   │   └── [R] styles.xml
│       │   │   │   │   │   └── values-night/
│       │   │   │   │   │       └── [R] styles.xml
│       │   │   │   │   └── [R] AndroidManifest.xml
│       │   │   │   └── profile/
│       │   │   │       └── [R] AndroidManifest.xml
│       │   │   ├── [R] build.gradle.kts
│       │   │   └── [R] google-services.json
│       │   ├── gradle/
│       │   │   └── wrapper/
│       │   │       └── [R] gradle-wrapper.properties
│       │   ├── [R] .gitignore
│       │   ├── [R] build.gradle.kts
│       │   ├── [R] gradle.properties
│       │   └── [R] settings.gradle.kts
│       ├── assets/
│       │   └── video/
│       │       └── [B] intro.mp4
│       ├── env/
│       │   ├── [R] development.json.example
│       │   ├── [R] production.json.example
│       │   └── [R] staging.json.example
│       ├── integration_test/
│       │   └── [R] README.md
│       ├── ios/
│       │   ├── Flutter/
│       │   │   ├── [R] AppFrameworkInfo.plist
│       │   │   ├── [R] Debug.xcconfig
│       │   │   └── [R] Release.xcconfig
│       │   ├── Runner/
│       │   │   ├── Assets.xcassets/
│       │   │   │   ├── AppIcon.appiconset/
│       │   │   │   │   ├── [R] Contents.json
│       │   │   │   │   ├── [B] Icon-App-1024x1024@1x.png
│       │   │   │   │   ├── [B] Icon-App-20x20@1x.png
│       │   │   │   │   ├── [B] Icon-App-20x20@2x.png
│       │   │   │   │   ├── [B] Icon-App-20x20@3x.png
│       │   │   │   │   ├── [B] Icon-App-29x29@1x.png
│       │   │   │   │   ├── [B] Icon-App-29x29@2x.png
│       │   │   │   │   ├── [B] Icon-App-29x29@3x.png
│       │   │   │   │   ├── [B] Icon-App-40x40@1x.png
│       │   │   │   │   ├── [B] Icon-App-40x40@2x.png
│       │   │   │   │   ├── [B] Icon-App-40x40@3x.png
│       │   │   │   │   ├── [B] Icon-App-60x60@2x.png
│       │   │   │   │   ├── [B] Icon-App-60x60@3x.png
│       │   │   │   │   ├── [B] Icon-App-76x76@1x.png
│       │   │   │   │   ├── [B] Icon-App-76x76@2x.png
│       │   │   │   │   └── [B] Icon-App-83.5x83.5@2x.png
│       │   │   │   └── LaunchImage.imageset/
│       │   │   │       ├── [R] Contents.json
│       │   │   │       ├── [B] LaunchImage.png
│       │   │   │       ├── [B] LaunchImage@2x.png
│       │   │   │       ├── [B] LaunchImage@3x.png
│       │   │   │       └── [R] README.md
│       │   │   ├── Base.lproj/
│       │   │   │   ├── [R] LaunchScreen.storyboard
│       │   │   │   └── [R] Main.storyboard
│       │   │   ├── [R] AppAttestPlugin.swift
│       │   │   ├── [R] AppDelegate.swift
│       │   │   ├── [R] Info.plist
│       │   │   ├── [R] PushNotificationsPlugin.swift
│       │   │   ├── [R] Runner-Bridging-Header.h
│       │   │   ├── [R] Runner.entitlements
│       │   │   ├── [R] RunnerRelease.entitlements
│       │   │   └── [R] SceneDelegate.swift
│       │   ├── Runner.xcodeproj/
│       │   │   ├── project.xcworkspace/
│       │   │   │   ├── xcshareddata/
│       │   │   │   │   ├── [R] IDEWorkspaceChecks.plist
│       │   │   │   │   └── [R] WorkspaceSettings.xcsettings
│       │   │   │   └── [R] contents.xcworkspacedata
│       │   │   ├── xcshareddata/
│       │   │   │   └── xcschemes/
│       │   │   │       └── [R] Runner.xcscheme
│       │   │   └── [R] project.pbxproj
│       │   ├── Runner.xcworkspace/
│       │   │   ├── xcshareddata/
│       │   │   │   ├── [R] IDEWorkspaceChecks.plist
│       │   │   │   └── [R] WorkspaceSettings.xcsettings
│       │   │   └── [R] contents.xcworkspacedata
│       │   ├── RunnerTests/
│       │   │   └── [R] RunnerTests.swift
│       │   └── [R] .gitignore
│       ├── lib/
│       │   ├── app/
│       │   │   ├── [R] app_shell.dart
│       │   │   ├── [R] app.dart
│       │   │   ├── [R] bootstrap.dart
│       │   │   ├── [R] intro_video_screen.dart
│       │   │   └── [R] router.dart
│       │   ├── core/
│       │   │   ├── auth/
│       │   │   │   ├── [R] auth_providers.dart
│       │   │   │   ├── [R] auth_repository.dart
│       │   │   │   └── [R] sign_out_service.dart
│       │   │   ├── config/
│       │   │   │   ├── [R] env_config.dart
│       │   │   │   └── [R] flavor.dart
│       │   │   ├── errors/
│       │   │   │   ├── [R] app_error.dart
│       │   │   │   └── [R] error_reporter.dart
│       │   │   ├── location/
│       │   │   │   └── [R] location_service.dart
│       │   │   ├── network/
│       │   │   │   └── [R] supabase_providers.dart
│       │   │   ├── offline/
│       │   │   │   ├── [R] offline_queue_connectivity.dart
│       │   │   │   ├── [R] offline_queue_controller.dart
│       │   │   │   ├── [R] offline_queue_providers.dart
│       │   │   │   ├── [R] offline_queue_store.dart
│       │   │   │   ├── [R] pending_mutation.dart
│       │   │   │   └── [R] README.md
│       │   │   ├── security/
│       │   │   │   ├── [R] app_attest_providers.dart
│       │   │   │   ├── [R] app_attest_service.dart
│       │   │   │   └── [R] README.md
│       │   │   ├── storage/
│       │   │   │   ├── [R] secure_local_storage.dart
│       │   │   │   └── [R] secure_session_storage.dart
│       │   │   ├── theme/
│       │   │   │   ├── [R] app_colors.dart
│       │   │   │   ├── [R] app_theme.dart
│       │   │   │   ├── [R] ops_colors.dart
│       │   │   │   └── [R] theme_mode_provider.dart
│       │   │   └── widgets/
│       │   │       ├── [R] blueprint_grid.dart
│       │   │       ├── [R] ops_panel.dart
│       │   │       ├── [R] state_views.dart
│       │   │       └── [R] status_chip.dart
│       │   ├── features/
│       │   │   ├── ai/
│       │   │   │   ├── application/
│       │   │   │   │   └── [R] ai_providers.dart
│       │   │   │   ├── data/
│       │   │   │   │   └── [R] ai_repository.dart
│       │   │   │   ├── domain/
│       │   │   │   │   └── [R] ai_models.dart
│       │   │   │   ├── presentation/
│       │   │   │   │   └── [R] wrangler_assistant_screen.dart
│       │   │   │   └── [R] README.md
│       │   │   ├── auth/
│       │   │   │   ├── [R] reset_password_screen.dart
│       │   │   │   ├── [R] sign_in_screen.dart
│       │   │   │   └── [R] sign_up_screen.dart
│       │   │   ├── billing/
│       │   │   │   ├── application/
│       │   │   │   │   └── [R] billing_providers.dart
│       │   │   │   ├── data/
│       │   │   │   │   └── [R] billing_repository.dart
│       │   │   │   ├── domain/
│       │   │   │   │   └── [R] subscription.dart
│       │   │   │   ├── presentation/
│       │   │   │   │   └── [R] billing_screen.dart
│       │   │   │   └── [R] README.md
│       │   │   ├── chat/
│       │   │   │   ├── application/
│       │   │   │   │   └── [R] chat_providers.dart
│       │   │   │   ├── data/
│       │   │   │   │   └── [R] chat_repository.dart
│       │   │   │   ├── domain/
│       │   │   │   │   ├── [R] chat_message.dart
│       │   │   │   │   └── [R] conversation.dart
│       │   │   │   ├── presentation/
│       │   │   │   │   └── [R] chat_screen.dart
│       │   │   │   └── [R] README.md
│       │   │   ├── checklists/
│       │   │   │   ├── application/
│       │   │   │   │   └── [R] checklists_providers.dart
│       │   │   │   ├── data/
│       │   │   │   │   └── [R] checklists_repository.dart
│       │   │   │   ├── domain/
│       │   │   │   │   ├── [R] checklist_template.dart
│       │   │   │   │   └── [R] item_result.dart
│       │   │   │   ├── presentation/
│       │   │   │   │   ├── [R] checklist_completion_screen.dart
│       │   │   │   │   └── [R] checklist_list_screen.dart
│       │   │   │   └── [R] README.md
│       │   │   ├── crm/
│       │   │   │   ├── application/
│       │   │   │   │   └── [R] crm_providers.dart
│       │   │   │   ├── data/
│       │   │   │   │   └── [R] crm_repository.dart
│       │   │   │   ├── domain/
│       │   │   │   │   ├── [R] crm_beo_charge.dart
│       │   │   │   │   ├── [R] crm_beo.dart
│       │   │   │   │   ├── [R] crm_contract.dart
│       │   │   │   │   └── [R] crm_lead.dart
│       │   │   │   ├── presentation/
│       │   │   │   │   ├── [R] crm_beo_detail_screen.dart
│       │   │   │   │   ├── [R] crm_lead_detail_screen.dart
│       │   │   │   │   └── [R] crm_screen.dart
│       │   │   │   └── [R] README.md
│       │   │   ├── dashboard/
│       │   │   │   ├── presentation/
│       │   │   │   │   ├── [R] dashboard_screen.dart
│       │   │   │   │   └── [R] more_screen.dart
│       │   │   │   └── [R] README.md
│       │   │   ├── documents/
│       │   │   │   ├── application/
│       │   │   │   │   ├── [R] document_picker_service.dart
│       │   │   │   │   └── [R] documents_providers.dart
│       │   │   │   ├── data/
│       │   │   │   │   └── [R] documents_repository.dart
│       │   │   │   ├── domain/
│       │   │   │   │   └── [R] venue_document.dart
│       │   │   │   ├── presentation/
│       │   │   │   │   └── [R] documents_screen.dart
│       │   │   │   └── [R] README.md
│       │   │   ├── employee/
│       │   │   │   ├── application/
│       │   │   │   │   └── [R] employee_providers.dart
│       │   │   │   ├── domain/
│       │   │   │   │   └── [R] employee_day.dart
│       │   │   │   └── presentation/
│       │   │   │       ├── [R] employee_home_screen.dart
│       │   │   │       └── [R] profile_screen.dart
│       │   │   ├── events/
│       │   │   │   ├── application/
│       │   │   │   │   └── [R] events_providers.dart
│       │   │   │   ├── data/
│       │   │   │   │   └── [R] events_repository.dart
│       │   │   │   ├── domain/
│       │   │   │   │   └── [R] event.dart
│       │   │   │   ├── presentation/
│       │   │   │   │   └── [R] event_list_screen.dart
│       │   │   │   └── [R] README.md
│       │   │   ├── floor/
│       │   │   │   ├── application/
│       │   │   │   │   ├── [R] floor_editor_controller.dart
│       │   │   │   │   └── [R] floor_providers.dart
│       │   │   │   ├── data/
│       │   │   │   │   └── [R] floor_repository.dart
│       │   │   │   ├── domain/
│       │   │   │   │   ├── [R] editor_table.dart
│       │   │   │   │   ├── [R] floor_plan.dart
│       │   │   │   │   ├── [R] floor_table.dart
│       │   │   │   │   └── [R] table_status_style.dart
│       │   │   │   ├── presentation/
│       │   │   │   │   ├── [R] floor_plan_editor_screen.dart
│       │   │   │   │   ├── [R] floor_plan_screen.dart
│       │   │   │   │   └── [R] live_floor_map.dart
│       │   │   │   └── [R] README.md
│       │   │   ├── guests_reservations/
│       │   │   │   ├── application/
│       │   │   │   │   └── [R] guests_reservations_providers.dart
│       │   │   │   ├── data/
│       │   │   │   │   └── [R] guests_reservations_repository.dart
│       │   │   │   ├── domain/
│       │   │   │   │   ├── [R] guest.dart
│       │   │   │   │   └── [R] reservation.dart
│       │   │   │   ├── presentation/
│       │   │   │   │   └── [R] reservations_screen.dart
│       │   │   │   └── [R] README.md
│       │   │   ├── incidents/
│       │   │   │   ├── application/
│       │   │   │   │   └── [R] incidents_providers.dart
│       │   │   │   ├── data/
│       │   │   │   │   └── [R] incidents_repository.dart
│       │   │   │   ├── domain/
│       │   │   │   │   └── [R] incident.dart
│       │   │   │   ├── presentation/
│       │   │   │   │   └── [R] incident_list_screen.dart
│       │   │   │   └── [R] README.md
│       │   │   ├── insights/
│       │   │   │   ├── application/
│       │   │   │   │   └── [R] insights_providers.dart
│       │   │   │   ├── data/
│       │   │   │   │   └── [R] insights_repository.dart
│       │   │   │   ├── domain/
│       │   │   │   │   └── [R] shift_insight.dart
│       │   │   │   ├── presentation/
│       │   │   │   │   └── [R] shift_insights_screen.dart
│       │   │   │   └── [R] README.md
│       │   │   ├── integrations/
│       │   │   │   ├── application/
│       │   │   │   │   └── [R] integrations_providers.dart
│       │   │   │   ├── data/
│       │   │   │   │   └── [R] integrations_repository.dart
│       │   │   │   ├── domain/
│       │   │   │   │   └── [R] payroll_connection.dart
│       │   │   │   ├── presentation/
│       │   │   │   │   └── [R] integrations_screen.dart
│       │   │   │   └── [R] README.md
│       │   │   ├── inventory/
│       │   │   │   ├── application/
│       │   │   │   │   └── [R] inventory_providers.dart
│       │   │   │   ├── data/
│       │   │   │   │   └── [R] inventory_repository.dart
│       │   │   │   ├── domain/
│       │   │   │   │   ├── [R] inventory_item.dart
│       │   │   │   │   └── [R] inventory_v2.dart
│       │   │   │   ├── presentation/
│       │   │   │   │   ├── [R] inventory_action_sheet.dart
│       │   │   │   │   ├── [R] inventory_admin_screen.dart
│       │   │   │   │   ├── [R] inventory_count_screen.dart
│       │   │   │   │   ├── [R] inventory_import_screen.dart
│       │   │   │   │   ├── [R] inventory_item_screen.dart
│       │   │   │   │   ├── [R] inventory_list_screen.dart
│       │   │   │   │   └── [R] inventory_widgets.dart
│       │   │   │   └── [R] README.md
│       │   │   ├── media/
│       │   │   │   ├── application/
│       │   │   │   │   ├── [R] image_picker_service.dart
│       │   │   │   │   ├── [R] media_providers.dart
│       │   │   │   │   └── [R] photo_annotator.dart
│       │   │   │   ├── data/
│       │   │   │   │   └── [R] media_repository.dart
│       │   │   │   ├── domain/
│       │   │   │   │   └── [R] annotation.dart
│       │   │   │   ├── presentation/
│       │   │   │   │   └── [R] photo_annotation_screen.dart
│       │   │   │   └── [R] README.md
│       │   │   ├── notifications/
│       │   │   │   ├── application/
│       │   │   │   │   ├── [R] notification_routing.dart
│       │   │   │   │   ├── [R] notification_tap_service.dart
│       │   │   │   │   ├── [R] notifications_providers.dart
│       │   │   │   │   └── [R] push_registration_service.dart
│       │   │   │   ├── data/
│       │   │   │   │   └── [R] notifications_repository.dart
│       │   │   │   ├── domain/
│       │   │   │   │   └── [R] notification_event.dart
│       │   │   │   ├── presentation/
│       │   │   │   │   └── [R] notifications_screen.dart
│       │   │   │   └── [R] README.md
│       │   │   ├── organizations/
│       │   │   │   ├── application/
│       │   │   │   │   ├── [R] organizations_providers.dart
│       │   │   │   │   └── [R] workspace_provisioning.dart
│       │   │   │   ├── data/
│       │   │   │   │   └── [R] organizations_repository.dart
│       │   │   │   ├── domain/
│       │   │   │   │   ├── [R] organization.dart
│       │   │   │   │   ├── [R] workspace_name.dart
│       │   │   │   │   └── [R] workspace_timezones.dart
│       │   │   │   ├── presentation/
│       │   │   │   │   ├── [R] create_workspace_dialog.dart
│       │   │   │   │   └── [R] organization_venue_switcher_screen.dart
│       │   │   │   └── [R] README.md
│       │   │   ├── pos/
│       │   │   │   ├── application/
│       │   │   │   │   └── [R] pos_providers.dart
│       │   │   │   ├── data/
│       │   │   │   │   └── [R] pos_repository.dart
│       │   │   │   ├── domain/
│       │   │   │   │   ├── [R] pos_check.dart
│       │   │   │   │   └── [R] pos_connection.dart
│       │   │   │   ├── presentation/
│       │   │   │   │   └── [R] pos_management_screen.dart
│       │   │   │   └── [R] README.md
│       │   │   ├── schedules/
│       │   │   │   ├── application/
│       │   │   │   │   └── [R] schedules_providers.dart
│       │   │   │   ├── data/
│       │   │   │   │   └── [R] schedules_repository.dart
│       │   │   │   ├── domain/
│       │   │   │   │   ├── [R] schedule_timeline.dart
│       │   │   │   │   └── [R] shift.dart
│       │   │   │   ├── presentation/
│       │   │   │   │   ├── [R] schedule_list_screen.dart
│       │   │   │   │   └── [R] schedule_timeline_screen.dart
│       │   │   │   └── [R] README.md
│       │   │   ├── settings/
│       │   │   │   ├── application/
│       │   │   │   │   └── [R] settings_providers.dart
│       │   │   │   ├── data/
│       │   │   │   │   └── [R] settings_repository.dart
│       │   │   │   ├── domain/
│       │   │   │   │   └── [R] profile.dart
│       │   │   │   ├── presentation/
│       │   │   │   │   ├── [R] delete_account_button.dart
│       │   │   │   │   └── [R] settings_screen.dart
│       │   │   │   └── [R] README.md
│       │   │   ├── shift_mode/
│       │   │   │   ├── domain/
│       │   │   │   │   └── [R] shift_mode.dart
│       │   │   │   └── presentation/
│       │   │   │       ├── [R] shift_mode_screen.dart
│       │   │   │       └── [R] shift_widgets.dart
│       │   │   ├── staff_requests/
│       │   │   │   ├── application/
│       │   │   │   │   └── [R] staff_requests_providers.dart
│       │   │   │   ├── data/
│       │   │   │   │   └── [R] staff_requests_repository.dart
│       │   │   │   ├── domain/
│       │   │   │   │   └── [R] staff_request.dart
│       │   │   │   ├── presentation/
│       │   │   │   │   └── [R] staff_requests_screen.dart
│       │   │   │   └── [R] README.md
│       │   │   ├── tasks/
│       │   │   │   ├── application/
│       │   │   │   │   ├── [R] task_status_change.dart
│       │   │   │   │   └── [R] tasks_providers.dart
│       │   │   │   ├── data/
│       │   │   │   │   └── [R] tasks_repository.dart
│       │   │   │   ├── domain/
│       │   │   │   │   ├── [R] operational_task.dart
│       │   │   │   │   └── [R] task_board.dart
│       │   │   │   ├── presentation/
│       │   │   │   │   ├── [R] task_board_screen.dart
│       │   │   │   │   └── [R] task_list_screen.dart
│       │   │   │   └── [R] README.md
│       │   │   ├── time_clock/
│       │   │   │   ├── application/
│       │   │   │   │   └── [R] time_clock_providers.dart
│       │   │   │   ├── data/
│       │   │   │   │   └── [R] time_clock_repository.dart
│       │   │   │   ├── domain/
│       │   │   │   │   ├── [R] geofence_helper.dart
│       │   │   │   │   └── [R] time_entry.dart
│       │   │   │   ├── presentation/
│       │   │   │   │   └── [R] time_clock_screen.dart
│       │   │   │   └── [R] README.md
│       │   │   ├── venues/
│       │   │   │   ├── application/
│       │   │   │   │   └── [R] venues_providers.dart
│       │   │   │   ├── data/
│       │   │   │   │   └── [R] venues_repository.dart
│       │   │   │   ├── domain/
│       │   │   │   │   └── [R] venue.dart
│       │   │   │   └── [R] README.md
│       │   │   └── workforce/
│       │   │       ├── application/
│       │   │       │   ├── [R] employee_profiles_providers.dart
│       │   │       │   └── [R] workforce_providers.dart
│       │   │       ├── data/
│       │   │       │   ├── [R] employee_profiles_repository.dart
│       │   │       │   └── [R] workforce_repository.dart
│       │   │       ├── domain/
│       │   │       │   ├── [R] employee_hr_profile.dart
│       │   │       │   └── [R] workforce_models.dart
│       │   │       ├── presentation/
│       │   │       │   ├── [R] employee_profile_widgets.dart
│       │   │       │   └── [R] workforce_roster_screen.dart
│       │   │       └── [R] README.md
│       │   ├── [R] main_development.dart
│       │   ├── [R] main_production.dart
│       │   └── [R] main_staging.dart
│       ├── test/
│       │   ├── app/
│       │   │   └── [R] navigation_test.dart
│       │   ├── core/
│       │   │   ├── auth/
│       │   │   │   └── [R] session_isolation_test.dart
│       │   │   ├── config/
│       │   │   │   └── [R] flavor_test.dart
│       │   │   ├── offline/
│       │   │   │   ├── [R] offline_queue_controller_test.dart
│       │   │   │   ├── [R] offline_queue_store_test.dart
│       │   │   │   └── [R] secure_storage_offline_queue_store_test.dart
│       │   │   ├── security/
│       │   │   │   └── [R] app_attest_service_test.dart
│       │   │   └── theme/
│       │   │       └── [R] app_theme_test.dart
│       │   └── features/
│       │       ├── auth/
│       │       │   ├── [R] reset_password_test.dart
│       │       │   ├── [R] sign_in_screen_test.dart
│       │       │   └── [R] sign_up_screen_test.dart
│       │       ├── billing/
│       │       │   └── [R] billing_screen_test.dart
│       │       ├── chat/
│       │       │   └── [R] chat_screen_test.dart
│       │       ├── checklists/
│       │       │   ├── [R] checklist_completion_screen_test.dart
│       │       │   └── [R] checklist_list_screen_test.dart
│       │       ├── crm/
│       │       │   ├── [R] add_beo_charge_dialog_test.dart
│       │       │   └── [R] crm_screen_test.dart
│       │       ├── employee/
│       │       │   └── [R] employee_home_test.dart
│       │       ├── floor/
│       │       │   ├── [R] floor_editor_controller_test.dart
│       │       │   ├── [R] floor_plan_editor_screen_test.dart
│       │       │   └── [R] floor_plan_screen_test.dart
│       │       ├── guests_reservations/
│       │       │   └── [R] reservations_screen_test.dart
│       │       ├── incidents/
│       │       │   └── [R] incident_list_screen_test.dart
│       │       ├── insights/
│       │       │   └── [R] shift_insights_screen_test.dart
│       │       ├── inventory/
│       │       │   ├── [R] inventory_repository_test.dart
│       │       │   ├── [R] inventory_screens_test.dart
│       │       │   └── [R] inventory_v2_test.dart
│       │       ├── media/
│       │       │   ├── [R] media_providers_test.dart
│       │       │   └── [R] photo_annotation_test.dart
│       │       ├── notifications/
│       │       │   ├── [R] notification_routing_test.dart
│       │       │   └── [R] notifications_screen_test.dart
│       │       ├── organizations/
│       │       │   ├── [R] organization_venue_switcher_screen_test.dart
│       │       │   ├── [R] workspace_provisioning_test.dart
│       │       │   └── [R] workspace_timezones_test.dart
│       │       ├── pos/
│       │       │   └── [R] pos_management_screen_test.dart
│       │       ├── schedules/
│       │       │   └── [R] schedule_timeline_test.dart
│       │       ├── settings/
│       │       │   └── [R] delete_account_button_test.dart
│       │       ├── shift_mode/
│       │       │   └── [R] shift_mode_test.dart
│       │       ├── staff_requests/
│       │       │   └── [R] staff_requests_screen_test.dart
│       │       ├── tasks/
│       │       │   ├── [R] task_board_screen_test.dart
│       │       │   └── [R] task_list_screen_test.dart
│       │       ├── time_clock/
│       │       │   ├── [R] time_clock_screen_test.dart
│       │       │   └── [R] time_entry_domain_test.dart
│       │       └── workforce/
│       │           ├── [R] employee_profiles_test.dart
│       │           └── [R] roster_member_test.dart
│       ├── web/
│       │   ├── icons/
│       │   │   ├── [B] Icon-192.png
│       │   │   ├── [B] Icon-512.png
│       │   │   ├── [B] Icon-maskable-192.png
│       │   │   └── [B] Icon-maskable-512.png
│       │   ├── [B] favicon.png
│       │   ├── [R] flutter_bootstrap.js
│       │   ├── [R] index.html
│       │   └── [R] manifest.json
│       ├── [R] .gitignore
│       ├── [R] .metadata
│       ├── [R] analysis_options.yaml
│       ├── [R] pubspec.lock
│       ├── [R] pubspec.yaml
│       └── [R] README.md
├── docs/
│   ├── integrations/
│   │   └── [R] pos-webhook.md
│   ├── migration/
│   │   ├── [R] account-deletion-dispatch-setup.md
│   │   ├── [N] flutter-cutover-closeout-2026-10-03.md
│   │   ├── [N] flutter-supabase-rebuild-plan.md
│   │   ├── [N] phase4-handoff-batch2.txt
│   │   ├── [N] phase4-port-remaining-modules-handoff.md
│   │   ├── [N] phase4-validation-report.md
│   │   ├── [N] phase5-validation-report.md
│   │   ├── [R] pos-schedule-platform-rollback.sql
│   │   └── [R] push-dispatch-setup.md
│   ├── reviews/
│   │   ├── [N] flutter-ui-profiles-correction-2026-10-06.md
│   │   └── [N] repo-review-2026-10-06.md
│   ├── security/
│   │   └── [N] REMEDIATION-HANDOFF.md
│   ├── soc2/
│   │   ├── [N] access-control-policy.md
│   │   ├── [N] business-continuity-disaster-recovery.md
│   │   ├── [N] data-retention-disposal-policy.md
│   │   ├── [N] incident-response-plan.md
│   │   ├── [N] information-security-policy.md
│   │   ├── [N] prowler-guide.md
│   │   ├── [R] README.md
│   │   ├── [N] soc2-controls-matrix.md
│   │   └── [N] vendor-management-policy.md
│   ├── [N] ANTIGRAVITY_HANDOFF_BILLING.md
│   ├── [N] CLAUDE_HANDOFF_REPO_REVIEW_FIXES.md
│   ├── [N] cloud-security-triage-2026-09-08.md
│   ├── [R] code-review-2026-10-07.md
│   ├── [N] HANDOFF_CODE_REVIEW_FIXES.md
│   ├── [N] HANDOFF_GROK_AUDIT_FIXES.md
│   ├── [N] inventory-recipes-and-units.md
│   ├── [N] inventory-v2.md
│   ├── [N] luxury-command-system.md
│   ├── [N] pos-integration-platform.md
│   ├── [N] privacy-policy.md
│   ├── [R] production-operations.md
│   ├── [N] production-readiness-2026-09-18.md
│   ├── [N] release-quality-gates.md
│   ├── [N] tenant-isolation.md
│   ├── [N] ui-redesign-progress.md
│   ├── [N] wrangler-engine-v1.md
│   └── [N] wrangler-home-ui.md
├── packages/
│   └── marketing/
│       ├── src/
│       │   ├── [R] App.tsx
│       │   ├── [R] main.tsx
│       │   ├── [R] styles.css
│       │   └── [R] vite-env.d.ts
│       ├── [R] index.html
│       ├── [R] package.json
│       ├── [R] README.md
│       ├── [R] tsconfig.json
│       └── [R] vite.config.ts
├── public/
│   ├── images/
│   │   ├── [B] vw_ai_inventory_ui.png
│   │   ├── [B] vw_command_center_ui.png
│   │   ├── [B] vw_floor_plan_ui.png
│   │   └── [B] vw_live_chat_ui.png
│   ├── support/
│   │   └── [R] index.html
│   ├── [R] sales-deck.html
│   └── [B] Venue_Wrangler_Sales_Deck.pdf
├── scripts/
│   ├── [R] audit-gate.mjs
│   ├── [R] build-site.mjs
│   ├── [R] make-appstore-screenshots.py
│   ├── [R] make-ipad-appstore-screenshots.py
│   ├── [R] make-review-screenshot.py
│   ├── [R] make-subscription-images.py
│   ├── [R] make-zeroed-appstore-screenshots.py
│   └── [R] site-build-files.mjs
├── site/
│   ├── .well-known/
│   │   ├── [R] apple-app-site-association
│   │   ├── [R] assetlinks.json
│   │   └── [R] assetlinks.json.NEEDS_REAL_FINGERPRINT.md
│   ├── assets/
│   │   ├── [B] 01-dashboard.png
│   │   ├── [B] 02-schedule.png
│   │   ├── [B] 03-timeclock.png
│   │   ├── [B] 04-floorplan.png
│   │   ├── [B] 05-chat.png
│   │   ├── [B] logo.jpg
│   │   ├── [B] screen-availability.png
│   │   ├── [B] screen-command.png
│   │   ├── [B] screen-floor.png
│   │   ├── [B] screen-inventory.png
│   │   ├── [B] screen-reports.png
│   │   ├── [B] screen-reservations.png
│   │   └── [B] venue-wrangler-ad.mp4
│   ├── billing/
│   │   └── [R] index.html
│   ├── faq/
│   │   └── [R] index.html
│   ├── join/
│   │   ├── success/
│   │   │   └── [R] index.html
│   │   └── [R] index.html
│   ├── marketing-assets/
│   │   ├── [G] index-BD29tyyz.js
│   │   ├── [G] index-CKT30Hkh.js
│   │   ├── [G] index-CT2XBtsO.js
│   │   └── [G] index-D4wbbrvQ.css
│   ├── privacy/
│   │   └── [R] index.html
│   ├── support/
│   │   └── [R] index.html
│   ├── terms/
│   │   └── [R] index.html
│   ├── [R] _headers
│   ├── [R] _redirects
│   ├── [R] _routes.json
│   ├── [R] _worker.js
│   ├── [R] 404.html
│   ├── [G] index.html
│   ├── [R] onboarding.spec.ts
│   ├── [G] opener.js
│   ├── [R] opener.src.jsx
│   ├── [R] robots.txt
│   └── [R] sitemap.xml
├── store/
│   ├── [R] app-store-connect.md
│   ├── [B] google-play-feature-graphic.png
│   ├── [R] google-play.md
│   └── [R] README.md
├── supabase/
│   ├── functions/
│   │   ├── _shared/
│   │   │   ├── [R] apns.ts
│   │   │   ├── [R] app-attest.ts
│   │   │   ├── [R] cbor.ts
│   │   │   ├── [R] clamav.ts
│   │   │   ├── [R] cors.ts
│   │   │   ├── [R] crypto_test.ts
│   │   │   ├── [R] crypto.ts
│   │   │   ├── [R] der.ts
│   │   │   ├── [R] document-bytes_test.ts
│   │   │   ├── [R] document-bytes.ts
│   │   │   ├── [R] google-auth.ts
│   │   │   ├── [R] groq.ts
│   │   │   ├── [R] malware-scan.ts
│   │   │   ├── [R] observability.ts
│   │   │   ├── [R] play-integrity_test.ts
│   │   │   ├── [R] play-integrity.ts
│   │   │   ├── [R] push-delivery.ts
│   │   │   ├── [R] stripe.ts
│   │   │   ├── [R] supabase-clients.ts
│   │   │   └── [R] venue-auth.ts
│   │   ├── account-deletion-worker/
│   │   │   └── [R] index.ts
│   │   ├── ai-assistant/
│   │   │   ├── [R] index.ts
│   │   │   └── [R] prompts.ts
│   │   ├── crm-send-email/
│   │   │   └── [R] index.ts
│   │   ├── device-attestation/
│   │   │   └── [R] index.ts
│   │   ├── documents-upload/
│   │   │   └── [R] index.ts
│   │   ├── gusto-oauth/
│   │   │   └── [R] index.ts
│   │   ├── notifications-dispatch/
│   │   │   └── [R] index.ts
│   │   ├── notifications-send/
│   │   │   └── [R] index.ts
│   │   ├── quickbooks-oauth/
│   │   │   └── [R] index.ts
│   │   ├── square-oauth/
│   │   │   └── [R] index.ts
│   │   ├── stripe-create-checkout/
│   │   │   └── [R] index.ts
│   │   ├── stripe-create-portal/
│   │   │   └── [R] index.ts
│   │   ├── stripe-webhook/
│   │   │   └── [R] index.ts
│   │   ├── toast-pos/
│   │   │   └── [R] index.ts
│   │   ├── [R] deno.json
│   │   └── [R] deno.lock
│   ├── migrations/
│   │   ├── [R] 20261002154052_foundation_schema.sql
│   │   ├── [R] 20261002154114_tasks_schema.sql
│   │   ├── [R] 20261002154143_checklists_schema.sql
│   │   ├── [R] 20261002154205_incidents_schema.sql
│   │   ├── [R] 20261002154223_storage_buckets.sql
│   │   ├── [R] 20261002154238_incident_attachments.sql
│   │   ├── [R] 20261002154307_harden_try_cast_uuid_search_path.sql
│   │   ├── [R] 20261002154310_harden_rls_performance.sql
│   │   ├── [R] 20261002171532_ai_usage.sql
│   │   ├── [R] 20261002172436_ai_usage_events_user_id_index.sql
│   │   ├── [R] 20261002174928_workforce_invites.sql
│   │   ├── [R] 20261002175142_inventory_schema.sql
│   │   ├── [R] 20261002175340_schedules_schema.sql
│   │   ├── [R] 20261002182117_subscriptions_schema.sql
│   │   ├── [R] 20261002182919_payroll_connections_schema.sql
│   │   ├── [R] 20261002183723_invite_redemption.sql
│   │   ├── [R] 20261002184109_shift_swaps_schema.sql
│   │   ├── [R] 20261002184420_device_attestation.sql
│   │   ├── [R] 20261002184707_events_schema.sql
│   │   ├── [R] 20261002185029_harden_subscription_is_entitled.sql
│   │   ├── [R] 20261002205115_staff_requests_schema.sql
│   │   ├── [R] 20261002233843_shift_insights_schema.sql
│   │   ├── [R] 20261002233921_time_clock_schema.sql
│   │   ├── [R] 20261002233940_ensure_public_grants.sql
│   │   ├── [R] 20261002234421_storage_deletion_jobs_schema.sql
│   │   ├── [R] 20261002235811_notifications_schema.sql
│   │   ├── [R] 20261002235847_guests_reservations_schema.sql
│   │   ├── [R] 20261002235927_floor_schema.sql
│   │   ├── [R] 20261003000000_pos_schema.sql
│   │   ├── [R] 20261003000037_chat_schema.sql
│   │   ├── [R] 20261003000100_harden_batch2_search_path_and_rpc_grants.sql
│   │   ├── [R] 20261003001000_storage_deletion_worker_and_schedule.sql
│   │   ├── [R] 20261003005913_crm_schema.sql
│   │   ├── [R] 20261003043737_documents_schema.sql
│   │   ├── [R] 20261003113416_attestation_challenges_schema.sql
│   │   ├── [R] 20261004023154_payment_and_notification_hardening.sql
│   │   ├── [R] 20261004144042_remove_beo_deposit_and_stripe_connect.sql
│   │   ├── [R] 20261005115202_chat_storage_conversation_scoping.sql
│   │   ├── [R] 20261005115215_ai_budget_atomic_reservation.sql
│   │   ├── [R] 20261005115222_stripe_webhook_idempotency.sql
│   │   ├── [R] 20261005115231_storage_bucket_limits.sql
│   │   ├── [R] 20261005115245_invite_redemption_confirmed_email.sql
│   │   ├── [R] 20261005115252_drop_debug_helpers.sql
│   │   ├── [R] 20261005214454_restrict_reserve_ai_budget.sql
│   │   ├── [R] 20261005220028_notification_triggers_and_dispatch.sql
│   │   ├── [R] 20261006150753_floor_layout_managers_and_atomic_publish.sql
│   │   ├── [R] 20261006160946_staff_section_and_reservation_assignment.sql
│   │   ├── [R] 20261006203252_harden_time_entry_integrity.sql
│   │   ├── [R] 20261006203635_time_entry_breaks_comparison_fix.sql
│   │   ├── [R] 20261006203829_time_entry_breaks_equal_hardening.sql
│   │   ├── [R] 20261006212133_flutter_staff_hr_and_photos.sql
│   │   ├── [R] 20261007021641_pos_schedule_platform.sql
│   │   ├── [R] 20261007021847_pos_schedule_fk_indexes.sql
│   │   ├── [R] 20261007131539_create_workspace_self_serve_signup.sql
│   │   ├── [R] 20261007160000_crm_beo_charges.sql
│   │   ├── [R] 20261007180000_account_deletion.sql
│   │   ├── [R] 20261007190000_account_deletion_fixes.sql
│   │   ├── [R] 20261007191000_create_workspace_timezone_validation.sql
│   │   ├── [R] 20261007192000_venue_roster_rpc.sql
│   │   ├── [R] 20261007193000_apply_stripe_subscription_state.sql
│   │   ├── [R] 20261007200621_restaurant_inventory_v2.sql
│   │   ├── [R] 20261007201000_review_fixes_stripe_inventory_roster.sql
│   │   ├── [R] 20261007202000_review_tenant_guards.sql
│   │   ├── [R] 20261007210000_fix_review_guard_record_fields.sql
│   │   └── [R] 20261010120000_retention_cleanup_in_database.sql
│   ├── rollbacks/
│   │   ├── [R] 20261007131539_create_workspace_self_serve_signup.sql
│   │   ├── [R] 20261007160000_crm_beo_charges.sql
│   │   ├── [R] 20261007180000_account_deletion.sql
│   │   ├── [R] 20261007190000_account_deletion_fixes.sql
│   │   ├── [R] 20261007191000_create_workspace_timezone_validation.sql
│   │   ├── [R] 20261007192000_venue_roster_rpc.sql
│   │   ├── [R] 20261007193000_apply_stripe_subscription_state.sql
│   │   ├── [R] 20261007201000_review_fixes_stripe_inventory_roster.sql
│   │   ├── [R] 20261007210000_fix_review_guard_record_fields.sql
│   │   └── [R] 20261010120000_retention_cleanup_in_database.sql
│   ├── tests/
│   │   ├── database/
│   │   │   ├── [R] account_deletion.test.sql
│   │   │   ├── [R] ai_usage_rls.test.sql
│   │   │   ├── [R] attestation_challenges_rls.test.sql
│   │   │   ├── [R] chat_rls.test.sql
│   │   │   ├── [R] checklists_rls.test.sql
│   │   │   ├── [R] create_workspace.test.sql
│   │   │   ├── [R] crm_beo_charges.test.sql
│   │   │   ├── [R] crm_rls.test.sql
│   │   │   ├── [R] device_attestation_rls.test.sql
│   │   │   ├── [R] documents_rls.test.sql
│   │   │   ├── [R] employee_hr_profiles_rls.test.sql
│   │   │   ├── [R] events_rls.test.sql
│   │   │   ├── [R] floor_rls.test.sql
│   │   │   ├── [R] foundation_rls.test.sql
│   │   │   ├── [R] guests_reservations_rls.test.sql
│   │   │   ├── [R] incident_attachments_rls.test.sql
│   │   │   ├── [R] incidents_rls.test.sql
│   │   │   ├── [R] inventory_rls.test.sql
│   │   │   ├── [R] inventory_v2.test.sql
│   │   │   ├── [R] invite_redemption.test.sql
│   │   │   ├── [R] invites_rls.test.sql
│   │   │   ├── [R] notification_receipts.test.sql
│   │   │   ├── [R] notifications_rls.test.sql
│   │   │   ├── [R] operational_tasks_rls.test.sql
│   │   │   ├── [R] payroll_connections_rls.test.sql
│   │   │   ├── [R] pos_rls.test.sql
│   │   │   ├── [R] pos_schedule_platform.test.sql
│   │   │   ├── [R] retention_cleanup.test.sql
│   │   │   ├── [R] shift_insights_rls.test.sql
│   │   │   ├── [R] shift_swaps_rls.test.sql
│   │   │   ├── [R] shifts_rls.test.sql
│   │   │   ├── [R] staff_requests_rls.test.sql
│   │   │   ├── [R] storage_deletion_jobs_rls.test.sql
│   │   │   ├── [R] storage_policies.test.sql
│   │   │   ├── [R] stripe_subscription_state.test.sql
│   │   │   ├── [R] subscriptions_rls.test.sql
│   │   │   ├── [R] time_clock_rls.test.sql
│   │   │   └── [R] venue_roster.test.sql
│   │   ├── fixtures/
│   │   │   ├── [R] inventory_v2_legacy_assertions.sql
│   │   │   └── [R] inventory_v2_legacy.sql
│   │   ├── [R] ci_auth_stub.sql
│   │   ├── [R] ci_grants_stub.sql
│   │   ├── [R] ci_storage_stub.sql
│   │   └── [R] README.md
│   ├── [R] .env.example
│   ├── [R] config.toml
│   └── [R] seed.sql
├── tests/
│   └── [R] workflow-security.spec.ts
├── tool/
│   └── [R] test_inventory_v2_database.py
├── [R] .gitignore
├── [R] AGENTS.md
├── [R] CLAUDE.md
├── [R] codemagic.yaml
├── [R] flutter-version.txt
├── [R] package-lock.json
├── [R] package.json
├── [R] README.md
├── [R] tsconfig.json
└── [R] vitest.config.mts
[deliverable] AUDIT_FINDINGS.md
```

## Appendix B. Dependency and asset inventory

| Direct dependency | Kind | Declared constraint | Locked version |
|---|---|---|---|
| flutter | dependencies | Flutter SDK | 0.0.0 |
| flutter_riverpod | dependencies | ^2.6.1 | 2.6.1 |
| go_router | dependencies | ^14.6.2 | 14.8.1 |
| supabase_flutter | dependencies | ^2.8.0 | 2.18.0 |
| flutter_secure_storage | dependencies | ^9.2.4 | 9.2.4 |
| connectivity_plus | dependencies | ^6.1.0 | 6.1.5 |
| path_provider | dependencies | ^2.1.5 | 2.1.6 |
| sentry_flutter | dependencies | ^9.30.1 | 9.30.1 |
| image_picker | dependencies | ^1.1.2 | 1.2.4 |
| file_picker | dependencies | ^8.3.7 | 8.3.7 |
| url_launcher | dependencies | ^6.3.1 | 6.3.3 |
| uuid | dependencies | ^4.5.1 | 4.6.0 |
| cupertino_icons | dependencies | ^1.0.8 | 1.0.9 |
| firebase_core | dependencies | ^3.8.0 | 3.15.2 |
| firebase_messaging | dependencies | ^15.1.5 | 15.2.10 |
| geolocator | dependencies | ^14.0.2 | 14.0.2 |
| video_player | dependencies | ^2.9.2 | 2.14.1 |
| flutter_test | dev_dependencies | Flutter SDK | 0.0.0 |
| flutter_lints | dev_dependencies | ^5.0.0 | 5.0.0 |
| http | dev_dependencies | ^1.6.0 | 1.6.0 |
| url_launcher_platform_interface | dev_dependencies | ^2.3.2 | 2.3.2 |
| flutter_secure_storage_platform_interface | dev_dependencies | ^1.1.2 | 1.1.2 |

Root Node tooling: npm@11.12.1; TypeScript ~6.0.3, Vitest ^5.0.0, @types/node ^22.0.0. Marketing is the only workspace package. No dependency upgrade or audit autofix ran.

| Marketing dependency | Kind | Declared | Locked |
|---|---|---|---|
| clsx | dependencies | ^2.1.1 | 2.1.1 |
| framer-motion | dependencies | ^13.2.0 | 13.2.0 |
| lucide-react | dependencies | ^1.44.0 | 1.44.0 |
| qrcode.react | dependencies | ^4.2.0 | 4.2.0 |
| react | dependencies | 19.2.3 | 19.2.3 |
| react-dom | dependencies | 19.2.3 | 19.2.3 |
| tailwind-merge | dependencies | ^3.0.0 | 3.6.0 |
| @tailwindcss/vite | devDependencies | ^4.0.0 | 4.3.3 |
| @types/react-dom | devDependencies | ^19.0.0 | 19.2.7 |
| @vitejs/plugin-react | devDependencies | ^6.1.1 | 6.1.1 |
| tailwindcss | devDependencies | ^4.0.0 | 4.3.3 |
| typescript | devDependencies | ~6.0.3 | 6.0.3 |
| vite | devDependencies | ^8.3.0 | 8.3.0 |

Edge lock: npm Supabase JS 2.117.2, Sentry Deno 8.55.2, Stripe 23.0.0; esm Supabase JS resolves separately to 2.110.0. Mixed import channels were inspected but not Deno-typechecked in this audit.

| Binary asset | Bytes | Inspection |
|---|---:|---|
| `apps/mobile/android/app/src/main/res/mipmap-hdpi/ic_launcher.png` | 7126 | 72 x 72; RGB; no artwork review |
| `apps/mobile/android/app/src/main/res/mipmap-mdpi/ic_launcher.png` | 3954 | 48 x 48; RGB; no artwork review |
| `apps/mobile/android/app/src/main/res/mipmap-xhdpi/ic_launcher.png` | 10978 | 96 x 96; RGB; no artwork review |
| `apps/mobile/android/app/src/main/res/mipmap-xxhdpi/ic_launcher.png` | 18847 | 144 x 144; RGB; no artwork review |
| `apps/mobile/android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png` | 26433 | 192 x 192; RGB; no artwork review |
| `apps/mobile/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-1024x1024@1x.png` | 216853 | 1024 x 1024; RGB; no artwork review |
| `apps/mobile/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-20x20@1x.png` | 1259 | 20 x 20; RGB; no artwork review |
| `apps/mobile/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-20x20@2x.png` | 3069 | 40 x 40; RGB; no artwork review |
| `apps/mobile/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-20x20@3x.png` | 5564 | 60 x 60; RGB; no artwork review |
| `apps/mobile/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-29x29@1x.png` | 2031 | 29 x 29; RGB; no artwork review |
| `apps/mobile/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-29x29@2x.png` | 5244 | 58 x 58; RGB; no artwork review |
| `apps/mobile/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-29x29@3x.png` | 9453 | 87 x 87; RGB; no artwork review |
| `apps/mobile/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-40x40@1x.png` | 3069 | 40 x 40; RGB; no artwork review |
| `apps/mobile/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-40x40@2x.png` | 8342 | 80 x 80; RGB; no artwork review |
| `apps/mobile/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-40x40@3x.png` | 14900 | 120 x 120; RGB; no artwork review |
| `apps/mobile/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-60x60@2x.png` | 14900 | 120 x 120; RGB; no artwork review |
| `apps/mobile/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-60x60@3x.png` | 25366 | 180 x 180; RGB; no artwork review |
| `apps/mobile/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-76x76@1x.png` | 7769 | 76 x 76; RGB; no artwork review |
| `apps/mobile/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-76x76@2x.png` | 20146 | 152 x 152; RGB; no artwork review |
| `apps/mobile/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-83.5x83.5@2x.png` | 22322 | 167 x 167; RGB; no artwork review |
| `apps/mobile/ios/Runner/Assets.xcassets/LaunchImage.imageset/LaunchImage.png` | 68 | 1 x 1; LA; no artwork review |
| `apps/mobile/ios/Runner/Assets.xcassets/LaunchImage.imageset/LaunchImage@2x.png` | 68 | 1 x 1; LA; no artwork review |
| `apps/mobile/ios/Runner/Assets.xcassets/LaunchImage.imageset/LaunchImage@3x.png` | 68 | 1 x 1; LA; no artwork review |
| `apps/mobile/web/favicon.png` | 26433 | 192 x 192; RGB; no artwork review |
| `apps/mobile/web/icons/Icon-192.png` | 26433 | 192 x 192; RGB; no artwork review |
| `apps/mobile/web/icons/Icon-512.png` | 216853 | 1024 x 1024; RGB; no artwork review |
| `apps/mobile/web/icons/Icon-maskable-192.png` | 26433 | 192 x 192; RGB; no artwork review |
| `apps/mobile/web/icons/Icon-maskable-512.png` | 216853 | 1024 x 1024; RGB; no artwork review |
| `apps/mobile/assets/video/intro.mp4` | 4834654 | size only; no playback/PDF rendering |
| `public/images/vw_ai_inventory_ui.png` | 552746 | 1024 x 1024; RGB; no artwork review |
| `public/images/vw_command_center_ui.png` | 596013 | 1024 x 1024; RGB; no artwork review |
| `public/images/vw_floor_plan_ui.png` | 653872 | 1024 x 1024; RGB; no artwork review |
| `public/images/vw_live_chat_ui.png` | 473788 | 1024 x 1024; RGB; no artwork review |
| `public/Venue_Wrangler_Sales_Deck.pdf` | 277010 | size only; no playback/PDF rendering |
| `store/google-play-feature-graphic.png` | 679381 | 1024 x 500; RGBA; no artwork review |
| `site/assets/01-dashboard.png` | 134214 | 1284 x 2778; RGB; no artwork review |
| `site/assets/02-schedule.png` | 103350 | 1284 x 2778; RGB; no artwork review |
| `site/assets/03-timeclock.png` | 90530 | 1284 x 2778; RGB; no artwork review |
| `site/assets/04-floorplan.png` | 79519 | 1284 x 2778; RGB; no artwork review |
| `site/assets/05-chat.png` | 109215 | 1284 x 2778; RGB; no artwork review |
| `site/assets/logo.jpg` | 67874 | 1024 x 559; RGB; no artwork review |
| `site/assets/screen-availability.png` | 806714 | 1242 x 2688; RGB; no artwork review |
| `site/assets/screen-command.png` | 493791 | 1242 x 2688; RGB; no artwork review |
| `site/assets/screen-floor.png` | 488126 | 1242 x 2688; RGB; no artwork review |
| `site/assets/screen-inventory.png` | 499580 | 1242 x 2688; RGB; no artwork review |
| `site/assets/screen-reports.png` | 557858 | 1242 x 2688; RGB; no artwork review |
| `site/assets/screen-reservations.png` | 526964 | 1242 x 2688; RGB; no artwork review |
| `site/assets/venue-wrangler-ad.mp4` | 13646967 | size only; no playback/PDF rendering |

App intro video is approximately 4.83 MB; public ad video approximately 13.65 MB. Largest standalone site screenshots are approximately 0.81 MB. Sizes are observations, not proof of a performance defect. Web files named Icon-512 contain 1024-pixel images and the manifest correctly declares 1024x1024; filename alone is not a mismatch. Sales-deck HTML contains embedded image bytes; authored HTML/JS was read with those bytes excluded, and embedded artwork was not rendered.

## Appendix C. SQL/source inspection index

All 120 SQL files appear in the checklist/tree: 65 migrations, 38 database test suites, 10 rollback files, one documented POS/schedule rollback, one seed, three CI auth/storage/grant stubs and two inventory migration fixtures. They were inspected as text only.

| Migration | Source declarations / replacements |
|---|---|
| `20261002154052_foundation_schema.sql` | tables: public.organizations, public.venues, public.profiles, public.platform_admins, public.memberships, public.audit_log; functions: app_hidden.is_platform_admin, app_hidden.has_org_role, app_hidden.has_venue_role, app_hidden.is_org_member, app_hidden.is_venue_member, app_hidden.shares_scope_with, app_hidden.handle_new_user; 1 triggers; 10 policies |
| `20261002154114_tasks_schema.sql` | tables: public.operational_tasks; functions: app_hidden.prepare_task_insert, app_hidden.sync_task_organization_id, app_hidden.sync_task_timestamps, app_hidden.enforce_task_update_scope; 4 triggers; 4 policies |
| `20261002154143_checklists_schema.sql` | tables: public.checklist_templates, public.checklist_template_items, public.checklist_completions; functions: app_hidden.prepare_checklist_template_insert, app_hidden.sync_checklist_item_venue_id, app_hidden.prepare_checklist_completion_insert; 3 triggers; 12 policies |
| `20261002154205_incidents_schema.sql` | tables: public.incidents; functions: app_hidden.prepare_incident_insert, app_hidden.sync_incident_resolution, app_hidden.enforce_incident_update_scope, app_hidden.log_incident_status_change; 4 triggers; 4 policies |
| `20261002154223_storage_buckets.sql` | functions: app_hidden.try_cast_uuid, app_hidden.storage_path_venue_id; 3 policies |
| `20261002154238_incident_attachments.sql` | tables: public.incident_attachments; functions: app_hidden.prepare_incident_attachment_insert; 1 triggers; 3 policies |
| `20261002154307_harden_try_cast_uuid_search_path.sql` | alter/grant/index/data migration |
| `20261002154310_harden_rls_performance.sql` | 5 policies |
| `20261002171532_ai_usage.sql` | tables: public.ai_usage_events, public.ai_budget_reservations; functions: public.ai_org_spend_this_month; 2 policies |
| `20261002172436_ai_usage_events_user_id_index.sql` | alter/grant/index/data migration |
| `20261002174928_workforce_invites.sql` | tables: public.invites; functions: app_hidden.prepare_invite_insert, app_hidden.enforce_invite_revoke_only; 2 triggers; 3 policies |
| `20261002175142_inventory_schema.sql` | tables: public.inventory_items; functions: app_hidden.prepare_inventory_item_insert, app_hidden.sync_inventory_item_update; 2 triggers; 4 policies |
| `20261002175340_schedules_schema.sql` | tables: public.shifts; functions: app_hidden.prepare_shift_insert, app_hidden.sync_shift_update; 2 triggers; 4 policies |
| `20261002182117_subscriptions_schema.sql` | tables: public.subscriptions; functions: public.subscription_is_entitled; 1 policies |
| `20261002182919_payroll_connections_schema.sql` | tables: public.payroll_connections; functions: app_hidden.prepare_payroll_connection_insert, app_hidden.sync_payroll_connection_update; 2 triggers; 1 policies |
| `20261002183723_invite_redemption.sql` | functions: app_hidden.enforce_invite_revoke_only, app_hidden.handle_new_user |
| `20261002184109_shift_swaps_schema.sql` | tables: public.shift_swaps; functions: app_hidden.prepare_shift_swap_insert, app_hidden.enforce_shift_swap_update, app_hidden.sync_shift_swap_timestamp, app_hidden.apply_accepted_shift_swap; 4 triggers; 3 policies |
| `20261002184420_device_attestation.sql` | tables: public.device_attestations; 1 policies |
| `20261002184707_events_schema.sql` | tables: public.events; functions: app_hidden.prepare_event_insert, app_hidden.sync_event_update; 2 triggers; 4 policies |
| `20261002185029_harden_subscription_is_entitled.sql` | functions: public.subscription_is_entitled |
| `20261002205115_staff_requests_schema.sql` | tables: public.staff_requests; functions: app_hidden.prepare_staff_request_insert, app_hidden.enforce_staff_request_update, app_hidden.sync_staff_request_timestamp, app_hidden.apply_approved_staff_request; 4 triggers; 3 policies |
| `20261002233843_shift_insights_schema.sql` | tables: public.shift_insights; functions: app_hidden.prepare_shift_insight_insert, app_hidden.sync_shift_insight_update; 2 triggers; 4 policies |
| `20261002233921_time_clock_schema.sql` | tables: public.time_entries; functions: app_hidden.haversine_distance_m, app_hidden.prepare_time_entry_insert, app_hidden.enforce_time_entry_update; 2 triggers; 4 policies |
| `20261002233940_ensure_public_grants.sql` | alter/grant/index/data migration |
| `20261002234421_storage_deletion_jobs_schema.sql` | tables: public.storage_deletion_jobs; functions: app_hidden.is_safe_storage_deletion_path, app_hidden.prepare_storage_deletion_job_insert, app_hidden.process_storage_deletion_batch; 1 triggers |
| `20261002235811_notifications_schema.sql` | tables: public.push_tokens, public.notification_events; functions: public.register_push_token, app_hidden.disable_push_tokens, app_hidden.prepare_notification_event_insert; 1 triggers; 4 policies |
| `20261002235847_guests_reservations_schema.sql` | tables: public.guests, public.guest_household_links, public.reservations, public.reservation_connections, public.webhook_replay_log; functions: app_hidden.guests_derive_org_and_lock_venue, app_hidden.guest_household_links_derive, app_hidden.reservations_derive_org_and_lock_venue, app_hidden.reservation_connections_derive_org, app_hidden.record_and_check_webhook_replay; 4 triggers; 12 policies |
| `20261002235927_floor_schema.sql` | tables: public.floor_plans, public.floor_tables, public.floor_table_assignments; functions: app_hidden.floor_plans_derive_org, app_hidden.floor_tables_derive_org, app_hidden.floor_table_assignments_derive, public.merge_floor_tables, public.split_floor_tables, public.assign_tables_to_reservation, public.update_floor_table_status; 3 triggers; 6 policies |
| `20261003000000_pos_schema.sql` | tables: public.pos_connections, public.pos_checks, public.pos_outbound_commands; functions: app_hidden.pos_connections_derive_org, app_hidden.pos_checks_derive_org, app_hidden.pos_outbound_commands_derive_org, app_hidden.claim_pos_outbound_commands_batch; 3 triggers; 4 policies |
| `20261003000037_chat_schema.sql` | tables: public.conversations, public.conversation_members, public.messages, public.conversation_reads; functions: app_hidden.conversations_derive_org, app_hidden.conversation_members_derive, app_hidden.is_conversation_member, app_hidden.messages_derive_and_touch, app_hidden.enqueue_chat_attachment_deletion, app_hidden.conversation_reads_derive, public.create_or_get_dm; 5 triggers; 12 policies |
| `20261003000100_harden_batch2_search_path_and_rpc_grants.sql` | functions: app_hidden.haversine_distance_m, app_hidden.is_safe_storage_deletion_path |
| `20261003001000_storage_deletion_worker_and_schedule.sql` | functions: app_hidden.process_storage_deletion_batch |
| `20261003005913_crm_schema.sql` | tables: public.crm_leads, public.crm_notes, public.crm_beos, public.crm_contracts, public.crm_activity_log, public.email_templates; functions: app_hidden.crm_leads_derive, app_hidden.crm_leads_log_status_change, app_hidden.crm_notes_derive, app_hidden.crm_notes_log_activity, app_hidden.crm_beos_derive, app_hidden.crm_beos_sync_reservation, app_hidden.crm_contracts_derive, app_hidden.crm_activity_log_derive, app_hidden.email_templates_derive, public.crm_pipeline_forecast, public.crm_source_roi, public.crm_stale_leads, public.convert_beo_to_contract, public.waive_beo_deposit, public.render_email_template; 9 triggers; 16 policies |
| `20261003043737_documents_schema.sql` | tables: public.documents; functions: app_hidden.prepare_document_insert, app_hidden.enqueue_document_storage_deletion, app_hidden.storage_path_document_category; 2 triggers; 3 policies |
| `20261003113416_attestation_challenges_schema.sql` | tables: public.attestation_challenges |
| `20261004023154_payment_and_notification_hardening.sql` | tables: public.organization_stripe_accounts; 1 policies |
| `20261004144042_remove_beo_deposit_and_stripe_connect.sql` | functions: public.convert_beo_to_contract, public.render_email_template, app_hidden.crm_beos_derive |
| `20261005115202_chat_storage_conversation_scoping.sql` | functions: app_hidden.storage_path_conversation_id, app_hidden.is_safe_storage_deletion_path; 2 policies |
| `20261005115215_ai_budget_atomic_reservation.sql` | functions: public.reserve_ai_budget |
| `20261005115222_stripe_webhook_idempotency.sql` | tables: public.stripe_processed_events |
| `20261005115231_storage_bucket_limits.sql` | alter/grant/index/data migration |
| `20261005115245_invite_redemption_confirmed_email.sql` | functions: app_hidden.handle_new_user; 1 triggers |
| `20261005115252_drop_debug_helpers.sql` | alter/grant/index/data migration |
| `20261005214454_restrict_reserve_ai_budget.sql` | alter/grant/index/data migration |
| `20261005220028_notification_triggers_and_dispatch.sql` | functions: app_hidden.dispatch_notification_push, app_hidden.notify_shift_assigned, app_hidden.notify_staff_request_created; 3 triggers |
| `20261006150753_floor_layout_managers_and_atomic_publish.sql` | functions: public.save_floor_layout; 1 policies |
| `20261006160946_staff_section_and_reservation_assignment.sql` | alter/grant/index/data migration |
| `20261006203252_harden_time_entry_integrity.sql` | functions: public.correct_time_entry, app_hidden.prepare_time_entry_insert, app_hidden.enforce_time_entry_update |
| `20261006203635_time_entry_breaks_comparison_fix.sql` | functions: app_hidden.break_entries_equal, app_hidden.enforce_time_entry_update |
| `20261006203829_time_entry_breaks_equal_hardening.sql` | functions: app_hidden.break_entries_equal, app_hidden.break_type_and_start_equal, app_hidden.enforce_time_entry_update |
| `20261006212133_flutter_staff_hr_and_photos.sql` | tables: public.employee_hr_profiles, public.staff_photos; functions: app_hidden.can_manage_staff_profile, app_hidden.guard_employee_hr_profile, app_hidden.guard_staff_photo, app_hidden.profile_photo_access; 2 triggers; 9 policies |
| `20261007021641_pos_schedule_platform.sql` | tables: public.pos_connection_capabilities, public.pos_location_mappings, public.pos_employee_mappings, public.pos_job_mappings, public.pos_external_shift_mappings, public.pos_schedule_versions, public.pos_outbound_jobs, public.pos_sync_conflicts, public.pos_sales, public.pos_time_entries, public.pos_sync_runs, public.pos_audit_events; functions: public.request_pos_connection, public.publish_pos_schedule, public.claim_pos_outbound_jobs, public.ack_pos_outbound_job, public.fail_pos_outbound_job, app_hidden.protect_pos_shift_delete, public.remove_or_cancel_shift; 1 triggers; 1 policies |
| `20261007021847_pos_schedule_fk_indexes.sql` | alter/grant/index/data migration |
| `20261007131539_create_workspace_self_serve_signup.sql` | functions: public.create_workspace |
| `20261007160000_crm_beo_charges.sql` | tables: public.crm_beo_charges; 3 policies |
| `20261007180000_account_deletion.sql` | tables: public.retained_time_entries, public.account_deletion_jobs; functions: app_hidden.is_safe_storage_deletion_path, app_hidden.dispatch_account_deletion_job, app_hidden.sweep_account_deletion_jobs, public.request_account_deletion |
| `20261007190000_account_deletion_fixes.sql` | functions: app_hidden.account_deletion_in_progress, app_hidden.enforce_task_update_scope, app_hidden.enforce_incident_update_scope, app_hidden.enforce_invite_revoke_only, app_hidden.enforce_shift_swap_update, app_hidden.enforce_staff_request_update, app_hidden.sync_inventory_item_update, public.request_account_deletion, app_hidden.sweep_account_deletion_jobs |
| `20261007191000_create_workspace_timezone_validation.sql` | functions: public.create_workspace |
| `20261007192000_venue_roster_rpc.sql` | functions: public.venue_roster |
| `20261007193000_apply_stripe_subscription_state.sql` | functions: public.apply_stripe_subscription_state |
| `20261007200621_restaurant_inventory_v2.sql` | tables: public.inventory_categories, public.inventory_subcategories, public.inventory_areas, public.inventory_sub_areas, public.inventory_stock, public.inventory_counts, public.inventory_count_items, public.inventory_history, app_hidden.inventory_operations; functions: app_hidden.seed_inventory_categories, app_hidden.inventory_seed_new_org, app_hidden.inventory_seed_new_venue, app_hidden.inventory_normalize_unit, app_hidden.inventory_metadata_scope, app_hidden.inventory_default_guard, app_hidden.inventory_item_v2_guard, app_hidden.inventory_item_archive_only, app_hidden.inventory_assert_manager, app_hidden.inventory_write_history, app_hidden.inventory_stock_version, app_hidden.inventory_definition_version, app_hidden.inventory_sync_total, app_hidden.inventory_legacy_quantity, public.inventory_set_stock, public.inventory_apply_action, public.inventory_start_count, public.inventory_save_count, public.inventory_dashboard; 13 triggers; 6 policies |
| `20261007201000_review_fixes_stripe_inventory_roster.sql` | functions: public.apply_stripe_subscription_state, app_hidden.inventory_legacy_quantity, public.venue_roster |
| `20261007202000_review_tenant_guards.sql` | tables: public.notification_reads; functions: app_hidden.guard_review_row_update, app_hidden.apply_approved_staff_request, app_hidden.guard_checklist_scope, app_hidden.guard_duplicate_pending_swap, app_hidden.notify_shift_assigned, app_hidden.apply_accepted_shift_swap, public.inventory_save_count, app_hidden.guard_floor_assignment_scope, app_hidden.guard_conversation_member_scope, public.venue_schedule_roster, app_hidden.guard_message_attachment, app_hidden.messages_derive_and_touch, app_hidden.guard_crm_links, app_hidden.crm_beos_sync_reservation, public.request_account_deletion, public.unregister_push_token, public.register_push_token, public.notification_feed_for_me, app_hidden.can_receive_notification, public.mark_notification_read_for_me, public.mark_all_notifications_read_for_me, app_hidden.prepare_storage_deletion_job_insert, app_hidden.process_storage_deletion_batch, public.publish_pos_schedule, app_hidden.is_safe_storage_deletion_path; 13 triggers; 3 policies |
| `20261007210000_fix_review_guard_record_fields.sql` | functions: app_hidden.guard_review_row_update, app_hidden.guard_crm_links |
| `20261010120000_retention_cleanup_in_database.sql` | functions: app_hidden.run_retention_cleanup |

This is a source declaration index, not a synthesized live schema. Later migrations replace functions and drop/rename some tables or columns. Counts are navigation aids; findings use final applicable definitions. CI stubs are not assumed to emulate production Auth/Storage completely.

Edge Function entrypoints reviewed:

- `supabase/functions/account-deletion-worker/index.ts`
- `supabase/functions/ai-assistant/index.ts`
- `supabase/functions/crm-send-email/index.ts`
- `supabase/functions/device-attestation/index.ts`
- `supabase/functions/documents-upload/index.ts`
- `supabase/functions/gusto-oauth/index.ts`
- `supabase/functions/notifications-dispatch/index.ts`
- `supabase/functions/notifications-send/index.ts`
- `supabase/functions/quickbooks-oauth/index.ts`
- `supabase/functions/square-oauth/index.ts`
- `supabase/functions/stripe-create-checkout/index.ts`
- `supabase/functions/stripe-create-portal/index.ts`
- `supabase/functions/stripe-webhook/index.ts`
- `supabase/functions/toast-pos/index.ts`

## Appendix D. Reconciliation of the concurrent audit draft

A separate Antigravity-authored AUDIT_FINDINGS.md appeared during this audit (27,678 bytes before sanitization). It contained 29 findings and literal credential values. The original content is retained below **with credential values redacted** so the other work is not silently discarded. Its totals, coverage claims and recommendations are superseded; only the main VW table counts as this audit's findings. Presence of ignored local credential files does not establish a current Git leak or credential compromise. No private file was deleted or modified.

| Antigravity ID | Verification result | Disposition / combined finding | Evidence in current checkout |
|---|---|---|---|
| SEC-01 | Needs verification | Not retained as Critical. credentials.json exists and is ignored/untracked; contents/credential validity were not independently verified. Literal credential value removed. Local handling/exposure is open question 11. | [.gitignore:105-106](C:/Users/lwhob/OneDrive/Downloads/a0-project/.gitignore:105) |
| SEC-02 | Needs verification | Not retained as Critical. Private-key file presence and ignore status verified; no current Git publication, exploit or credential validity demonstrated. See open question 11. | [.gitignore:27](C:/Users/lwhob/OneDrive/Downloads/a0-project/.gitignore:27) |
| SEC-03 | Needs verification | Not retained as Critical. .env.local exists and is ignored/untracked; no contents were independently dumped. Literal secret value removed. See open question 11. | [.gitignore:48-51](C:/Users/lwhob/OneDrive/Downloads/a0-project/.gitignore:48) |
| SEC-04 | Merged / requalified | Retained at Medium as VW-024 after origin equality check. Actual production designation remains unverified. | [apps/mobile/env/development.json:2](C:/Users/lwhob/OneDrive/Downloads/a0-project/apps/mobile/env/development.json:2)<br>[apps/mobile/env/production.json:2](C:/Users/lwhob/OneDrive/Downloads/a0-project/apps/mobile/env/production.json:2)<br>[apps/mobile/lib/main_development.dart:1-4](C:/Users/lwhob/OneDrive/Downloads/a0-project/apps/mobile/lib/main_development.dart:1) |
| DAT-01 | Merged / requalified | Retained at High as VW-003, with final RPC/guard source checked. | [supabase/migrations/20261002235927_floor_schema.sql:152-169,302-350](C:/Users/lwhob/OneDrive/Downloads/a0-project/supabase/migrations/20261002235927_floor_schema.sql:152)<br>[supabase/migrations/20261007202000_review_tenant_guards.sql:194-229](C:/Users/lwhob/OneDrive/Downloads/a0-project/supabase/migrations/20261007202000_review_tenant_guards.sql:194) |
| DAT-02 | Merged / requalified | Split into specific overlap/capacity/BEO findings VW-003, VW-019 and VW-020. Same venue alone is not an exclusive booking resource. | [supabase/migrations/20261002235927_floor_schema.sql:152-169,302-350](C:/Users/lwhob/OneDrive/Downloads/a0-project/supabase/migrations/20261002235927_floor_schema.sql:152)<br>[supabase/migrations/20261007202000_review_tenant_guards.sql:194-229](C:/Users/lwhob/OneDrive/Downloads/a0-project/supabase/migrations/20261007202000_review_tenant_guards.sql:194)<br>[supabase/migrations/20261002235927_floor_schema.sql:77,302-350](C:/Users/lwhob/OneDrive/Downloads/a0-project/supabase/migrations/20261002235927_floor_schema.sql:77)<br>[supabase/migrations/20261002235847_guests_reservations_schema.sql:144](C:/Users/lwhob/OneDrive/Downloads/a0-project/supabase/migrations/20261002235847_guests_reservations_schema.sql:144)<br>[supabase/migrations/20261007202000_review_tenant_guards.sql:423-437](C:/Users/lwhob/OneDrive/Downloads/a0-project/supabase/migrations/20261007202000_review_tenant_guards.sql:423)<br>[supabase/migrations/20261002235847_guests_reservations_schema.sql:179-208](C:/Users/lwhob/OneDrive/Downloads/a0-project/supabase/migrations/20261002235847_guests_reservations_schema.sql:179) |
| MEM-01 | Needs verification | Not confirmed. A single-subscription StreamController calls onListen synchronously before a subscriber can cancel; channel assignment is synchronous. A preceding initialization exception is a different scenario, not demonstrated. | [apps/mobile/lib/features/chat/data/chat_repository.dart:32-58](C:/Users/lwhob/OneDrive/Downloads/a0-project/apps/mobile/lib/features/chat/data/chat_repository.dart:32) |
| MEM-02 | Rejected as stated | Rejected as stated. notifications_providers.dart:29-31 owns service disposal; NotificationTapService.start is idempotent. GoRouter lifetime is separately VW-026. | [apps/mobile/lib/features/notifications/application/notifications_providers.dart:29-32](C:/Users/lwhob/OneDrive/Downloads/a0-project/apps/mobile/lib/features/notifications/application/notifications_providers.dart:29) |
| COR-01 | Merged / requalified | Retained at Medium as VW-013. Unhandled async error is not proof of a whole-app/UI-thread crash. | [apps/mobile/lib/features/guests_reservations/presentation/reservations_screen.dart:54-58,141-148](C:/Users/lwhob/OneDrive/Downloads/a0-project/apps/mobile/lib/features/guests_reservations/presentation/reservations_screen.dart:54) |
| COR-02 | Needs verification | Needs verification; not counted separately. Thread lacks didUpdateWidget but current list/back flow unmounts the old thread. No current in-place conversation-change trigger was demonstrated. | [apps/mobile/lib/features/chat/presentation/chat_screen.dart:14-20,77-79,109-137](C:/Users/lwhob/OneDrive/Downloads/a0-project/apps/mobile/lib/features/chat/presentation/chat_screen.dart:14)<br>[apps/mobile/lib/features/chat/application/chat_providers.dart:22-23](C:/Users/lwhob/OneDrive/Downloads/a0-project/apps/mobile/lib/features/chat/application/chat_providers.dart:22) |
| PERF-01 | Merged / requalified | Retained at Medium as VW-027; actual high-volume cost is unprofiled. | [apps/mobile/lib/features/guests_reservations/data/guests_reservations_repository.dart:111-137](C:/Users/lwhob/OneDrive/Downloads/a0-project/apps/mobile/lib/features/guests_reservations/data/guests_reservations_repository.dart:111)<br>[apps/mobile/lib/features/guests_reservations/presentation/reservations_screen.dart:104-117](C:/Users/lwhob/OneDrive/Downloads/a0-project/apps/mobile/lib/features/guests_reservations/presentation/reservations_screen.dart:104) |
| NAV-01 | Merged / requalified | Requalified as VW-026, including missing provider disposal. Exact route/history loss needs a lifecycle test. | [apps/mobile/lib/app/router.dart:50-69](C:/Users/lwhob/OneDrive/Downloads/a0-project/apps/mobile/lib/app/router.dart:50)<br>[apps/mobile/lib/features/employee/presentation/employee_home_screen.dart:59-63](C:/Users/lwhob/OneDrive/Downloads/a0-project/apps/mobile/lib/features/employee/presentation/employee_home_screen.dart:59) |
| COR-03 | Rejected as stated | Rejected as stated. Dart DateTime compares instants across UTC/local representations correctly; mixing is not inherently an offset bug. Venue-zone interpretation is VW-001. | [apps/mobile/lib/features/time_clock/domain/time_entry.dart:90-117](C:/Users/lwhob/OneDrive/Downloads/a0-project/apps/mobile/lib/features/time_clock/domain/time_entry.dart:90) |
| COR-04 | Needs verification | Not confirmed in current flow. Task updatedAt is parsed from PostgreSQL timestamptz and queued serialization retains its instant. A local DateTime passed directly would warrant explicit UTC normalization, but that failing path was not demonstrated. | [apps/mobile/lib/features/tasks/domain/operational_task.dart:60-76](C:/Users/lwhob/OneDrive/Downloads/a0-project/apps/mobile/lib/features/tasks/domain/operational_task.dart:60)<br>[apps/mobile/lib/features/tasks/application/tasks_providers.dart:25-39,50-60](C:/Users/lwhob/OneDrive/Downloads/a0-project/apps/mobile/lib/features/tasks/application/tasks_providers.dart:25)<br>[apps/mobile/lib/features/tasks/data/tasks_repository.dart:90-110](C:/Users/lwhob/OneDrive/Downloads/a0-project/apps/mobile/lib/features/tasks/data/tasks_repository.dart:90) |
| COR-05 | Intent / product scope | API is unused, but the asserted unread badge is absent from current Conversation/UI. Record as dormant read-tracking capability/open product scope, not a proven stuck badge. | [apps/mobile/lib/features/chat/data/chat_repository.dart:126-146](C:/Users/lwhob/OneDrive/Downloads/a0-project/apps/mobile/lib/features/chat/data/chat_repository.dart:126)<br>[apps/mobile/lib/features/chat/presentation/chat_screen.dart:53-80](C:/Users/lwhob/OneDrive/Downloads/a0-project/apps/mobile/lib/features/chat/presentation/chat_screen.dart:53) |
| PERF-02 | Merged / requalified | Retained at Low as VW-046; timer is cancelled correctly and cost is unprofiled. | [apps/mobile/lib/features/time_clock/presentation/time_clock_screen.dart:24-35](C:/Users/lwhob/OneDrive/Downloads/a0-project/apps/mobile/lib/features/time_clock/presentation/time_clock_screen.dart:24) |
| PERF-03 | Intent / product scope | Not retained as a separate defect. Provider<void> activation/listeners are a deliberate Riverpod pattern; watching them does not prove every dependency change rebuilds MaterialApp. Router recreation is separately VW-026. | [apps/mobile/lib/app/app.dart:42-61](C:/Users/lwhob/OneDrive/Downloads/a0-project/apps/mobile/lib/app/app.dart:42) |
| SEC-05 | Rejected as stated | Rejected as secret finding. Supabase anon/public keys and Sentry DSN are client-visible configuration; authorization depends on RLS and backend role checks. | [codemagic.yaml:24-28](C:/Users/lwhob/OneDrive/Downloads/a0-project/codemagic.yaml:24) |
| SEC-06 | Intent / product scope | Not counted as standalone security breach. Observe mode is explicitly documented; sensitive-operation enforcement is an open scope/validation question. Challenge fail-open defect is VW-038. | [supabase/functions/device-attestation/index.ts:1-3,167,346](C:/Users/lwhob/OneDrive/Downloads/a0-project/supabase/functions/device-attestation/index.ts:1)<br>[apps/mobile/lib/core/security/README.md:13-14](C:/Users/lwhob/OneDrive/Downloads/a0-project/apps/mobile/lib/core/security/README.md:13) |
| MEM-03 | Rejected as stated | Rejected. TransformationController lives in LiveFloorMap state and is disposed (live_floor_map.dart:33-40). | [apps/mobile/lib/features/floor/presentation/live_floor_map.dart:32-39](C:/Users/lwhob/OneDrive/Downloads/a0-project/apps/mobile/lib/features/floor/presentation/live_floor_map.dart:32) |
| DAT-03 | Merged / requalified | Retained in VW-023 with actual memberships semantics; no venue_members table is assumed. | [supabase/migrations/20261006160946_staff_section_and_reservation_assignment.sql:7-11](C:/Users/lwhob/OneDrive/Downloads/a0-project/supabase/migrations/20261006160946_staff_section_and_reservation_assignment.sql:7)<br>[supabase/migrations/20261002175340_schedules_schema.sql:1-21](C:/Users/lwhob/OneDrive/Downloads/a0-project/supabase/migrations/20261002175340_schedules_schema.sql:1) |
| DAT-04 | Intent / product scope | Not retained as a bug without operational policy. Deletion unassignment is intentional; notification/reassignment behavior is open question 3. | [supabase/migrations/20261007190000_account_deletion_fixes.sql:389,413-416](C:/Users/lwhob/OneDrive/Downloads/a0-project/supabase/migrations/20261007190000_account_deletion_fixes.sql:389) |
| NAV-02 | Needs verification | Needs verification; no failed navigation was reproduced. Tenant/object routing is the concrete VW-010 issue. | [apps/mobile/lib/app/router.dart:395-405](C:/Users/lwhob/OneDrive/Downloads/a0-project/apps/mobile/lib/app/router.dart:395) |
| UI-01 | Needs verification | Needs verification; not counted separately. The busy flag is set synchronously, but the handler has no re-entry guard and button disabling requires a rebuild. A second callback before that rebuild could duplicate location/RPC calls; the one-open-punch unique index prevents two persisted open punches. No same-frame widget/device reproduction was run. The earlier categorical rejection is superseded by this narrower assessment. | [apps/mobile/lib/features/time_clock/presentation/time_clock_screen.dart:38-50,350-353](C:/Users/lwhob/OneDrive/Downloads/a0-project/apps/mobile/lib/features/time_clock/presentation/time_clock_screen.dart:38)<br>[supabase/migrations/20261002233921_time_clock_schema.sql:69-71](C:/Users/lwhob/OneDrive/Downloads/a0-project/supabase/migrations/20261002233921_time_clock_schema.sql:69) |
| BUILD-01 | Merged / requalified | Retained as VW-045 with actual locked versions (js 0.6.7, flutter_secure_storage_macos 3.1.3), not the draft's stale versions. | [apps/mobile/pubspec.lock:337-344,579-586](C:/Users/lwhob/OneDrive/Downloads/a0-project/apps/mobile/pubspec.lock:337)<br>[apps/mobile/pubspec.yaml:25-26](C:/Users/lwhob/OneDrive/Downloads/a0-project/apps/mobile/pubspec.yaml:25) |
| BUILD-02 | Rejected as stated | Rejected. iOS uses checked-in Swift Package Manager setup. Missing CocoaPods Podfile alone is not a defect. | [apps/mobile/ios/Runner.xcodeproj/project.pbxproj:173-174,649-659](C:/Users/lwhob/OneDrive/Downloads/a0-project/apps/mobile/ios/Runner.xcodeproj/project.pbxproj:173) |
| A11Y-01 | Rejected as stated | Rejected. LiveFloorMap table widgets have labelled Semantics (live_floor_map.dart:140-143); specific annotation control gaps are VW-039. | [apps/mobile/lib/features/floor/presentation/live_floor_map.dart:140-143](C:/Users/lwhob/OneDrive/Downloads/a0-project/apps/mobile/lib/features/floor/presentation/live_floor_map.dart:140) |
| CODE-01 | Rejected as stated | Rejected as runtime bug. subscription force unwrap is dominated by a non-null value derived from that subscription; no unsafe execution path was shown. | [apps/mobile/lib/features/billing/presentation/billing_screen.dart:69-86](C:/Users/lwhob/OneDrive/Downloads/a0-project/apps/mobile/lib/features/billing/presentation/billing_screen.dart:69) |
| CODE-02 | Rejected as stated | Rejected. Referenced offline_mutation_queue.dart does not exist in this checkout; implemented controller differs. No cited TODO/backoff defect was verified. | [apps/mobile/lib/core/offline/offline_queue_controller.dart:1-7,159-197](C:/Users/lwhob/OneDrive/Downloads/a0-project/apps/mobile/lib/core/offline/offline_queue_controller.dart:1) |

Other corrections to the draft: Riverpod annotation is not a declared dependency; locked GoRouter is 14.8.1; there are 14 Edge entrypoints; packages/api is not present; the live PostgreSQL version and applied RLS could not be verified. Current checks passed 202 Flutter tests, rather than proving production integration behavior.

<details>
<summary>Sanitized concurrent draft — superseded, not part of the finding totals</summary>

~~~~text
# Comprehensive Read-Only Audit Findings: Venue Wrangler Mobile & Database

**Audit Date:** October 10, 2026  
**Auditor:** Antigravity Principal Engineering Agent  
**Repository:** `lwhobley/venuewrangler` (`c:\Users\lwhob\OneDrive\Downloads\a0-project`)  
**Scope:** Full repository audit covering `apps/mobile` (Flutter/Dart), backing database (`supabase/migrations`), platform configurations (Android, iOS, CI), and environment/secret hygiene.  
**Mode:** Strictly Read-Only (no modifications made, no destructive commands run, no database write queries executed).

---

## 1. Executive Summary

### 1.1 Issue Breakdown by Severity

| Severity | Count | Criteria |
| :--- | :--- | :--- |
| **Critical** | **5** | Clear risk of data loss, credential/secret compromise, production outage, or broken reservations/payments |
| **High** | **7** | Severe memory leaks, unhandled exceptions in primary workflows, missing DB integrity constraints, or cross-environment bleed |
| **Medium** | **11** | Inconsistent timezone models, optimistic concurrency failures, unread message state bugs, aggressive polling rebuilds, and root widget churn |
| **Low** | **6** | Dead code, deprecated SDK dependencies, missing static semantics labels, and minor style inconsistencies |
| **Total** | **29** | **Total Audited Findings** |

### 1.2 Issue Breakdown by Category

| Category | Count | Primary Areas |
| :--- | :--- | :--- |
| **Security & Secrets** | 6 | Plaintext certificates, live production credentials, shared prod/dev database configs, unencrypted private keys |
| **Memory & Lifecycle** | 4 | Realtime stream listeners, missing controller disposal, unmanaged service subscriptions, whole-screen timers |
| **Correctness & Data Integrity** | 7 | Timezone parsing mismatches, optimistic concurrency string formatting, uncaught repository exceptions, unread chat status |
| **Database & Invariants** | 4 | Missing table exclusion constraints for double-booking, legacy schema drift, unconstrained assignment cascades |
| **State & Navigation** | 3 | GoRouter recreation on auth changes, side-effect provider watching in root `build()`, stream resubscription gaps |
| **Performance & Scale** | 3 | 395-day unbounded reservation pagination, whole-tree timer rebuilds, high-frequency offline sync triggers |
| **Platform & Build Config** | 2 | Discontinued package warnings (`js`, `flutter_secure_storage_macos`), missing checked-in iOS Podfile |

### 1.3 Architecture Summary (Phase 1 Synthesis)

- **Client App (`apps/mobile`)**: A single Flutter cross-platform mobile application supporting both iOS and Android. Built with Flutter 3.47.5 and Dart 3.13.4 (`sdk: ">=3.5.0 <4.0.0"`).
- **Entry Points**: Flavored multi-entry architecture:
  - `apps/mobile/lib/main_development.dart` (loads `env/development.json`)
  - `apps/mobile/lib/main_staging.dart` (loads `env/staging.json`)
  - `apps/mobile/lib/main_production.dart` (loads `env/production.json`)
- **State Management & DI**: Riverpod 2.6.1 (`flutter_riverpod`, `riverpod_annotation`). State is organized into feature-sliced directories with `domain`, `data`, `application`, and `presentation` layers.
- **Routing**: `go_router` 14.6.2 with a single root router (`apps/mobile/lib/app/router.dart`) managing authentication guards, role-based screen routing (manager vs. employee view), and push-notification deep links.
- **Backend & Storage**: Supabase (Auth, PostgreSQL 15 with RLS, Realtime websockets, Storage, and Deno Edge Functions). Firebase Cloud Messaging is utilized exclusively for Android push tokens; APNs handles iOS push tokens natively.
- **Adjacent Workspaces**:
  - `supabase/`: 65 sequential SQL migrations, 13 Deno edge functions, 38 pgTAP test suites.
  - `packages/marketing`: Static Vite + React landing page.
  - `packages/api`: Legacy Node.js / Prisma server (deprecated).
  - `site/`: Static Cloudflare Pages site.

---

## 2. Coverage & Audit Scope

### 2.1 Complete List of Files Audited

All **230 Dart files** in `apps/mobile` were reviewed line-by-line without sampling:

#### Core & App Architecture (16 files)
- `apps/mobile/lib/main_development.dart`
- `apps/mobile/lib/main_staging.dart`
- `apps/mobile/lib/main_production.dart`
- `apps/mobile/lib/bootstrap.dart`
- `apps/mobile/lib/app/app.dart`
- `apps/mobile/lib/app/router.dart`
- `apps/mobile/lib/app/theme.dart`
- `apps/mobile/lib/app/intro_video_screen.dart`
- `apps/mobile/lib/core/auth/auth_providers.dart`
- `apps/mobile/lib/core/config/app_config.dart`
- `apps/mobile/lib/core/errors/error_logger.dart`
- `apps/mobile/lib/core/location/location_service.dart`
- `apps/mobile/lib/core/offline/offline_mutation_queue.dart`
- `apps/mobile/lib/core/offline/offline_queue_connectivity.dart`
- `apps/mobile/lib/core/security/app_attest_providers.dart`
- `apps/mobile/lib/core/storage/secure_storage_service.dart`

#### Feature Modules (169 files in `apps/mobile/lib/features/`)
- **ai**: `application/ai_providers.dart`, `data/ai_repository.dart`, `domain/ai_suggestion.dart`, `presentation/ai_sheet.dart`
- **billing**: `application/billing_providers.dart`, `data/billing_repository.dart`, `domain/subscription.dart`, `presentation/billing_screen.dart`
- **chat**: `application/chat_providers.dart`, `data/chat_repository.dart`, `domain/conversation.dart`, `domain/message.dart`, `presentation/chat_screen.dart`, `presentation/conversations_screen.dart`
- **checklists**: `application/checklists_providers.dart`, `data/checklists_repository.dart`, `domain/checklist.dart`, `domain/checklist_item.dart`, `presentation/checklist_run_screen.dart`, `presentation/checklists_screen.dart`
- **crm**: `application/crm_providers.dart`, `data/crm_repository.dart`, `domain/crm_lead.dart`, `presentation/crm_leads_screen.dart`, `presentation/lead_detail_screen.dart`
- **dashboard**: `application/dashboard_providers.dart`, `presentation/manager_dashboard_screen.dart`, `presentation/employee_dashboard_screen.dart`
- **employee**: `application/employee_providers.dart`, `presentation/employee_schedule_screen.dart`, `presentation/my_profile_screen.dart`
- **floor**: `application/floor_providers.dart`, `data/floor_repository.dart`, `domain/editor_table.dart`, `domain/floor_plan.dart`, `domain/floor_table.dart`, `domain/table_status_style.dart`, `presentation/floor_plan_screen.dart`, `presentation/floor_editor_screen.dart`
- **guests_reservations**: `application/guests_reservations_providers.dart`, `data/guests_reservations_repository.dart`, `domain/guest.dart`, `domain/reservation.dart`, `presentation/guests_screen.dart`, `presentation/guest_detail_screen.dart`, `presentation/reservations_screen.dart`, `presentation/reservation_detail_screen.dart`
- **incidents**: `application/incidents_providers.dart`, `data/incidents_repository.dart`, `domain/incident.dart`, `presentation/incidents_screen.dart`, `presentation/report_incident_screen.dart`
- **insights**: `application/insights_providers.dart`, `data/insights_repository.dart`, `domain/insight_metric.dart`, `presentation/insights_screen.dart`
- **integrations**: `application/integrations_providers.dart`, `data/integrations_repository.dart`, `domain/integration_connection.dart`, `presentation/integrations_screen.dart`
- **inventory**: `application/inventory_providers.dart`, `data/inventory_repository.dart`, `domain/inventory_item.dart`, `domain/inventory_count.dart`, `presentation/inventory_screen.dart`, `presentation/count_sheet_screen.dart`
- **media**: `application/media_providers.dart`, `data/media_repository.dart`, `domain/media_asset.dart`, `presentation/media_library_screen.dart`
- **notifications**: `application/notifications_providers.dart`, `data/notifications_repository.dart`, `domain/app_notification.dart`, `presentation/notifications_screen.dart`
- **organizations**: `application/organizations_providers.dart`, `application/workspace_provisioning.dart`, `data/organizations_repository.dart`, `domain/organization.dart`, `presentation/create_organization_screen.dart`, `presentation/organization_settings_screen.dart`
- **pos**: `application/pos_providers.dart`, `data/pos_repository.dart`, `domain/pos_ticket.dart`, `domain/pos_item.dart`, `domain/pos_tender.dart`, `presentation/pos_management_screen.dart`
- **schedules**: `application/schedules_providers.dart`, `data/schedules_repository.dart`, `domain/shift.dart`, `domain/shift_swap_request.dart`, `presentation/schedules_screen.dart`, `presentation/schedule_editor_screen.dart`, `presentation/swap_requests_screen.dart`
- **settings**: `application/settings_providers.dart`, `presentation/settings_screen.dart`, `presentation/security_screen.dart`, `presentation/appearance_screen.dart`
- **shift_mode**: `application/shift_mode_providers.dart`, `presentation/active_shift_overlay.dart`, `presentation/shift_briefing_screen.dart`
- **tasks**: `application/tasks_providers.dart`, `data/tasks_repository.dart`, `domain/task.dart`, `domain/task_status.dart`, `presentation/task_board_screen.dart`, `presentation/task_list_screen.dart`
- **time_clock**: `application/time_clock_providers.dart`, `data/time_clock_repository.dart`, `domain/time_entry.dart`, `domain/time_card.dart`, `presentation/time_clock_screen.dart`, `presentation/clock_board_screen.dart`
- **venues**: `application/venues_providers.dart`, `data/venues_repository.dart`, `domain/venue.dart`, `presentation/select_venue_screen.dart`, `presentation/venue_settings_screen.dart`
- **workforce**: `application/workforce_providers.dart`, `data/workforce_repository.dart`, `domain/team_member.dart`, `domain/wage_rate.dart`, `presentation/team_members_screen.dart`, `presentation/member_detail_screen.dart`

#### Test Suites (45 files in `apps/mobile/test/`)
- All 45 unit and widget test files across `auth`, `offline`, `router`, and individual feature tests.

#### Platform & Configuration Files Audited
- Android: `apps/mobile/android/app/build.gradle.kts`, `apps/mobile/android/app/src/main/AndroidManifest.xml`, `apps/mobile/android/settings.gradle.kts`
- iOS: `apps/mobile/ios/Runner/Info.plist`
- Configuration & Secrets: `apps/mobile/pubspec.yaml`, `credentials.json`, `keys/private-key.pem`, `.env`, `.env.local`, `apps/mobile/env/development.json`, `apps/mobile/env/production.json`, `codemagic.yaml`, `.github/workflows/flutter-ci.yml`, `.github/workflows/supabase-ci.yml`
- Database: All 65 SQL migration files in `supabase/migrations/` (from `20261002154114_tasks_schema.sql` through `20261007202000_review_tenant_guards.sql`).

### 2.2 Unreviewed Components / Verification Constraints
1. **Live Local PostgreSQL Container**: The local Supabase Docker daemon (`localhost:54322`) was not running during the audit. Verification of runtime database behavior was performed via static analysis of the 65 migration files and pgTAP test definitions.
2. **Neon Cloud DB Schema**: Inspected via Neon MCP tool (`autumn-fire-26190369`). This branch contains legacy Prisma schema (PascalCase tables `User`, `Booking`, etc.), confirming that the active schema has migrated entirely to Supabase managed PostgreSQL (`public.guests`, `public.reservations`, `public.floor_tables`, etc.).

---

## 3. Findings Table

| ID | Severity | Category | File Path & Line Number(s) | Description | Why It Matters / How It Could Fail | Suggested Fix | Effort |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **SEC-01** | **Critical** | Security & Secrets | `credentials.json:5` | Plaintext iOS distribution certificate password ([REDACTED]) committed to disk | Anyone with read access to the project directory or compromised developer backup can extract the production distribution signing certificate (`credentials/ios/dist-cert.p12`). | Remove plaintext password from `credentials.json`; load via environment variable in CI / Codemagic secrets. | S |
| **SEC-02** | **Critical** | Security & Secrets | `keys/private-key.pem:1-28` | Plaintext 2048-bit RSA private key stored unencrypted on local filesystem | Compromise of local environment exposes cryptographic private key used for code signing or auth validation. | Remove private key from local workspace; store exclusively in hardware token or secret manager. | S |
| **SEC-03** | **Critical** | Security & Secrets | `.env.local:14-24` | Live production Cloud Run configuration with unredacted Stripe secret key, AWS secret access key, Supabase direct DB password, and Resend API key | Developer machine compromise or accidental sync exposes production database password ([REDACTED]), live Stripe secret (`sk_live_...`), and AWS credentials. | Remove live secrets from developer workstation; use Doppler / Google Secret Manager with ephemeral access. | S |
| **SEC-04** | **Critical** | Security & Secrets | `apps/mobile/env/development.json:2-3` vs `apps/mobile/env/production.json:2-3` | Development environment points to identical Supabase production instance (`puttwjwmwrzmhpsjykuj`) | Testing or running development builds directly mutates and queries production tables, creating risk of live data pollution or accidental data deletion. | Provision a dedicated Supabase staging/dev project and point `development.json` to it. | M |
| **DAT-01** | **Critical** | Database & Invariants | `supabase/migrations/20261002235927_floor_schema.sql:152-165` | Missing PostgreSQL exclusion constraint on `floor_table_assignments` | Multiple guests can be concurrently booked or seated at the exact same table for overlapping time windows because overlap validation is not enforced at the database layer. | Add `btree_gist` extension and `EXCLUDE USING gist (table_id WITH =, tstzrange(starts_at, ends_at) WITH &&) WHERE (released_at IS NULL)`. | M |
| **DAT-02** | **High** | Database & Invariants | `supabase/migrations/20261002235847_guests_reservations_schema.sql:136-170` | No table capacity constraint or overlapping reservation constraint on `reservations` table | High-traffic booking periods can result in double bookings across identical venues/tables under concurrent API or mobile submissions. | Enforce database-level booking capacity checks via transaction triggers or table assignment constraints. | M |
| **MEM-01** | **High** | Memory & Lifecycle | `apps/mobile/lib/features/chat/data/chat_repository.dart:33-56` | `late final RealtimeChannel channel` accessed in `onCancel` before initialization | If a listener cancels or is disposed before `onListen` runs, accessing `channel` throws an unhandled `LateInitializationError: Field 'channel' has not been initialized.` | Change to `RealtimeChannel? channel = null;` and null-check in `onCancel`: `if (channel != null) unawaited(...)`. | S |
| **MEM-02** | **High** | Memory & Lifecycle | `apps/mobile/lib/app/router.dart:415-427` | `notificationTapServiceProvider.start(...)` invoked without registering `ref.onDispose` cleanup | Orphaned stream listeners and method channel callbacks remain active across provider re-evaluations, leaking memory and invoking handlers multiple times. | Register `ref.onDispose(() => ref.read(notificationTapServiceProvider).dispose());`. | S |
| **COR-01** | **High** | Correctness & Data Integrity | `apps/mobile/lib/features/guests_reservations/presentation/reservations_screen.dart:55-58` | Unhandled network/database exception on `assignReservation` | If assignment fails (e.g., connection drop or permission failure), an unhandled exception bubbles up, crashing the UI thread without user feedback. | Wrap in `try/catch`, display user-facing `SnackBar`, and revert optimistic UI. | S |
| **COR-02** | **High** | Correctness & Data Integrity | `apps/mobile/lib/features/chat/presentation/chat_screen.dart:109-118` | `_messageChanges` stream subscription ignores `didUpdateWidget` | If `widget.conversationId` changes while viewing the screen, the listener remains bound to the previous conversation, missing new messages. | Implement `didUpdateWidget`, cancel previous stream subscription, and re-subscribe to the new `conversationId`. | S |
| **PERF-01** | **High** | Performance & Scale | `apps/mobile/lib/features/guests_reservations/data/guests_reservations_repository.dart:117-137` | Unbounded reservation pagination loop querying a 395-day window on screen load | When opening reservations, the app synchronously queries 30 days past to 365 days future in 500-item chunks. For busy venues, this executes dozens of queries and loads tens of thousands of records into RAM. | Restrict default query window to current day or week; implement lazy pagination by selected date. | M |
| **NAV-01** | **High** | State & Navigation | `apps/mobile/lib/app/router.dart:50-67` | `routerProvider` instantiates a new `GoRouter` and `GlobalKey` whenever auth or venue state updates | Recreating `GoRouter` drops the active navigator state, resets navigation history, and causes jarring UI reloads during auth state transitions. | Convert `routerProvider` to a singleton router instance utilizing `refreshListenable` with a dedicated Riverpod notifier. | M |
| **COR-03** | **Medium** | Correctness & Data Integrity | `apps/mobile/lib/features/guests_reservations/domain/reservation.dart:44-77` | Mixed timezone representation: `reservationTime` parsed with `.toLocal()`, while other dates parsed as UTC | Calculations comparing `reservationTime` against `seatedAt`, `completedAt`, or `cancelledAt` mix local and UTC times, causing subtle offset bugs. | Standardize all domain date fields to UTC `DateTime.parse(...)` and format to local only in the presentation layer. | S |
| **COR-04** | **Medium** | Correctness & Data Integrity | `apps/mobile/lib/features/tasks/data/tasks_repository.dart:99` | Optimistic concurrency check queries `expectedUpdatedAt.toIso8601String()` without UTC normalization | If `expectedUpdatedAt` is local, `.toIso8601String()` omits the timezone offset/`Z`, causing PostgREST string equality against PostgreSQL `timestamptz` to fail. | Use `expectedUpdatedAt.toUtc().toIso8601String()`. | S |
| **COR-05** | **Medium** | Correctness & Data Integrity | `apps/mobile/lib/features/chat/data/chat_repository.dart:127` vs `chat_screen.dart` | `markConversationRead` is defined and implemented against `conversation_reads`, but never invoked anywhere in presentation | Opening and reading messages in a conversation never clears the unread badge in the database or UI. | Call `ref.read(chatRepositoryProvider).markConversationRead(conversationId: ...)` when the chat thread is mounted. | S |
| **PERF-02** | **Medium** | Performance & Scale | `apps/mobile/lib/features/time_clock/presentation/time_clock_screen.dart:27-29` | 1-second `Timer.periodic` unconditionally calls `setState(() {})` on the entire 590-line screen | Triggers continuous whole-tree widget rebuilds every second regardless of active tab or clock-in state, causing high CPU and battery drain. | Isolate the running timer display into a dedicated self-updating leaf widget. | S |
| **PERF-03** | **Medium** | Performance & Scale | `apps/mobile/lib/app/app.dart:44-59` | 6 side-effect trigger providers watched inside root `VenueWranglerApp.build()` | State changes on `offlineQueueConnectivityProvider`, `appAttestTriggerProvider`, etc. trigger full re-evaluations of `MaterialApp.router`. | Move side-effect activations into `bootstrap.dart` or wrap in a dedicated headless listener widget. | S |
| **SEC-05** | **Medium** | Security & Secrets | `codemagic.yaml:12-16` | Static Sentry DSN and Supabase anon key configured directly in CI build script | Anon keys and monitoring endpoints are visible to anyone with access to CI configuration. | Inject CI build variables via encrypted Codemagic environment variable groups. | S |
| **SEC-06** | **Medium** | Security & Secrets | `apps/mobile/lib/core/security/app_attest_providers.dart:34` | App Attest evaluation set to `observe` mode in production config | In observe mode, devices failing hardware attestation checks are logged but not rejected, allowing modified client runtimes to communicate with Supabase. | Enforce hardware attestation verification on critical sensitive API endpoints once baseline is validated. | M |
| **MEM-03** | **Medium** | Memory & Lifecycle | `apps/mobile/lib/features/floor/presentation/floor_plan_screen.dart:140-155` | `TransformationController` allocated without explicit cleanup on conditional rebuilds | Multiple pan/zoom controllers can be created if layout structure changes dynamically. | Ensure single persistent controller initialized in `initState` and cleaned up in `dispose`. | S |
| **DAT-03** | **Medium** | Database & Invariants | `supabase/migrations/20261006160946_staff_section_and_reservation_assignment.sql:8` | `reservations.assigned_to` foreign key does not validate venue membership at the DB level | A manager could theoretically assign a reservation to a user who is not a member of the reservation's venue. | Add a validation trigger verifying `assigned_to` exists in `venue_members` for the given `venue_id`. | S |
| **DAT-04** | **Medium** | Database & Invariants | `supabase/migrations/20261007190000_account_deletion_fixes.sql:416` | User deletion nullifies `reservations.assigned_to` without notifying team or reassigning | Deleted staff leaves active reservations silently unassigned without alert. | Trigger an operational notification or log entry when a deleted user's reservations are unassigned. | S |
| **NAV-02** | **Medium** | State & Navigation | `apps/mobile/lib/app/router.dart:402-406` | Pending push route consumed before navigation verification | If navigation fails or destination route is locked, pending route is cleared and user is left on current screen. | Clear `pendingNotificationRouteProvider` only after successful route transition. | S |
| **UI-01** | **Medium** | State, Navigation & UI | `apps/mobile/lib/features/time_clock/presentation/time_clock_screen.dart:38-50` | Double-tap race condition on `_handleClockIn` | If user rapidly taps "Clock In", two geolocation fixes and API calls can fire simultaneously before `_isProcessing` updates. | Disable button immediately using a synchronous flag or `ref.read` debouncer. | S |
| **BUILD-01** | **Low** | Platform & Build Config | `apps/mobile/pubspec.yaml:70-75` | Discontinued dependencies: `js` (v0.7.1) and `flutter_secure_storage_macos` (v3.0.1) | Discontinued packages will not receive security patches or future Flutter engine updates. | Migrate from `package:js` to Dart 3.3+ `dart:js_interop`; update secure storage package. | S |
| **BUILD-02** | **Low** | Platform & Build Config | `apps/mobile/ios/` | iOS `Podfile` omitted from version control (generated on `flutter build`) | CI runners or team members on different CocoaPods versions may generate diverging Podfiles and build configurations. | Commit standard Flutter `ios/Podfile` with pinned platform deployment target (iOS 15.0+). | S |
| **A11Y-01** | **Low** | State, Navigation & UI | `apps/mobile/lib/features/floor/presentation/floor_plan_screen.dart:210-245` | Custom painted tables lack accessible `Semantics` widgets | Screen readers cannot discover or announce table statuses, capacities, or seatings to visually impaired staff. | Wrap table render objects in `Semantics` widgets with label, status, and tap action descriptions. | M |
| **CODE-01** | **Low** | Code Quality & Maintainability | `apps/mobile/lib/features/billing/presentation/billing_screen.dart:86` | Unsafe force-unwrap `subscription!.cancelAtPeriodEnd` | While logically guarded by `end != null`, force unwraps (`!`) violate strict null-safety conventions and risk crashes if logic refactors. | Use null-aware property access: `subscription?.cancelAtPeriodEnd == true`. | S |
| **CODE-02** | **Low** | Code Quality & Maintainability | `apps/mobile/lib/core/offline/offline_mutation_queue.dart:182` | TODO comment in offline synchronization retry logic | Unfinished exponential backoff jitter logic left in production offline queue. | Implement standard full-jitter exponential backoff for offline mutation retries. | S |

---

## 4. Prioritized Grouping & Fix Order

### Group 1: Urgent Security & Secret Remediation (Immediate - No DB Migration Required)
1. **SEC-01**: Revoke credentials/ios/dist-cert.p12 password from `credentials.json`; migrate to CI secret.
2. **SEC-02**: Remove `keys/private-key.pem` from workspace and rotate.
3. **SEC-03**: Scrub live production credentials from `.env.local` and rotate Supabase DB password, Stripe keys, and AWS keys.
4. **SEC-05**: Move Sentry DSN and Supabase anon key out of plaintext `codemagic.yaml`.

### Group 2: Critical Database Constraints & Data Integrity (Requires Supabase Migration)
5. **DAT-01**: Create migration adding PostgreSQL `btree_gist` extension and exclusion constraint on `public.floor_table_assignments`.
6. **DAT-02**: Enforce booking capacity validation triggers on `public.reservations`.
7. **DAT-03**: Add foreign key validation trigger ensuring `reservations.assigned_to` belongs to `venue_members`.

### Group 3: Memory Leaks, Lifecycle & Unhandled Runtime Exceptions (Client Dart Fixes)
8. **MEM-01**: Fix `RealtimeChannel? channel` nullability in `ChatRepository.watchMessages`.
9. **MEM-02**: Register `ref.onDispose` cleanup in `router.dart` for `notificationTapServiceProvider`.
10. **COR-01**: Wrap `assignReservation` in try/catch with user feedback.
11. **COR-02**: Add `didUpdateWidget` stream resubscription in `_ChatThreadViewState`.
12. **COR-04**: Fix ISO string formatting with `.toUtc()` in `tasks_repository.dart`.
13. **COR-05**: Invoke `markConversationRead` in `_ChatThreadViewState.initState`.

### Group 4: Performance, Query Optimization & State Management Architecture
14. **PERF-01**: Scope `getReservations` default query window from 395 days down to active day/week.
15. **NAV-01**: Refactor `routerProvider` to a singleton router with `refreshListenable`.
16. **PERF-03**: Move side-effect provider watchers out of root `MaterialApp.router` `build()`.
17. **PERF-02**: Isolate 1-second timer in `TimeClockScreen` to an isolated leaf widget.
18. **COR-03**: Standardize reservation model date fields to UTC.

### Group 5: Environment Separation & Dependency Maintenance
19. **SEC-04**: Spin up dedicated Supabase staging instance; configure `development.json` away from production.
20. **BUILD-01**: Replace discontinued `package:js` with `dart:js_interop`.
21. **BUILD-02**: Check in standard iOS `Podfile`.
22. **A11Y-01**: Add `Semantics` to floor plan table renders.
23. **CODE-01 & CODE-02**: Clean up force unwrap and finish backoff jitter logic.

---

## 5. Open Questions for Approval Before Implementation

1. **Staging vs. Production Supabase Environment**:
   `development.json` currently points directly to production (`puttwjwmwrzmhpsjykuj`). Do you have an existing staging Supabase project reference ready to plug in, or should we prepare a script/config for one?
2. **Double Booking Enforcement Policy**:
   For `DAT-01` (`floor_table_assignments` exclusion constraint), should the database strictly reject overlapping table assignments with an error code (409 Conflict), or do you allow managers to intentionally double-seat a table during special events?
3. **Reservation Default Time Window**:
   For `PERF-01`, when a manager opens the Reservations screen without filters, what is the desired default window? (e.g., Today only, next 7 days, or current business day?)
4. **App Attest Hardware Attestation Enforcement**:
   For `SEC-06`, should App Attest transition from `observe` mode to `enforce` mode now, or remain in `observe` until all legacy employee devices are registered?

---

*End of Audit Findings Report. Antigravity is halted and awaiting user authorization before applying any fixes.*
~~~~

</details>

Audit complete. Awaiting user approval of selected finding IDs before any implementation.

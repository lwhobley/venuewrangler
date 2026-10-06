# Repository review — 2026-10-06

Branch: `claude/nifty-allen-ysavbp`. Scope: repository-wide automated checks, Expo and Flutter clients, NestJS API, Prisma changes, Supabase migrations/functions, and CI configuration. Includes the pending UI and HR/profile-photo changes. This is a review report only; no implementation fixes were made. `.env.local` was preserved and its values were not inspected or printed.

P1 means fix before release because a core workflow or data integrity is affected. P2 means a reproducible functional regression or failed validation gate. Source findings below are not assertions about what is currently deployed.

## Findings, in priority order

### 1. P1 — Employees can manipulate Supabase time records

Locations: `supabase/migrations/20261002233921_time_clock_schema.sql:108`, `:171`, `:189`, `:241`.

The insert trigger preserves a supplied `clock_in_at`; the close trigger preserves a supplied `clock_out_at`. The employee update policy permits updating one's own rows, while the update trigger protects clock-in fields but does not protect already-closed clock-out timestamps or validate changes to `breaks`. An authenticated employee can backdate clock-in, submit a future clock-out, alter a closed entry's clock-out, or remove unpaid breaks. This can inflate reported working time. The existing SQL test explicitly submits `now() + interval '8 hours'` as an employee close timestamp (`supabase/tests/database/time_clock_rls.test.sql:158`).

Fix: assign server timestamps for employee punches; allow corrections only through an authorized, audited manager operation. Validate break transitions and prevent arbitrary editing of completed punches. Add RLS tests for hostile timestamp and break edits. Confirmed by source inspection; DB execution was unavailable because Docker is not running.

### 2. P1 — Profile-photo uploads cannot reach their advertised size limit

Locations: `packages/api/src/common/body-limit.ts:12`; `packages/api/src/modules/app/app-profile.controller.ts:104`.

Both new photo routes are absent from the large-JSON allowlist and receive the default 1 MB request-body limit. The controller accepts up to 5 MB of decoded image bytes. Base64 encoding means even an image of roughly 750 KB can exhaust the JSON limit, so normal phone photos fail before the controller runs. The path-limit helper was checked for both new routes and returns `1mb`.

Fix: include both authenticated photo routes in the larger body parser, align base64 and decoded-size limits, and verify realistic photo requests above 1 MB of JSON through the HTTP stack.

### 3. P2 — Manager photo permissions bypass the existing hierarchy

Locations: `packages/api/src/modules/app/app-profile.controller.ts:96`; `packages/api/src/auth/roles.ts:32`.

The photo route blocks a manager from replacing an owner/admin photo but permits replacing another manager's photo. The shared `canManageRole` policy and staff-edit route explicitly forbid equal-rank manager edits. Photo identity changes therefore use a weaker rule than the rest of profile management.

Fix: apply the shared target-management rule, retaining the intended self-edit exception, and cover manager-to-manager requests.

### 4. P2 — Optional JSON null values crash profile updates

Locations: `packages/api/src/modules/app/app-profile.controller.ts:20`, `:66`; `packages/api/src/modules/app/app-staff.controller.ts:351`.

`@IsOptional()` permits `null`, but the handlers check only for `undefined` and then call `.trim()`. A request with `phone: null` passes validation and throws a TypeError. The same pattern affects multiple contact/name fields in both update paths. Reproduced against the reflected DTO and controller.

Fix: explicitly reject null or support it as a field-clear value consistently; test validation and execution together.

### 5. P2 — Clearing saved contact fields does not work in Team

Locations: `app/(tabs)/staff.tsx:395`; `packages/api/src/modules/app/app-staff.controller.ts:351`.

The editor converts blank phone, alternate phone and address values to `undefined`. JSON omits these fields and the API deliberately preserves omitted fields, so clearing a previously saved value leaves the old value intact. A blank optional hourly rate similarly preserves the old rate.

Fix: distinguish omission from an explicit clear and send an accepted clear value. Verify edit/save/reload for each optional field.

### 6. P2 — An open HR form can save into a different venue

Locations: `app/(tabs)/profile.tsx:34`, `:68`, `:95`; `lib/railway-hooks.ts:680`; `lib/api-client.ts:179`.

HR form state is copied from the active venue's profile when editing begins and is not reset when the venue changes. The user can open venue settings while editing, switch venues and return to the still-mounted profile tab. Save uses the new active venue header and can write the old venue's HR details into the new venue's profile. Clearing query cache on venue changes does not clear component form state, and this mutation does not supply an expected venue.

Fix: bind edits to their initial account/profile/venue, cancel or reset on scope changes, and reject submission after a scope change. Source-confirmed flow; not tested on a device.

### 7. P2 — Photos can fail after their signed URLs expire

Locations: `packages/api/src/modules/chat/media-access.service.ts:8`, `:46`; `app/(tabs)/staff.tsx:807`; `lib/railway-hooks.ts:581`.

Photo URLs expire after 1–2 minutes. Profile, roster and directory queries retain these URLs without a refresh interval or image-error recovery. For example, a virtualized roster row first mounted after the token window requests an expired URL and gets no photo. Query staleness alone does not schedule a fetch while a screen stays mounted.

Fix: renew media access when needed or refetch active photo-bearing views before expiry, and recover from an expired URL without looping on the same token.

### 8. P2 — The new HR form lacks keyboard handling

Locations: `app/(tabs)/profile.tsx:135`, `:159`; `lib/ui-migration-guards.spec.ts:95`.

Eight inputs and Save are in a plain ScrollView without the project's form/keyboard handling. Lower fields can be covered by the native keyboard and the default tap behavior dismisses it before activating controls. The repository keyboard regression guard fails for this screen.

Fix: use the shared form wrapper or appropriate keyboard avoidance, scrolling and tap behavior. Verify lower fields and Save on iOS and Android.

### 9. P2 — Flutter profile hours include unpaid breaks

Locations: `apps/mobile/lib/features/employee/presentation/profile_screen.dart:74`; `apps/mobile/lib/features/time_clock/domain/time_entry.dart:108`.

The profile's worked-hours calculation adds entire clock-in/out intervals and ignores unpaid breaks. An eight-hour punch with a 30-minute unpaid break displays eight hours instead of 7.5, contradicting the time-entry model's net worked duration.

Fix: subtract unpaid break intervals overlapping the displayed week; retain correct handling of punches and breaks crossing week boundaries.

### 10. P2 — Android app-link verification remains disabled

Locations: `app.json:44`; `tests/deep-links.spec.ts:106`.

`autoVerify` is false even though the site now contains `assetlinks.json`. The matching configuration test fails. Android will not request automatic domain verification for this intent filter, so the association file alone does not establish the intended verified invite-link behavior.

Fix: verify the association file against the actual release signing certificate, then align `autoVerify` and deployment configuration. Signing ownership and installed-device behavior were not verified in this review.

### 11. P2 — Three core tests are stale relative to current contracts

Locations: `lib/railway-response-parity.spec.ts:146`; `packages/api/src/modules/chat/chat.controller.spec.ts:255`; `tests/deep-links.spec.ts:75`.

The response-parity parser misses the HR fields returned through a mapper spread, the directory test still expects no `photoUrl`, and the AASA test expects invite-only paths although the current association also claims billing returns. These are failed validation gates; the first does not prove that the runtime HR response lacks fields.

Fix: teach the contract guard to recognize the mapped response, cover the actual response, and update directory/deep-link expectations to the intended supported contracts.

### 12. P2 — Supabase Edge Function lint fails

Locations: `.github/workflows/supabase-ci.yml:109`; `supabase/functions/_shared/document-bytes.ts:36`.

The exact lint command reports 13 errors under installed Deno 2.9.1: inline import prefixes, unnecessary async declarations, unused suppression comments and a misplaced no-control-regex suppression. CI selects Deno `v2.x`, so this is an active gate failure, not merely a suggested style change.

Fix: align import/configuration conventions with the selected Deno version and correct the code/suppressions; rerun the actual lint command.

### 13. P2 — Supabase CI's test command cannot run

Location: `.github/workflows/supabase-ci.yml:112`.

`deno test --allow-none ...` fails with “unexpected argument '--allow-none'” on installed Deno 2.9.1. Removing that flag in a read-only check then reports “No test modules found”: `_shared/` contains no Deno test files. The command currently cannot provide the claimed shared-module test coverage.

Fix: use supported permission options/defaults and add meaningful Deno tests or invoke the actual existing test suite. Do not substitute a silently successful empty test run.

## Validation evidence

- Core Vitest run: 134 files, 129 passed and five failed; 1,450/1,456 tests passed. Six failures: keyboard guard, HR response parity, directory shape, AASA paths, Android verification, and source-manifest timeout.
- Source-manifest test rerun alone passed; the earlier timeout under full-suite load is not treated as a confirmed implementation defect.
- UI Vitest run: all 57 files and 329 tests passed. These results do not establish real-device rendering, keyboard behavior or actual photo uploads.
- App, API and marketing TypeScript checks passed.
- `git diff --check` passed, with Windows newline warnings only.
- Expo Doctor: 19/21 checks passed; config-schema and React Native Directory checks could not finish because external requests failed. Those two failures are not classified as code defects.
- Deno lint: 13 errors. Explicit-config checking of `_shared/venue-auth.ts` passed. Checking all function entries was blocked by missing local npm type dependency resolution under the non-installing review command; full Edge Function type safety remains unverified.
- API integration and Supabase migration/RLS execution were unavailable because the Docker daemon is not running.
- Flutter analysis stalled without diagnostics and was stopped. Flutter tests and real-device checks remain unverified.
- npm vulnerability audit could not reach its registry endpoint. No claim of dependency safety is made.
- No migration, deployment, commit or production mutation occurred during this review.

## Assessment

Release-readiness score: **5/10**, a qualitative review judgment rather than a test-coverage measurement. The first three priorities are time-record integrity, the photo request-size mismatch, and consistent authorization for photo edits. Address the remaining functional issues and failed gates before claiming release readiness.

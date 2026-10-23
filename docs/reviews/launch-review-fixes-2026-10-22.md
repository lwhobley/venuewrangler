# Launch review remediation - 2026-10-22

The October 22 launch-review findings are addressed in the Flutter app and one additive Supabase migration. The Supabase migration and Edge Functions were deployed on October 23, 2026; the app rollout is tracked below.

| Finding | Change |
| --- | --- |
| S1 | Managers configure an address, coordinates and clock-in radius in Settings. The database refuses a new punch without a venue location; existing punches can still close. |
| A1 | Explicit staff account signup creates no workspace. Invitations are emailed by `invite-member`, expired rows can be replaced, and invite delivery failures remain visible. |
| A2 | Expired callback links explain how to request a replacement reset email. |
| D1 | Manager hours review includes named punches, monthly navigation, audited clock-out corrections and CSV export. Restricted clock boards explain manager access. |
| D2 | The board subscribes to shift changes. Edits and drags patch only changed fields, preserving another user's assignment changes. |
| D3 | Incident, task, event, lead, BEO, document and invitation dialogs stay open on validation/save errors. HR validation also displays feedback beside the current workflow. |
| D4 | BEO cancellation asks for confirmation and offers Restore to draft. Reservation cancellation synchronizes the BEO in the same transaction; linked private events require a manager. |
| D5-D6 | Event notes are visible; BEO entry/details and punch history use the venue clock. |
| U1 | Swap cards show the shift and confirm who takes it; the database refuses overlapping assignments, including accepted swaps. |
| U2 | Staff profile links directly to requests; request rows show names and selected shifts. |
| U3 | Chat messages show sender, timestamp and distinct own-message alignment. |
| U4 | Selecting a table hides the floating Add button so Edit/Delete stay accessible. |
| U5 | Signup collects a name; roster RPCs use the venue's preferred/legal profile name as a fallback without exposing HR records. |
| U6 | Reservations sort earliest first and use business-date headers. |
| U7 | Event conflicts identify reservations as well as confirmed events. |
| U8 | AI suggestions resolve exact unambiguous roster names, retain role labels, receive today's date and require explicit valid times. |
| U9 | Browser photo paths bypass native file rewriting; upload still sanitizes the bytes before storing them. |

## Rollout

1. Review missing venue coordinates before deploying `20261023101510_launch_review_workflows.sql`. Configure genuine venue locations before staff next clock in. The new guard intentionally blocks new punches for every unconfigured venue; no coordinates are guessed or backfilled.
2. Deploy the migration, then `invite-member` and the updated `ai-assistant`, then the app.
3. `invite-member` requires the existing `RESEND_API_KEY`, `EMAIL_FROM`, plus `INVITE_APP_URL` pointing to the app's staff signup route, for example `https://venuewrangler.com/app/#/sign-up?join=1`. Configure these through the approved secrets process; no secret values belong in source.
4. Verify a real invitation email, confirmed staff signup, browser photo upload, CSV download and an on-site device punch in staging before a production rollout.

The report's infrastructure follow-ups (backup encryption recipient/restore drill, hosted Supabase settings, separate Stripe testing, DNS policy) are external configuration work. No credentials, backup settings, Stripe accounts or DNS records were changed here. The production migration and the two reviewed Edge Functions were deployed on October 23 under the owner's authorization; no native release build was triggered.

## Verification

- All migrations plus the repository's CI auth/storage/grants fixtures replayed successfully against a new loopback-only PostgreSQL 18 cluster (94 SQL files). Cron, Vault and hosted Storage behavior are outside this fixture.
- `supabase/tests/launch_review_assertions.sql` passed native SQL assertions for manager/tenant authorization, unconfigured/outside-geofence punches, expired-invite replacement, overlapping shift and swap rejection, name resolution, cancellation and restoration. The CI workflow runs this file alongside the existing pgTAP suite.
- Six isolated invitation handler tests passed; Deno type checking and lint passed. No email was actually sent.
- Flutter analysis and formatting passed with no issues. The full run passed 502 tests and identified one outdated clock-board expectation; after updating it to check the staff name, all 20 clock/schedule tests passed. The normal asset build is required; `--no-test-assets` omits Flutter's ink shader and is not a valid full-suite run in this checkout.

## Hosted rollout - October 23, 2026

- Applied `launch_review_workflows` to project `puttwjwmwrzmhpsjykuj`. The connector assigned version `20261023101510`; the source filename now matches that recorded version to prevent a duplicate application.
- Verified the invitation/location RPCs exist, anonymous execution is denied, and all three new workflow triggers are enabled.
- Deployed `invite-member` version 1 and `ai-assistant` version 37, both ACTIVE with JWT verification enabled.
- Both venues currently have 0,0 coordinates. The owner will enter their locations in the app; new punches are blocked until then.
- The owner confirmed Auth URLs, SMTP and invitation secrets are already configured. No credentials were read or changed. Actual invitation delivery and on-site clock-in remain unverified.
- Combined the review branch with main and resolved chat, BEO and time-clock conflicts while preserving the Organic theme. The merged app passed all 503 Flutter tests. App publication is tracked by PR #186 and its production deployment workflow.

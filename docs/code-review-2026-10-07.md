# Full-repo code review — 2026-10-07

Every tracked source file was read (Flutter `apps/mobile/lib` + `test`, all 62 migrations,
all Edge Functions, pgTAP tests, site/worker, CI workflows, Codemagic, Android/iOS config).
Nothing was changed. Severity: **H** high, **M** medium, **L** low. "✓" = re-checked against the
code by hand after the review; the rest are the reviewer's verified reading (confirmed) or
**(plausible)** where it depends on platform behaviour that could not be run here.

Key context: `create_workspace` lets any signed-in user become owner of a brand-new org, so
"is a manager of *some* venue" is free for an attacker. Several guards check the role on the
row's *new* venue, which that makes exploitable.

## Database (RLS, triggers, RPCs)

### Cross-tenant / authorization
- **H ✓** `migrations/20261002184109_shift_swaps_schema.sql:64` — `enforce_shift_swap_update` returns early if the caller manages `new.venue_id`; the update policy only needs membership; `venue_id`/`shift_id` are mutable. Staff at venue A who own a free workspace B can `update shift_swaps set venue_id=B, status='accepted', accepted_by=X, shift_id=<any>` and the definer `apply_accepted_shift_swap` reassigns a shift at A (or any org).
- **M ✓** `20261002154114_tasks_schema.sql:109`, `20261002154205_incidents_schema.sql:87` — same "role on new.venue_id" early return: an assignee/reporter moves the row to their own workspace and every column guard is skipped (task/incident vanishes from venue A).
- **M ✓** `20261002235927_floor_schema.sql:326` — `assign_tables_to_reservation` never checks `p_table_ids`/`p_reservation_id` belong to `p_venue_id`; holds can be written into another org's floor. `floor_table_assignments_write` (FOR ALL) lets `table_id` be re-pointed on update.
- **M ✓** `20261003000037_chat_schema.sql:435` — `conversation_members_insert` only needs a role at the venue: any staff can add themselves to any DM/group (and nobody can remove them), then read history and 4-segment attachments.
- **M** `20261003000037_chat_schema.sql:414` — `conversations_update` has no column guard: any member can flip a DM to `all_staff` (exposes it to the venue) or an all_staff channel to `group`, or fake `last_message_text`.
- **M** `20261003000037_chat_schema.sql:246-268` (+ `20261005115202:238`) — `messages.attachment_path` is never tied to the conversation/sender; posting a message naming someone else's file and deleting it makes the privileged worker delete their file.
- **M** `20261004144042_remove_beo_deposit_and_stripe_connect.sql:161` — `crm_beos.lead_id` only validated on INSERT; on UPDATE it can point at another org's lead and `crm_beos_sync_reservation` (definer) copies that lead's name/phone/email into the caller's reservation. Same gap on `crm_contracts`.
- **L** `20261002154205_incidents_schema.sql:126` (and checklists/tasks) — `organization_id` only re-derived on insert; a manager can set a foreign org id and forge `audit_log` rows under it.
- **L** `20261003000037_chat_schema.sql:332` — `create_or_get_dm` doesn't check the target user belongs to the venue.

### Integrity
- **M ✓** `20261006203829_time_entry_breaks_equal_hardening.sql:59` — `location_anomaly` and `shift_id` are not in the immutable list; an employee can clear the anti-replay `location_anomaly` flag on their open punch.
- **M ✓** `20261003001000_storage_deletion_worker_and_schedule.sql:67` — the `attempts + 1` update is inside the BEGIN/EXCEPTION block and rolls back with the error, so failing jobs never reach `dead`; 25 permanent failures fill every batch and starve newer deletions.
- **M (plausible)** same file `:43,74` — files are "deleted" with `delete from storage.objects` (bypassing `storage.allow_delete_query`). On hosted Supabase that removes metadata only; the bytes stay in the object store (account-deletion photos, documents, chat attachments). Needs a Storage-API worker.
- **M ✓** `20261002174928_workforce_invites.sql:19` — `unique (venue_id, email, status)`: a second revoke for the same email fails (23505), and a re-invited user who previously accepted can never complete sign-up (unique violation inside the `auth.users` trigger, `20261005115245:153`).
- **M** `20261002235811_notifications_schema.sql:80` + `apps/mobile/lib/core/auth/sign_out_service.dart` — push token stays registered to user A after sign-out; on a shared tablet B can't register (42501 swallowed) and A's pushes keep arriving in front of B.
- **M (plausible)** `20261007190000_account_deletion_fixes.sql:316-467` — anonymisation runs once at request time but the session stays valid; a later write (new workspace, shift/task assignment) re-creates a NO ACTION reference and every worker retry fails until the job is dead.
- **M (plausible)** `20261007201000_review_fixes…sql:166` — any non-terminal status (incl. `past_due`/`unpaid`) on an older subscription takes the row over; its later cancel then cancels the org while a newer sub is active. Prefer "only active/trialing take over".
- **L** `20261007200621_restaurant_inventory_v2.sql:129` — the data-migration UPDATE fires the legacy trigger and wipes every item's `updated_by`/`updated_at`.
- **L (plausible)** same file `:3,576` — explicit `begin;`/`commit;` inside a migration.
- **L** `20261003005913_crm_schema.sql:371-437` — reservation-hold conflict check only on first sync; moving a confirmed BEO's date double-books; inserting a BEO directly as confirmed creates no reservation.
- **L** `20261007021641_pos_schedule_platform.sql:256-286` — `publish_pos_schedule` fails forever if any scheduled shift (even past/open) has no staff or role label.
- **L (plausible)** same file `:447` — `protect_pos_shift_delete` also fires on venue/org cascade deletes.
- **L** `20261003043737_documents_schema.sql:67` — a document named like `report..final.pdf` can never be deleted (path guard rejects `..`).
- **L** `20261005220028_notification_triggers_and_dispatch.sql:87` — a bad `venues.timezone` (only validated in `create_workspace`) makes every shift insert fail.
- **L** `20261007190000_account_deletion_fixes.sql:336` — sole-owner check unlocked; two co-owners deleting at once leaves an ownerless org.
- **L** `rollbacks/20261007180000_account_deletion.sql:32` — rollback re-adds the bucket check without `profile-photos` and fails once such jobs exist; migration 61 has no rollback.

## Edge Functions
- **H ✓** `functions/toast-pos/index.ts:113` — allows `paid`/`void` but `pos_checks.status` only allows `open/closed/voided`: those webhooks 500 forever, real voids are rejected 400.
- **M ✓** `functions/crm-send-email/index.ts:127` — activity-log insert uses the service client with a client-supplied `lead_id` from any org (cross-tenant write into another org's CRM log).
- **M ✓** `functions/_shared/cors.ts:6` — `x-correlation-id` not in allowed headers; the web app sends it on every AI call, so all AI requests fail CORS preflight on web.
- **M (plausible)** `functions/{square,quickbooks,gusto}-oauth/index.ts` + `_shared/crypto.ts:92` — OAuth `state` is replayable for 10 min and not bound to the finishing browser; a victim merchant can be tricked into linking their provider account to an attacker's venue.
- **M (plausible)** `functions/_shared/app-attest.ts:203` — cert signature hash picked from issuer curve instead of the cert's signature algorithm; if Apple's leaf is ecdsa-SHA256 every iOS attestation records `invalid`.
- **M** `functions/_shared/document-bytes.ts:35` — an all-non-ASCII filename (`Меню.pdf`) slugs to `pdf`, losing the extension → "Unsupported file type".
- **L** `functions/device-attestation/index.ts:187` — Play Integrity verdict not bound to nonce/timestamp/device (replayable).
- **L** `functions/notifications-send/index.ts:50,126` — client `data` passed through: `origin:"db"` double-pushes, an `aps` key blanks the iOS alert; `target_user_ids`/`audience` unvalidated.
- **L** `functions/account-deletion-worker/index.ts:75` — status updates never set `updated_at`, so the sweep's lease/backoff don't work (duplicate deleteUser calls).
- **L** `functions/crm-send-email/index.ts:81` — `template_not_found` branch unreachable (shows generic error).
- **L** `functions/stripe-create-checkout/index.ts:99` — no guard against a second checkout while a subscription is active (double billing; API-only today).
- **L** `functions/ai-assistant/index.ts:84`, `_shared/crypto.ts:103,172` — malformed ids/tokens give 500 instead of 400/redirect.

## Flutter app
### Data that silently stops showing
- **H ✓** `features/chat/data/chat_repository.dart:47` — ascending + limit 50 returns the 50 *oldest* messages; past 50, new messages never appear.
- **H ✓** `features/guests_reservations/data/guests_reservations_repository.dart:111` (+ providers:20) — no date filter, ascending, limit 50: after 50 reservations, tonight's never show.
- **H ✓** `features/schedules/data/schedules_repository.dart:60` — all shifts, ascending, `max_rows=1000`: past ~1000 shifts, current/future shifts vanish everywhere.
- **L** `features/time_clock/data/time_clock_repository.dart:106` — clock board filters "open" after taking newest 50; old forgotten punches disappear.
- **L** `features/inventory/data/inventory_repository.dart:77` — archived items counted on dashboard.

### Broken against the backend
- **H ✓** `features/pos/data/pos_repository.dart:82` — `.select()` (= `*`) on `pos_connections`, which only grants column-level SELECT → "permission denied" for every manager.
- **H** `features/inventory/presentation/inventory_count_screen.dart:505` — save/complete sends every row, blanks as `null`, so a second device's save erases the first device's counted rows.
- **M** same file `:532` — "Complete" on an already-completed count reports success but ignores the entries.
- **H** `features/tasks/data/tasks_repository.dart:74,97`, `features/incidents/data/incidents_repository.dart:67` — update/delete without `.select()`: RLS-denied writes "succeed" with 0 rows (supervisor marks task done, nothing happens; offline path reports a false conflict).
- **M** `features/staff_requests/presentation/staff_requests_screen.dart:329` — never sends `requested_shift_id`, so approving Drop/Add/Open shift requests changes nothing.
- **M** `features/time_clock/data/time_clock_repository.dart:57` — open punch looked up per venue but DB allows one per user overall; at venue B the user is shown "clocked out" and Clock In always fails.
- **M** `features/schedules/presentation/schedule_list_screen.dart:328`, `workforce_roster_screen.dart:378` — AI-suggestion "Add" passes the popped dialog's context; `!context.mounted` returns early, so nothing is created.
- **M** manager-only actions shown to staff/supervisors that always fail (`schedule_list_screen.dart:105,385`, `staff_requests_screen.dart:171`, `workforce_roster_screen.dart:26`, `shift_insights_screen.dart:134` — the last also spends AI budget first).
- **M** `features/schedules/presentation/schedule_timeline_screen.dart:360` — `venue_roster` is manager-only (my change), so for staff/supervisors everyone on the board shows "Former team member". Needs a member-readable names RPC or a fallback.
- **M** `app/router.dart:122` — employees can't open `/staff-requests` (staff can't request time off; request push taps bounce home).
- **M** `features/notifications/data/notifications_repository.dart:83-108` — read state is one column on broadcast rows: a manager's "mark all read" clears it for everyone; staff can't mark broadcasts read (0-row update, badge never clears).
- **M** `features/crm/presentation/crm_screen.dart:281` — date-only BEO `event_date` becomes a midnight–4am reservation; overlap check misses real evening bookings.
- **M** `features/guests_reservations/presentation/reservations_screen.dart:246` — new reservations are always "now + 1h"; no error handling, double-submit, controllers never disposed.
- **M** `features/events/presentation/event_list_screen.dart:341` — event times printed as raw UTC `toString()`.
- **M** `features/chat/application/chat_providers.dart:155` — no realtime for messages (not in the publication); threads don't update until you send.
- **M** `features/chat/presentation/chat_screen.dart:182` — text cleared before send, no error handling; non-members can't post to all_staff (trigger vs RLS mismatch).
- **M (plausible)** `features/media/data/media_repository.dart:169` — retry uploads with `upsert:true` but `incident-evidence` has no UPDATE policy → retries always fail after a partial success.
- **M (plausible)** `features/floor/data/floor_repository.dart:113`, `floor_editor_controller.dart:318` — filtered realtime misses DELETEs; resumed drafts delete tables added by another manager.
- **M** `features/crm/presentation/crm_lead_detail_screen.dart:177` — status dropdown bound to the stale route arg.
- **M** `features/floor/presentation/floor_plan_screen.dart:59,193` — table actions fire-and-forget, no errors, setState after await.
- **M** `features/inventory/presentation/inventory_import_screen.dart:149,218`, `inventory_action_sheet.dart:46` — 2 MB file vs 20k-char AI limit (generic error); idempotency key regenerated on reopen → double receive.
- **M** `features/insights/data/insights_repository.dart:97` — non-atomic one-by-one inserts; partial saves duplicate on retry.

### Core / session
- **H ✓** `core/offline/offline_queue_controller.dart:121` — with no signed-in user the ownership check is skipped and another user's queue is replayed as anon (then lost as a "conflict").
- **H** same file `:141-165` — 5 offline cold starts turn a queued write into an in-memory-only conflict that's never shown and lost on restart.
- **M ✓** same file `:121` — a flush keeps running handlers for entries a sign-out cleared mid-flush (my earlier fix only protects final state; the test doesn't count handler calls).
- **M** `core/auth/auth_providers.dart:34` — recovery flag is in-memory; killing the app on /reset-password restores the recovery session and skips setting a password.
- **M** `app/router.dart:381` — cold-start push taps are lost (no persisted venue → /select-venue); Android adds an `onMessageOpenedApp` listener per router rebuild.
- **M (plausible)** `core/offline/offline_queue_store.dart:38` — non-atomic write + no FormatException handling bricks the queue after a mid-write kill.
- **L** sign-in/up show raw `AuthApiException(...)` text; `notifications_screen.dart:60` shows "Instance of 'UnknownError'"; notification dates in UTC; billing visible to roles RLS hides it from, dates raw UTC.
- **L** `core/storage/secure_session_storage.dart:22` — `deleteAll()` also wipes theme and App Attest key on every sign-out.
- **L** `features/organizations/domain/workspace_timezones.dart:24` — "MST"→Denver (Arizona has no DST), "CST"→Chicago (also China).
- **L** dialogs disposing controllers while animating out: `photo_annotation_screen.dart:155`, `profile_screen.dart:279`.
- **L** misc: shift swap double-request/stale accept, DST day stepping, schedule math ignores venue timezone, event delete without confirm, CRM convert double-tap, floor plans cache, integrations offline errors unhandled, CSV strict UTF-8, assistant screen overflow, inventory "Add location" clears par, `late final userId` session check no-op.

## Tests
- **H** `supabase/tests/database/chat_rls.test.sql:150` — "non-member can't read DM" runs before any DM message exists (can't fail); `:187` passes only via a NULL conversation id.
- **M** many negative RLS tests use only `lives_ok` on UPDATE/DELETE without checking the row (events, inventory, device_attestation, …) — a 0-row denial and a successful write look the same.
- **M** `apps/mobile/test/features/employee/employee_home_test.dart:368` — fails when run 05:30–06:00.
- **M** `apps/mobile/test/core/offline/offline_queue_controller_test.dart:257` — doesn't count handler calls (see core finding).
- **M** Vitest suites (`tests/workflow-security.spec.ts`, `site/onboarding.spec.ts`) are never run by CI; one SRI test asserts nothing.
- **L** anon tests keep a stale `request.jwt.claim.sub`; POS "no 86 action" test renders no connection.

## Build, CI, site, native
- **H (plausible)** `apps/mobile/ios/Runner/RunnerRelease.entitlements:7` — App Attest entitlement likely missing from the App Store profile Codemagic uses → archive/export fails (fits the tags that never reached TestFlight). Enable App Attest on the App ID and regenerate the profile.
- **M** `site/.well-known/apple-app-site-association:7` — `/join` universal links open the app, which has no `/join` route; invite token lost.
- **M (plausible)** `apps/mobile/ios/Runner/Info.plist` — missing `NSAppleMusicUsageDescription` (file_picker audio) → ITMS-90683.
- **M** `.github/workflows/database-backup.yml:30,90,133` — backs up the legacy Prisma DB only; the Supabase production project has no automated backup.
- **M** `site/_worker.js:12` — Flutter web assets cached 4h with fixed names; engine/version mismatches after deploy.
- **M (plausible)** `apps/mobile/android/app/src/main/AndroidManifest.xml:10` — `allowBackup` default true + secure storage → launch failure after restore.
- **L–M** `.github/workflows/deploy-cloudflare-pages.yml` — `/app` deploys on push regardless of Flutter CI.
- **L–M** `codemagic.yaml:57` — build-number lookup failures are swallowed (`|| echo 0`); `:74` `submit_to_testflight` triggers external beta review.
- **L** `android/app/build.gradle.kts:58` — release silently signs with the debug key without `key.properties`.
- **L** `site/join/index.html:31` empty venue name; `site/faq/index.html:294` dead anchors; `supabase/config.toml:38` local redirect list; `android/app/google-services.json` committed (check key restrictions).

Clean: Stripe/service-role keys not committed; GitHub Actions pinned, no `pull_request_target` or script injection; Flutter version consistent (3.47.5); `ios-v*` tag pattern matches; pgTAP plan counts all correct; 199 Flutter tests pass.

# Production operations

Venue Wrangler runs on **Supabase** (Postgres, Auth, Storage, Edge Functions) and **Cloudflare** (Pages for the website and the Flutter web app at `/app`, R2 for backups). Mobile apps are built and signed in **Codemagic**. Earlier versions of this document described a NestJS/Prisma API on Google Cloud Run deployed by `deploy-api.yml`; that is decommissioned (see "Legacy" at the end).

## Subprocessors

This list must match `docs/privacy-policy.md`, `site/privacy/index.html` and `docs/soc2/vendor-management-policy.md`. Change all four together.

| Subprocessor | Use |
|---|---|
| Supabase | Database, authentication, file storage, Edge Functions |
| Cloudflare | Pages hosting and CDN; R2 backup storage |
| Stripe | Subscription payments |
| Resend | Transactional email |
| Sentry | Crash and error diagnostics |
| Groq | AI assistant, only when an organization enables AI |
| Google Firebase Cloud Messaging, Apple APNs | Push notifications |
| Google Play Integrity, Apple App Attest | Device/app integrity |
| Cloudmersive, ClamAV | Malware scanning of uploaded documents |
| Square, Toast, QuickBooks (Intuit), Gusto, BrightHR | Optional integrations a venue connects |

Not used by the current product and not to be listed: AWS S3, Google Cloud Run/Cloud Storage, Google Gemini, Apple In-App Purchase.

## Health and monitoring

- Supabase dashboard: database health, API/Auth/Edge Function logs, advisors (security and performance).
- Sentry: client and Edge Function errors (alerts go to the principal's email).
- GitHub Actions: failed scheduled runs of the backup, storage-backup and restore-drill workflows are the backup alarm. Make sure GitHub notifies on failed workflow runs.
- `public.ops_health_report()` (service role) lists silent failures such as stuck deletion jobs; any `critical` or `warning` row needs action.
- There is no staging environment and no on-call rota; the principal is the only responder.

## Release and rollback

**Web app and site.** Pushing to `main` runs `.github/workflows/deploy-cloudflare-pages.yml` (tests, `npm audit` gate, Flutter analyze/test, build, `wrangler pages deploy`). The job is bound to the GitHub `production` environment: configure required reviewers and a `main`-only deployment rule on it so a push alone cannot ship. To roll back, promote the previous deployment in the Cloudflare Pages dashboard or revert the commit and let the workflow redeploy. Then verify `https://venuewrangler.com/app/` loads and sign-in works.

**Database and Edge Functions.** There is no automated deployment. Migrations (`supabase db push` or the SQL editor) and functions (`supabase functions deploy`) are applied by hand by the principal. Migrations are forward-only; to undo one, write a new forward migration. Take a manual backup (run `Supabase Database Backup` via `workflow_dispatch`) before a risky migration.

**Mobile apps.** Codemagic builds TestFlight/Play builds from tags on `main`; store review and phased rollout are the rollback levers (expedited review for fixes).

**Release checklist**
1. CI is green: Site CI, Supabase CI (pgTAP + Deno), Flutter CI.
2. Review pending migrations; back up first if destructive.
3. Merge to `main` (approve the `production` environment if reviewers are configured).
4. Smoke test sign-in, the time clock, and checkout against Stripe.
5. Record the previous Pages deployment ID for rollback.
6. Confirm the `retention-cleanup` pg_cron job's latest run succeeded.

## Database backups and restore

**What exists.**
- `.github/workflows/supabase-database-backup.yml`: nightly at 04:00 UTC. It takes a logical `pg_dump` of `public`, `app_hidden`, `auth` and `storage`, checks it with `pg_restore --list`, gzips it, **encrypts it client-side with `age`** to the public recipient `BACKUP_AGE_RECIPIENT`, and uploads `database-backups/supabase-<ref>-<UTC timestamp>.dump.gz.age` to the Cloudflare R2 bucket, then verifies the uploaded size. It **fails** if no recipient is configured, so a plaintext dump can never be uploaded. The job runs in the GitHub environment `production-backups`.
- `.github/workflows/supabase-storage-backup.yml`: daily at 05:00 UTC; mirrors every Storage bucket to `storage-mirror/<bucket>/` and keeps changed/deleted objects under `storage-changes/<date>/` for 30 days; fails if file count or bytes differ. The database dump holds Storage metadata only, not file bytes.
- `.github/workflows/supabase-restore-drill.yml`: monthly (and on demand). Downloads the newest backup, decrypts it with `BACKUP_AGE_IDENTITY`, restores it with `pg_restore` into an ephemeral `supabase/postgres` container, and asserts that `organizations`, `venues`, `memberships` and `auth.users` have rows. It fails loudly otherwise and uploads nothing. **The drill's run summary is the SOC 2 evidence that a restore was tested.** Until it has passed once, backups are unproven.

**Recovery point.** The nightly dump means an RPO of **up to 24 hours**. **Enable Supabase PITR** (paid add-on) if the plan allows: it brings the RPO to minutes and is the recommended control for payroll and time records. RTO has not been measured.

**One-time setup the operator must do.**
1. Generate an age key pair offline (`age-keygen`). Store the identity offline in two places.
2. Create GitHub environments `production-backups` and `backup-restore-drill` (required reviewer on the latter). Put these in `production-backups`: `SUPABASE_PRODUCTION_DB_URL` (secret), `R2_BACKUP_ACCESS_KEY_ID`, `R2_BACKUP_SECRET_ACCESS_KEY` (secrets), `BACKUP_AGE_RECIPIENT` (public key; secret or variable), and the variables `SUPABASE_PRODUCTION_PROJECT_REF`, `R2_ACCOUNT_ID`, `R2_BACKUP_BUCKET`, optionally `R2_JURISDICTION`. Put these in `backup-restore-drill`: `BACKUP_AGE_IDENTITY` (secret), `R2_RESTORE_ACCESS_KEY_ID`, `R2_RESTORE_SECRET_ACCESS_KEY` (an R2 **read-only** token on the bucket), and the variables `R2_ACCOUNT_ID`, `R2_BACKUP_BUCKET`, `R2_JURISDICTION`.
3. On the R2 bucket: add a lifecycle rule deleting `database-backups/` after 30 days and `storage-changes/` after 30 days (never on `storage-mirror/`), and enable **bucket lock** (a retention rule on `database-backups/` for at least 30 days, and versioning if available) so a leaked token cannot delete or overwrite backups. Cloudflare R2 tokens are not write-only (the backup job also needs read for its size check), so immutability must come from bucket lock, not from the token. Use a token scoped to this one bucket.
4. Run `Supabase Database Backup` manually, confirm a `.dump.gz.age` object appears, then run `Supabase Restore Drill` and keep the passing run.

**Restoring for real.** Create a new Supabase project, apply `supabase/migrations`, or restore the decrypted dump into it with `pg_restore --no-owner`; verify Auth and application data there before pointing the app at it. The app's Supabase URL/anon key (`FLUTTER_PRODUCTION_ENV_JSON`, Codemagic) and the host in the `/app` CSP (`site/_worker.js`) must change together. Never store a database password in this repository. To restore a Storage bucket, `rclone copy` from `storage-mirror/<bucket>/`.

Decryption: `age --decrypt -i identity.txt -o dump.gz file.dump.gz.age && gunzip dump.gz`.

## Retention cleanup

pg_cron calls `app_hidden.run_retention_cleanup()` daily at 06:17 UTC (`supabase/migrations/20261010120000_retention_cleanup_in_database.sql`, extended by later migrations such as `20261017110000_audit_privacy_retention_and_evidence.sql`). It deletes audit-log rows after 365 days (time-entry corrections/voids after 3 years), attestation challenges after expiry, and retained wage records after 3 years, and in the later migration nulls raw POS payloads after 90 days, anonymizes guest data on reservations after 24 months, purges old invites and notification events, and nulls raw punch GPS after the configured period (default 365 days). To check it, run `select * from cron.job_run_details where jobid = (select jobid from cron.job where jobname = 'retention-cleanup') order by start_time desc limit 5;` in the Supabase SQL editor. Treat a failed or missing run as an operational alert.

## Document malware scanning

The `documents-upload` Edge Function scans every validated file (ClamAV daemon via `CLAMAV_HOST`/`CLAMAV_PORT`, and/or Cloudmersive via `CLOUDMERSIVE_API_KEY`) before storing it and rejects the upload if scanning fails. Do not expose the ClamAV daemon to the public internet. **[operator to confirm where the ClamAV daemon runs now; earlier notes referred to a Google Kubernetes Engine cluster that is part of the decommissioned Google Cloud setup.]** Legacy OLE Office formats (`.doc`, `.xls`, `.ppt`) are intentionally blocked; use `.docx`, `.xlsx` or `.pptx`.

## POS and OAuth secrets

POS webhook secrets are stored only as SHA-256 digests; rotate a stale or exposed one through the app's POS connection settings (the new secret is displayed once). OAuth client secrets for Square, QuickBooks and Gusto live in Supabase secrets; rotation steps are in `docs/security/secrets-handling.md`. Never paste plaintext secrets into source control, tickets or logs.

## Clock behavior

Clock punches require an online response. Failed requests display an error and are never replayed later under another identity or time; staff should check their status before retrying and request a time correction for a missed punch. Punch location is reported by the client and can be spoofed, so geofencing is a deterrent rather than proof. Punches are refused at a venue that has no coordinates set (trigger `app_hidden.require_clock_in_location`, since `20261023101510`); managers set the location in the app's Settings (`set_venue_location`).

## Security configuration

- Hosted auth settings the operator must apply by hand: `docs/security/hosted-auth-settings.md`.
- Secrets, rotation and GitHub environment/branch-protection settings: `docs/security/secrets-handling.md`.
- Compliance posture (honest status): `docs/soc2/soc2-controls-matrix.md`.
- Findings and status from the 2026-11-25 security review: `docs/security/security-review-2026-11-25.md`.

## Production flags and settings

Platform flags live in the single row of `app_hidden.platform_settings`; change them as the table owner in the SQL editor (clients cannot read or write the table). Edge Function variables are set with `supabase secrets set NAME=value` and take effect on the next invocation. The older switches (`billing_enforcement`, `gps_retention_days`, `ai_monthly_org_budget_usd`) are described in `docs/security/remediation-2026-10-17.md`.

| Setting | Where | Default | Effect |
|---|---|---|---|
| `require_mfa_for_admin_actions` | `app_hidden.platform_settings` | false | Requires an MFA (`aal2`) session for role changes, ownership transfer, wage edits, Stripe checkout/portal, payroll OAuth connect, and BrightHR connect/disconnect. |
| `require_attested_punches` | `app_hidden.platform_settings` | false | The database refuses self-service punches that did not come through `time-clock-punch`. |
| `TIME_CLOCK_ATTESTATION_MODE` | Edge Function secret (`time-clock-punch`) | `observe` | `enforce` refuses punches without a valid App Attest / Play Integrity proof and fails closed on verification errors. |
| `TIME_CLOCK_REQUIRE_ATTESTED` | Flutter `--dart-define` (production build) | false | `true` makes the app fail closed instead of writing a punch directly when the function is unreachable. |
| `POS_WEBHOOK_ALLOW_LEGACY_SECRET` | Edge Function secret (`toast-pos`) | unset (off) | Opt-out. When `true`, the function also accepts the legacy `X-Venue-Webhook-Secret` header. By default only signed Toast webhooks are accepted. |
| `CORS_ALLOWED_ORIGINS` | Edge Function secret | see the function code | Allowlist of browser origins the Edge Functions answer with CORS headers. Requests from other origins get no CORS grant. |
| Auth redirect allowlist | Supabase dashboard | n/a | `https://venuewrangler.com/reset-password` for iOS/web; `venuewrangler://reset-password` for Android only, until `site/.well-known/assetlinks.json` has the real fingerprint. See `docs/security/hosted-auth-settings.md` section 5. |

**`require_mfa_for_admin_actions`.** Owners and admins must enrol TOTP in the app before this is turned on; otherwise they cannot change roles, edit wages, manage billing, or connect payroll or BrightHR. Enable with `update app_hidden.platform_settings set require_mfa_for_admin_actions = true;`.

**Enforcing attested punches (rollout order).** Do these in order; doing them out of order blocks legitimate punches.
1. Deploy `time-clock-punch` in `observe` mode and ship app builds that send per-punch proofs.
2. Confirm on a real iPhone and a real Android phone that punches come back `verified`.
3. Set `TIME_CLOCK_ATTESTATION_MODE=enforce` on the function.
4. Run `update app_hidden.platform_settings set require_attested_punches = true;`.
5. Ship production app builds with `--dart-define=TIME_CLOCK_REQUIRE_ATTESTED=true`.

Details and verification queries: `docs/security/remediation-2026-10-17.md`, "Rolling out attested punches".

**`POS_WEBHOOK_ALLOW_LEGACY_SECRET`.** Toast webhooks are now accepted only when signed. If a gateway in front of a venue still sends only the legacy `X-Venue-Webhook-Secret` header, run `supabase secrets set POS_WEBHOOK_ALLOW_LEGACY_SECRET=true` **before** deploying the updated function, then migrate that gateway to signed delivery and unset the variable.

**`CORS_ALLOWED_ORIGINS`.** Set this to the comma-separated list of origins that must call the Edge Functions from a browser (for example the production site origin). Check the function code for the default used when it is unset, and add any additional web origin before deploying, or browser calls from it fail.

**APNs secrets.** iOS push needs `APNS_KEY`, `APNS_KEY_ID`, `APNS_TEAM_ID` and `APNS_BUNDLE_ID` set as Edge Function secrets (`APNS_SANDBOX` only for development builds; see `supabase/.env.example`). When they are missing, the push functions now report it to Sentry instead of silently skipping iOS devices; treat that Sentry event as a configuration alert.

## Legacy (decommissioned, do not use)

The following existed in earlier versions of this document and no longer apply: the NestJS/Prisma API on Google Cloud Run (`venue-wrangler-api`), `.github/workflows/deploy-api.yml` and its production gate, Secret Manager credential pinning for Cloud Run, the Cloud Run `DATABASE_POOL_SIZE` connection budget, the `retention-cleanup` Cloud Run job, the Expo/EAS clients and `EXPO_PUBLIC_RESTAURANT_CORE_ONLY` edition flags, and `POST /api/v1/pos/connections/:id/rotate-secret`. If any Google Cloud project, Cloud Run service, GKE cluster or AWS account from that era still exists, decommission it and revoke its credentials.

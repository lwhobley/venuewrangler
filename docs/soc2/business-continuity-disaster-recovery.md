# Business Continuity & Disaster Recovery (BC/DR) Plan

**Document Owner**: Principal (Loungeability LLC)
**Last reviewed**: 2026-10-17
**Review Cycle**: Annual

This plan states the recovery capability that exists **today** and the roadmap to improve it. Earlier versions referred to Google Cloud Run, AWS S3, Prisma migrations and semi-annual restore drills to a staging environment. None of those apply to the current product or were performed; they have been removed.

---

## 1. Objectives & metrics

| Objective | Current | Notes |
|---|---|---|
| **RPO** (data loss tolerated) | **Up to 24 hours** | Based on the nightly logical backup. Supabase point-in-time recovery (PITR) is **not** enabled. Enabling PITR (paid add-on) would reduce RPO to minutes and is recommended because the product holds payroll and time records. |
| **RTO** (time to restore) | **Not yet measured** | No restore had been timed before the restore drill workflow was added. The drill's run duration provides the first measurement. A target of 24 hours is a goal, not a tested figure. |

---

## 2. System architecture (what must be recovered)

- **Database, authentication and Edge Functions**: Supabase (Postgres 15). Schema is reproducible from `supabase/migrations`; Edge Functions from `supabase/functions`.
- **File storage**: Supabase Storage buckets (photos, documents, chat attachments, incident evidence).
- **Web app and marketing site**: Cloudflare Pages (`dist-site`, built by `.github/workflows/deploy-cloudflare-pages.yml`).
- **Backups**: Cloudflare R2 bucket (database dumps and Storage mirror).
- **Mobile apps**: built and signed in Codemagic and distributed through TestFlight/App Store and Google Play. Signing identities live in Codemagic and Play App Signing.
- **Other providers** (Stripe, Resend, Groq, Firebase/APNs, Sentry): replaceable; their configuration is in Supabase secrets.

There is **no staging environment**. There is a single production Supabase project.

---

## 3. Backups

| Control | State |
|---|---|
| Nightly database backup | `.github/workflows/supabase-database-backup.yml`, 04:00 UTC. `pg_dump` of `public`, `app_hidden`, `auth` and `storage`, verified readable with `pg_restore --list`, compressed, **encrypted client-side with age**, uploaded to R2 as `database-backups/*.dump.gz.age`, size verified. The job fails if the age recipient is not configured. |
| Storage mirror | `.github/workflows/supabase-storage-backup.yml`, 05:00 UTC, full mirror to R2 plus a 30-day journal of changes/deletions; file counts and bytes are compared. |
| Retention | 30 days, via an R2 lifecycle rule that must exist on the bucket **[verify in Cloudflare]** |
| Immutability | R2 bucket lock / versioning is recommended and **not evidenced**. The backup token can currently overwrite or delete backups. Roadmap: bucket lock with a retention period on `database-backups/` and a separate read-only token for restores |
| Key custody | The age **private** identity is held offline, never in the backup job. The restore drill uses it from a protected GitHub Environment |
| PITR | Not enabled (see RPO) |

**A restore has not yet been verified.** Treat the backups as unproven until `Supabase Restore Drill` completes successfully at least once.

### 3.1 Restore drill

`.github/workflows/supabase-restore-drill.yml` runs monthly (1st, 07:00 UTC) and on demand. It downloads the newest `.dump.gz.age` from R2, decrypts it, restores it with `pg_restore` into a throwaway `supabase/postgres` container, asserts that `organizations`, `venues`, `memberships` and `auth.users` contain rows, checks the newest backup is under 36 hours old, and prints a summary of counts only. It fails loudly otherwise and uploads nothing. The run log is the SOC 2 evidence for recovery testing. Status: **not yet run**.

Semi-annual full disaster-recovery exercises (rebuilding a new Supabase project from migrations plus the dump and pointing the app at it) have **not been performed**. Roadmap: run one once a safe scratch Supabase project is available and record its duration as the first measured RTO.

---

## 4. Recovery scenarios

### A. Bad web release
1. Open the Cloudflare Pages project, find the last good deployment and roll back to it (or `git revert` and let the deploy workflow redeploy).
2. Verify `https://venuewrangler.com/app/` loads and sign-in works.

### B. Bad database migration or data corruption
1. Stop making further changes. If PITR is not enabled, the recovery point is the last nightly backup (up to 24 hours of data lost).
2. Create a new Supabase project. Apply `supabase/migrations` in order, or restore the latest decrypted dump into it (`pg_restore --no-owner`), following the same steps as the restore drill workflow.
3. Verify row counts and sign-in in the new project.
4. Point the app at the new project by updating the Supabase URL and anon key in `FLUTTER_PRODUCTION_ENV_JSON` and Codemagic and shipping a new release, and update the Content-Security-Policy host in `site/_worker.js`. Re-set Edge Function secrets in the new project and re-register provider webhooks (Stripe, POS, OAuth redirect URLs).
5. Mobile clients already in the field still point at the old project until updated. **This is the slowest step and is not rehearsed.**

### C. Supabase regional or provider outage
No secondary region or provider exists; recovery is waiting for Supabase, or scenario B in a new project. Not rehearsed.

### D. Loss of the age identity
Backups become unreadable. Keep two offline copies of the identity (see `docs/security/secrets-handling.md`).

### E. Loss of the operator account or machine
GitHub, Supabase, Cloudflare, Stripe and Codemagic are each recoverable only through that vendor's account recovery. There is no second administrator. Roadmap: add a break-glass second owner on critical accounts and keep recovery codes offline.

---

## 5. Roadmap (not yet implemented)

1. Run the restore drill successfully and record the result.
2. Enable Supabase PITR; re-baseline RPO.
3. R2 bucket lock and a read-only token for restores; verify the 30-day lifecycle rule.
4. A staging Supabase project for migration rehearsal and DR exercises.
5. A documented, rehearsed project-rebuild runbook and a measured RTO.

# Data Classification, Retention & Disposal Policy

**Document Owner**: Principal (Loungeability LLC)
**Last reviewed**: 2026-10-17
**Review Cycle**: Annual

States current behaviour as implemented in `supabase/migrations`, and separates roadmap items. See also the privacy policy (`docs/privacy-policy.md`), which must stay consistent with this document.

---

## 1. Purpose & Scope

Data classification, retention and disposal for data processed by Venue Wrangler. For staff and guest data entered by venues, **the venue is the controller and Venue Wrangler is the processor**; for account, billing and security data Loungeability LLC is the controller.

---

## 2. Data classification

| Tier | Description | Examples | Controls today |
|---|---|---|---|
| **Restricted** | Disclosure causes severe harm | Service-role keys, database credentials, signing keys, OAuth client secrets, payroll/POS OAuth tokens, age backup identity, auth password hashes | Supabase/GitHub/Codemagic secret stores; never in the repository; backups of the `auth` schema are encrypted client-side |
| **Confidential** | Personal and business data of customers | Staff names, emails, phones, schedules, time entries and punch GPS, HR pay data, guest records and allergy notes, reservations, chat, incident reports and photos | Tenant isolation by RLS, role-based access, TLS in transit, encryption at rest by the providers |
| **Internal** | Non-public company information | Internal audits, architecture notes | The repository is currently public; internal audit documents should not be published (decision pending) |
| **Public** | Intended for publication | Marketing site, terms, privacy policy | Served over HTTPS |

---

## 3. Retention

| Data | Retention | Mechanism | Status |
|---|---|---|---|
| Active tenant operational data | While the subscription/account is active | Deleted when the venue or account is deleted | Implemented (self-deletion); tenant offboarding workflow partial |
| `audit_log` | 365 days; `time_entry.correct` / `time_entry.void` rows 3 years | Daily pg_cron job `retention-cleanup` calling `app_hidden.run_retention_cleanup()` (06:17 UTC) | Implemented |
| Wage and time records the law requires (retained time entries and wage profiles) | 3 years | Same job; held in restricted tables with no foreign key to the venue or the departed user | Implemented |
| Raw GPS on finished time punches | 365 days by default (`app_hidden.platform_settings.gps_retention_days`) | Same job nulls the coordinates; times and verdicts are kept | Implemented in migration `20261017110000` (confirm applied) |
| Raw POS webhook payloads | 90 days | Same job nulls `raw_payload` | Same migration |
| Guest PII on finished reservations | Anonymized after 24 months | Same job | Same migration |
| Invites | Resolved: 90 days; pending: 30 days after expiry | Same job | Same migration |
| Notification events | 180 days | Same job | Same migration |
| Device attestation challenges | Purged an hour after expiry | Same job | Implemented |
| Rate-limit counters | 2 days | Same job | Same migration |
| Database backups (Cloudflare R2, age-encrypted) | 30 days | R2 lifecycle rule on `database-backups/` | Partial **[verify rule in Cloudflare]** |
| Storage mirror change journal | 30 days | R2 lifecycle rule on `storage-changes/` | Partial **[verify rule in Cloudflare]** |
| Error diagnostics (Sentry) | About 30 days | Sentry project setting | **[verify in Sentry]** |
| Email delivery records (Resend) | Per Resend defaults | Resend | **[verify in Resend]** |

---

## 4. Account deletion & data-subject requests

**Self-deletion (implemented).** A signed-in user can delete their own account in the app (Settings, Delete account; `public.request_account_deletion`). A user who is the sole owner of an organization is blocked until another owner exists. Deletion removes the sign-in and profile; wage records the law requires are retained in a restricted store for 3 years; files the user uploaded into a venue remain the venue's records, and the user's own profile photo is queued for deletion from Storage via `storage_deletion_jobs`. Pseudonymous traces (for example identifiers in older audit rows) are scrubbed by the privacy migration where applied; confirm with the migration notes.

**Guest and lead erasure.** `erase_guest` (migration `20261017110000`, confirm applied) anonymizes reservation guest fields, removes CRM notes/activity/leads and POS guest names for a guest. There is no in-app button for guests themselves; venues request it.

**Requests by email.** Requests to `admin@venuewrangler.com` are answered within 30 days **by manual process**; no ticketing or SLA tracking exists. For venue-controlled data the request is forwarded to the venue.

**Tenant offboarding.** Final-owner deletion of an organization cascades its data; media purge runs through the deletion outbox and a worker. Written confirmation of destruction is a manual process and is not automated or evidenced.

**Backups.** Deleted data persists in backups for up to 30 days and is not individually removed.

---

## 5. Media & workstation sanitization

- **Cloud storage**: managed by Supabase and Cloudflare; deletion relies on their provider-side erasure.
- **Workstations**: no formal sanitization procedure is performed. Roadmap: document wipe steps for retired devices; and keep the repository and credentials off cloud-synced folders (see `docs/security/secrets-handling.md`).

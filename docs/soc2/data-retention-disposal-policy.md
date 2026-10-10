# Data Classification, Retention & Disposal Policy

**Document Owner**: Security & Engineering  
**Effective Date**: August 2026  
**Review Cycle**: Annual  

---

## 1. Purpose & Scope

This policy defines the data classification tiers, retention periods, and secure cryptographic sanitization and disposal procedures for customer records, employee information, and audit trails processed by Venue Wrangler.

---

## 2. Data Classification Matrix

| Classification Tier | Description | Examples | Protection Controls |
|---------------------|-------------|----------|---------------------|
| **Restricted (Confidential)** | Highly sensitive business or security assets whose disclosure causes severe operational or financial harm. | Passwords (salted/hashed), POS connection secrets, Stripe customer IDs, JWT signing secrets, database credentials. | One-way hashing (PBKDF2/SHA-256), encrypted secrets manager, never logged, excluded from API responses. |
| **Confidential (PII & Business Data)** | Sensitive customer operational and personal data. | Staff names, phone numbers, email addresses, shift schedules, time-clock entries, payroll exports, reservations, guest notes. | Multi-tenant isolation enforced, TLS in transit, AES-256 at rest, role-based access control. |
| **Internal** | Non-public company documentation and aggregated operational telemetry. | System architectures, internal Slack communications, aggregated analytics. | Authentication required, internal access only. |
| **Public** | Information intended for public distribution. | Marketing website content, public help documentation, Terms of Service, Privacy Policy. | Publicly accessible over HTTPS. |

---

## 3. Data Retention Lifecycle

| Data Category | Retention Window | Storage Medium | Deletion Method |
|---------------|------------------|----------------|-----------------|
| **Active Tenant Operational Data** | Duration of active subscription | Supabase PostgreSQL | Hard delete cascade upon tenant offboarding request. |
| **Nightly Database Backups** | **30 Days** | Encrypted AWS S3 Bucket | Automated S3 Lifecycle Rule (`Expire after 30 days`). |
| **Security & System Audit Logs** | **365 Days** (1 Year) | PostgreSQL `AuditLog` table | Automated hard deletion by the daily `retention-cleanup` pg_cron job in Supabase. No immutable archive is currently claimed. |
| **Application Error Traces (Sentry)** | **30 Days** | Sentry Cloud | Automated Sentry retention expiration. |
| **Device Attestation Challenges** | **5 Minutes** | PostgreSQL `AttestationChallenge` | Ephemeral single-use expiration. |

---

## 4. Account Deletion & "Right to be Forgotten" Protocol

**Implementation status**: Non-owner self-deletion (items 1, 4, 5 below) is implemented —
`public.request_account_deletion`, `supabase/migrations/20261007180000_account_deletion.sql`,
exposed in-app via Settings → Delete account. Tenant offboarding (items 2's cascade-deletion
half and item 3's media purge) is **not yet implemented**; a user who is the sole
`organization_owner` of any organization is blocked from self-deleting rather than triggering
it, with a message to add another owner first. Item 6 (written confirmation within 30 days)
is a process commitment, not a system behavior, and isn't automated by anything below.

When a customer cancels their subscription or requests account deletion under GDPR/CCPA:
1. **Verification**: Request must originate from the authenticated account itself (the
   in-app flow requires an active, signed-in session — there is no separate out-of-band
   verification step for a request made by the account owner directly).
2. **Cascade Deletion**: A final owner can explicitly confirm tenant offboarding in the app; the API deletes all venue-owned models (profiles, shifts, time entries, floor plans, reservations) transactionally. Non-owner account deletion removes only that user's account and profile.
3. **Media Purge**: On tenant offboarding, the venue's images and documents are written to a durable deletion outbox in the same transaction. The API attempts deletion immediately and retries failed AWS S3 deletes hourly, escalating a job for manual review after repeated failures rather than retrying indefinitely. Non-owner account deletion purges that user's own profile photo the same way (queued via `storage_deletion_jobs`); it does not purge venue media: files uploaded into a venue are that venue's operational records and are removed when the venue is deleted.
4. **Anonymization**: Timeclock or audit records belonging to the departing account that are retained for legal/tax purposes replace personal names and emails with synthetic identifiers (`deleted_user_[profile_id]`). Records belonging to *other* employees at the venue keep their identifying name, because FLSA §516.2 requires wage records to be attributable to the employee who worked them.
5. **Wage-record retention**: Before a venue is deleted, its timeclock rows are copied to `RetainedTimeEntry` (`public.retained_time_entries`), which holds no foreign key to the venue, organization or the departed user's `auth.users` row and therefore survives both this deletion and any future venue/org cascade. This preserves the FLSA-required three-year payroll history for *all* staff at that venue, not only the account being deleted.
6. **Confirmation**: Written confirmation of data destruction is provided to the customer within 30 days.

---

## 5. Media & Workstation Sanitization

* **Cloud Storage**: Cloud disks (Cloud Run container ephemeral storage, Supabase volumes) are encrypted with provider-managed cryptographic erasure upon deletion.
* **Employee Devices**: When laptops or storage drives reach end-of-life or are returned upon employee separation, drives undergo cryptographic zeroing (NIST SP 800-88 Rev. 1 compliant sanitize command).

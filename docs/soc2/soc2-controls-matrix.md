# Venue Wrangler SOC 2 Controls Matrix

Last reviewed: 2026-10-17. **This is an honest self-assessment, not an attestation.** Venue Wrangler is operated by a very small team and has **not** undergone a SOC 2 Type I or Type II examination. The matrix maps AICPA Trust Services Criteria to what exists in the repository today. Earlier versions of this file described controls (mandatory pull-request reviews, branch protection, AWS S3 backups with automated restore verification, semi-annual DR drills, quarterly executive reviews) that were not operated; those claims have been removed.

## Status legend

| Status | Meaning |
|---|---|
| **Implemented** | The control exists and operates today; the evidence pointer shows where to verify it. |
| **Partial** | Part of the control exists; the gap is stated. |
| **Planned** | Designed or scheduled but not yet operating. Do not describe it as in place. |
| **Not operated** | A control a SOC 2 auditor would expect, which is not performed today. |

Where a control depends on a GitHub, Supabase or Cloudflare dashboard setting that cannot be seen in the repository, it is marked **[verify in dashboard]**. Record evidence in `docs/security/hosted-auth-settings.md` and `docs/security/secrets-handling.md` as settings are applied.

---

## 1. Common Criteria (Security)

### CC1: Control Environment

| Criterion | Control | Status | Evidence / gap |
|---|---|---|---|
| CC1.1 | Commitment to integrity and ethics | **Partial** | Policies exist in `docs/soc2/`. There is one principal; no code-of-conduct acknowledgements, annual or otherwise, are collected. |
| CC1.2 | Oversight by leadership | **Not operated** | One-person company; no independent oversight body and no quarterly risk-register or KPI review is performed. Roadmap: calendar a quarterly self-review and record minutes. |
| CC1.3 | Structure and assignment of authority | **Partial** | Role-based access exists in the product (`memberships`, RLS). Vendor-console access is held by the owner alone; there is no separation of duties. `.github/CODEOWNERS` records ownership. |
| CC1.4 | HR practices (screening, offboarding) | **Not operated** | No employees besides the owner; no background-check or offboarding procedure has been exercised. Roadmap: written onboarding/offboarding checklist before the first hire or contractor. |

### CC2: Communication and Information

| Criterion | Control | Status | Evidence / gap |
|---|---|---|---|
| CC2.1 | Internal security communication | **Partial** | Policies are in this folder; there is no training programme or alerting channel. |
| CC2.2 | Incident reporting channel | **Partial** | `docs/soc2/incident-response-plan.md` defines the process and a contact address; it has not been exercised in a drill. |
| CC2.3 | External communication | **Partial** | Privacy policy (`docs/privacy-policy.md`, `site/privacy/index.html`) and terms are published; the privacy policy is a draft awaiting counsel review. |

### CC3: Risk Assessment

| Criterion | Control | Status | Evidence / gap |
|---|---|---|---|
| CC3.1 | Risk assessment process | **Partial** | An internal security audit was performed on 2026-10-17 and its remediation is tracked; there is no recurring, documented annual risk assessment or risk register. |
| CC3.2 | Fraud risk | **Partial** | Server-side rate limiting exists in Edge Functions (`supabase/functions/_shared/rate-limit.ts`). Time-clock location is client-reported and can be spoofed; geofencing is not fraud-proof (audit F-01). |

### CC4: Monitoring Activities

| Criterion | Control | Status | Evidence / gap |
|---|---|---|---|
| CC4.1 | Evaluation of controls | **Partial** | CI runs tests, CodeQL for JavaScript/TypeScript (`.github/workflows/codeql.yml`), pgTAP RLS tests (`supabase-ci.yml`), `npm audit` for production dependencies (`site-ci.yml`, deploy workflow) and a frozen Deno lockfile. CodeQL does not cover Dart or SQL. There is no vulnerability scanning of the Flutter (pub) dependencies beyond Dependabot. |
| CC4.2 | Communication of deficiencies | **Partial** | Sentry captures client and Edge Function errors; `public.ops_health_report()` surfaces silent failures where the migration is applied. No paging or on-call rota. |

### CC5: Control Activities

| Criterion | Control | Status | Evidence / gap |
|---|---|---|---|
| CC5.1 | Control activities that mitigate risk | **Implemented** | Authorization is enforced in Postgres: row-level security on tenant tables, helper functions in the unexposed `app_hidden` schema, `to authenticated` policies, trigger-derived ownership columns (`supabase/migrations`, tests in `supabase/tests/database`). |
| CC5.2 | Technology general controls | **Partial** | Hosting by Supabase and Cloudflare (managed). Strict CSP and security headers on the web app (`site/_worker.js`) and marketing site (`site/_headers`, inline scripts allowed by hash only). |
| CC5.3 | Policies and procedures | **Partial** | This policy set; several documents describe aspirations alongside current state, which each document now separates. |

### CC6: Logical and Physical Access

| Criterion | Control | Status | Evidence / gap |
|---|---|---|---|
| CC6.1 | Logical access security | **Partial** | Supabase Auth (hashed passwords, JWT sessions, refresh-token rotation). Local config now requires 12-character passwords with mixed case and digits; **the hosted project must be updated by hand** (`docs/security/hosted-auth-settings.md`) **[verify in dashboard]**. Leaked-password protection and CAPTCHA are not enabled until applied. |
| CC6.2 | Registration and credential management | **Partial** | Email confirmation is required in config; invitation redemption requires a verified email. Offboarding of members (deprovisioning, role change, ownership transfer) has known gaps tracked from the audit. |
| CC6.3 | Role-based access | **Implemented** | Roles via `memberships` and RLS; membership resolved live, not from stale JWT claims. Known segregation-of-duties gaps (managers approving their own requests, admins editing their own pay) are tracked. |
| CC6.4 | Physical access | **Implemented (inherited)** | Delegated to Supabase and Cloudflare data centres. Obtain their current SOC 2 reports; none are on file yet (see vendor policy). |
| CC6.5 | Disposal of data and media | **Partial** | In-app account deletion and scheduled retention cleanup exist (`app_hidden.run_retention_cleanup()`); guest erasure and some purges are in recently added migrations. No documented device-sanitization procedure. |
| CC6.6 | Boundary protection | **Partial** | All access is via Supabase APIs over TLS; Postgres direct access network restrictions not confirmed **[verify in dashboard]**. |
| CC6.7 | Data transmission protection | **Implemented** | TLS everywhere; HSTS on the site (`site/_headers`, `site/_worker.js`). Database backups are encrypted client-side with `age` before upload (`supabase-database-backup.yml`) once `BACKUP_AGE_RECIPIENT` is configured; the first encrypted run is not yet recorded. |
| CC6.8 | Malicious software prevention | **Implemented** | Uploaded documents are scanned (ClamAV / Cloudmersive) and rejected if unscanned (`supabase/functions/documents-upload`). |

### CC7: System Operations

| Criterion | Control | Status | Evidence / gap |
|---|---|---|---|
| CC7.1 | Vulnerability detection | **Partial** | Dependabot (npm, pub, GitHub Actions), `npm audit` gate, CodeQL (JS/TS), GitHub secret scanning and push protection **[verify in dashboard]**. No SBOM, no Dart/SQL static analysis in CI beyond `dart analyze`. |
| CC7.2 | Monitoring for anomalies | **Partial** | Sentry; audit log (`public.audit_log`) retained 365 days. No alerting rules or log review procedure. |
| CC7.3 | Security event evaluation | **Partial** | Incident Response Plan exists; never exercised. |
| CC7.4 | Incident response | **Planned** | Plan to be exercised with a tabletop exercise (roadmap in `incident-response-plan.md`). |
| CC7.5 | Recovery from incidents | **Partial** | See A1.2/A1.3: backups exist, restore proven only after the first successful drill run. |

### CC8: Change Management

| Criterion | Control | Status | Evidence / gap |
|---|---|---|---|
| CC8.1 | Authorized, tested changes | **Partial** | **Branch protection and mandatory pull-request review are NOT enabled on `main`** (the repository API reports no protection); changes can be pushed directly. What does exist: CI test jobs, SHA-pinned Actions, least-privilege workflow permissions, `.github/CODEOWNERS` and a PR checklist (`.github/pull_request_template.md`), and the production deploy job is bound to a GitHub `production` environment (reviewers must be configured **[verify in dashboard]**). Database migrations and Edge Functions are applied by hand from the operator's machine; there is **no staging environment**. |
| CC8.2 | Deployment and rollback | **Partial** | Web deploys via `deploy-cloudflare-pages.yml`; rollback is redeploying a previous commit/Pages deployment (`docs/production-operations.md`). Database changes are forward-only; no rehearsed rollback. |

### CC9: Risk Mitigation

| Criterion | Control | Status | Evidence / gap |
|---|---|---|---|
| CC9.1 | Business disruption risk | **Partial** | `docs/soc2/business-continuity-disaster-recovery.md` states current recovery capability honestly (RPO up to 24 hours, RTO untested). |
| CC9.2 | Vendor risk management | **Partial** | Subprocessor list maintained (`docs/soc2/vendor-management-policy.md`); no vendor SOC 2 reports or DPAs are filed yet; no annual review has been performed. |

---

## 2. Availability

| Criterion | Control | Status | Evidence / gap |
|---|---|---|---|
| A1.1 | Capacity and availability management | **Partial** | Capacity is managed by Supabase and Cloudflare. No load testing and no documented capacity thresholds. |
| A1.2 | Backup, recovery infrastructure | **Partial** | Nightly logical `pg_dump` (public, app_hidden, auth, storage schemas) uploaded to **Cloudflare R2** (not AWS S3), encrypted client-side with `age` (`.github/workflows/supabase-database-backup.yml`); daily Storage mirror (`supabase-storage-backup.yml`). **A restore has not yet been verified.** The restore drill (`supabase-restore-drill.yml`) exists but has not yet run; until it passes, treat backups as unproven. RPO is up to 24 hours; Supabase PITR is not enabled. No object lock or versioning is evidenced on the R2 bucket **[verify in dashboard]**. |
| A1.3 | Recovery testing | **Not operated** | Semi-annual DR drills have **not** been performed. The monthly automated restore drill is the planned control; its first successful run is the first piece of evidence. There is no staging environment. |

---

## 3. Confidentiality

| Criterion | Control | Status | Evidence / gap |
|---|---|---|---|
| C1.1 | Identification and protection of confidential information | **Partial** | Data classification is defined in `docs/soc2/data-retention-disposal-policy.md`. Tenant isolation by RLS; line staff can currently read some guest and incident data they may not need (tracked). |
| C1.2 | Disposal of confidential information | **Partial** | Retention cleanup runs in-database (pg_cron) for the audit log, wage-record store and other short-lived data; backups expire after 30 days if the R2 lifecycle rule is configured **[verify in dashboard]**. No documented evidence of deletion requests being completed within SLA. |

---

## 4. Privacy (not in the committed scope, tracked for honesty)

| Criterion | Control | Status | Evidence / gap |
|---|---|---|---|
| P1 | Privacy notice | **Partial** | One privacy notice (`docs/privacy-policy.md` mirrored in `site/privacy/index.html`) describing controller/processor roles and the real subprocessors; draft pending counsel review. The sign-up flow link/acceptance is being added in the app. |
| P3-P4 | Collection, use and retention | **Partial** | Retention schedule in the policy matches `supabase/migrations`. |
| P5 | Access and correction, deletion | **Partial** | In-app self-deletion; guest erasure function in a recent migration; email requests answered within 30 days by process only. |
| P6 | Disclosure to third parties | **Partial** | Subprocessors listed; DPAs and international-transfer mechanism not yet on file **[counsel to confirm]**. |

---

## 5. Evidence log

| Evidence | Where |
|---|---|
| Restore drill result | GitHub Actions run summary of `Supabase Restore Drill` (none yet) |
| Encrypted backup run | GitHub Actions run of `Supabase Database Backup` with `.dump.gz.age` object |
| Hosted auth settings applied | `docs/security/hosted-auth-settings.md` applied-settings log |
| Secret rotations | `docs/security/secrets-handling.md` rotation log |
| Branch protection / environments | GitHub screenshots, once configured |

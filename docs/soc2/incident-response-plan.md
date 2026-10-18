# Security Incident Response Plan (IRP)

**Document Owner**: Principal (Loungeability LLC)
**Last reviewed**: 2026-10-17
**Review Cycle**: Annual

Venue Wrangler is run by one person. There is no on-call rota and no dedicated security team, and this plan has **never been exercised**. The service levels below are targets for a one-person operation, not guarantees. Earlier versions referenced a Cloud Run API, NestJS, a `Session` table and a 24/7 on-call engineer; those do not exist.

---

## 1. Objective & scope

Detect, triage, contain, remediate and document incidents affecting customer data, the Supabase project, Edge Functions, the Cloudflare site, the mobile apps, or the credentials that control them.

---

## 2. Severity

| Severity | Definition | Examples | Target first response | Target containment |
|---|---|---|---|---|
| **SEV-1** | Confirmed or likely unauthorized access to customer data, leaked production credentials, or total outage | Leaked service-role key, RLS bypass actively exploited, backup bucket exposed | Same day, as soon as noticed (best effort outside business hours) | 24 hours |
| **SEV-2** | Exploitable vulnerability without evidence of exploitation, partial outage, third-party provider incident affecting us | Cross-tenant read bug reported, Stripe key exposed in a log | 1 business day | 3 days |
| **SEV-3** | Moderate issue with compensating controls | Dependency with a high CVE, rate-limit bypass | 3 business days | 2 weeks |
| **SEV-4** | Low or informational | Header misconfiguration, scanner noise | Next planning cycle | Next release |

---

## 3. Workflow

1. **Detect.** Sources today: Sentry error alerts, GitHub secret-scanning/Dependabot/CodeQL alerts, Supabase and Cloudflare notifications, reports to `admin@venuewrangler.com`, and customer reports. A dedicated `security@` address and a published security contact page/`security.txt` are not yet in place (roadmap). There is no automated alerting on audit-log anomalies.
2. **Triage.** Record the time, what was observed, which tenants may be affected, and set a severity. Keep a timeline in a private document.
3. **Contain.**
   - Leaked credential: rotate it using `docs/security/secrets-handling.md` (Stripe, Supabase service-role/JWT secret, database password, Cloudflare, signing keys), then revoke the old value.
   - Vulnerable web build: roll back the Cloudflare Pages deployment to the last good one.
   - Vulnerable Edge Function or policy: ship a fix migration/function, or disable the function in the Supabase dashboard.
   - Compromised user: remove the membership and revoke the session in the Supabase dashboard.
   - Compromised GitHub access: revoke tokens and sessions, review recent commits, workflow runs and secrets, disable Actions if needed.
4. **Eradicate and recover.** Fix the root cause with a reviewed change and add a regression test (RLS pgTAP test or Vitest spec). Verify sign-in, core flows and the backup/restore workflows. If data was lost or corrupted, follow `business-continuity-disaster-recovery.md` (RPO up to 24 hours; restore not yet proven).
5. **Notify.** If personal data was or may have been accessed without authorization:
   - Venues are controllers of staff and guest data, so tell affected venues without undue delay, with what happened, what data, what we did and what they should do.
   - Regulators and individuals: notification duties depend on jurisdiction (for example GDPR 72 hours to the regulator, US state laws, POPIA). **[counsel to confirm timelines and who notifies.]** The 72-hour figure is a working assumption for the controller's duty, not a legal conclusion.
6. **Learn.** Write a short post-incident review within a week: timeline, root cause, impact, and action items with owners and dates; update this plan.

---

## 4. Evidence to preserve

Supabase auth and API logs (note the retention window of the plan), `public.audit_log`, Cloudflare logs, GitHub audit log and Actions history, Sentry events. Export before the retention windows elapse.

---

## 5. Roadmap

- Run a tabletop exercise (leaked key scenario) and record the result.
- Publish a security contact (`security@venuewrangler.com`, `/.well-known/security.txt`).
- Alerting on `ops_health_report()` findings, failed backups and failed restore drills (GitHub Actions failure notifications are the minimum).
- Add a second trusted contact for account recovery and incident help.

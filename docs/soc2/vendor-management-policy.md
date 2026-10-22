# Vendor Management & Subprocessor Policy

**Document Owner**: Principal (Loungeability LLC)
**Last reviewed**: 2026-10-17
**Review Cycle**: Annual

---

## 1. Purpose & Scope

Selection, risk evaluation and monitoring of third parties that store, process or transmit customer data or support production. This list must match the privacy policy (`docs/privacy-policy.md`, `site/privacy/index.html`) and the notes in `docs/production-operations.md`. Update all three together.

Google Cloud Platform, Amazon Web Services (S3), Apple In-App Purchase and Google Gemini appeared in earlier versions of this document. The current code does not use them and they have been removed. If a legacy GCP or AWS account still exists, decommission it and revoke its credentials (see the manual-only Prowler workflow).

---

## 2. Subprocessors (verified against the code)

Columns "DPA on file", "SOC 2 / ISO report on file" and "Last review" record evidence. **None has been collected yet**, so each reads "No" until the operator files it. Certifications are what the vendors publicly claim; verify before relying on them.

| Subprocessor | Service | Data | Evidence in repo | DPA on file | Report on file | Last review |
|---|---|---|---|---|---|---|
| **Supabase** | Postgres, Auth, Storage, Edge Functions | All application data | `supabase/` | No | No | Never |
| **Cloudflare** | Pages hosting, CDN, R2 backups | Web traffic metadata; encrypted backups and file mirrors | `site/`, backup workflows | No | No | Never |
| **Stripe** | Subscription billing | Billing contact, subscription IDs; card data goes to Stripe directly | `supabase/functions/stripe-*` | No | No | Never |
| **Resend** | Transactional email | Recipient email, name, message content | `supabase/functions/crm-send-email`, `supabase/functions/invite-send-email` | No | No | Never |
| **Sentry** | Error diagnostics | Technical error data | `_shared/observability.ts`, `error_reporter.dart` | No | No | Never |
| **Groq** | AI assistant, only when an organization enables AI | Text and context submitted to the assistant | `_shared/groq.ts` | No | No | Never (confirm zero-retention setting) |
| **Google (Firebase Cloud Messaging)** | Android push | Push token, notification content | `_shared/push-delivery.ts` | No | No | Never |
| **Apple (APNs)** | iOS push | Push token, notification content | `_shared/apns.ts` | No | No | Never |
| **Google Play Integrity / Apple App Attest** | Device integrity | Attestation tokens | `device-attestation` function | No | No | Never |
| **Cloudmersive** / **ClamAV** (self-hosted) | Malware scanning of uploads | The uploaded file | `_shared/malware-scan.ts` | No | No | Never |
| **Square, Toast, QuickBooks (Intuit), Gusto** | Optional customer-connected POS / payroll / accounting | Whatever the venue authorizes | `supabase/functions/*-oauth`, `toast-pos` | No (venue's own agreements; verify OAuth app terms) | No | Never |
| **Codemagic** | iOS build and signing | Source, signing identities, build secrets | `codemagic.yaml` | No | No | Never |
| **GitHub** | Source, CI | Source code, CI secrets | `.github/` | No | No | Never |

Codemagic and GitHub process no customer data but hold signing and deployment credentials, so they are included for access-risk purposes.

---

## 3. Onboarding criteria (applies to any new vendor)

1. Identify the data it will touch and update the privacy policy and this list **before** go-live.
2. Obtain a current SOC 2 Type II report or ISO 27001 certificate where the vendor has one, and a signed DPA with Standard Contractual Clauses where personal data is transferred outside the EU/UK **[counsel to confirm]**.
3. Require TLS in transit and encryption at rest.
4. Use the narrowest API key or OAuth scope available; store it as a Supabase secret.
5. For AI providers: confirm training and retention settings and keep the feature opt-in per organization.

---

## 4. Annual review (roadmap; not yet performed)

Once a year: collect updated reports, confirm DPAs, review scopes and rotate keys (`docs/security/secrets-handling.md`), and check each vendor's incident disclosures. **No annual review has been performed to date.** First review target: record the date in the table above.

---

## 5. Subprocessor changes

Customers should be told before a subprocessor is added. Mechanism (notice period, objection right) is **[counsel/operator to confirm]** and is not yet automated.

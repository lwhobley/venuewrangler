# Venue Wrangler Privacy Policy

Last updated: October 17, 2026 (DRAFT for counsel review)

> **Maintainer notes (remove before publishing; the published copy is `site/privacy/index.html`, which must say the same thing).**
> - This file and `site/privacy/index.html` are one policy. Edit both together, and edit the subprocessor list in `docs/production-operations.md` at the same time.
> - Items marked **[counsel to confirm]** are legal wording or conclusions that have not been reviewed by a lawyer.
> - Items marked **[operator to confirm]** are facts that depend on production configuration (regions, plan, dates) that the repository cannot show.
> - The retention periods below match `supabase/migrations`. The shorter purges (raw POS payloads, guest data on old reservations, invites, notification events, raw GPS) are defined in `20261017110000_audit_privacy_retention_and_evidence.sql`; confirm that migration is applied to production before publishing.
> - Sections 4 and 8 describe the in-app AI consent and organization AI switch; confirm the release containing them is live before publishing.

## 1. Who we are

Venue Wrangler (the "service": a mobile and web app for running restaurants, bars and venues) is operated by **Loungeability LLC** ("we", "us").

**Our role depends on whose data it is.**

- **Venues are the controllers of staff and guest data.** A venue (the "customer") decides what staff, guest, reservation, schedule, time-clock, chat, inventory and other operational data it puts into Venue Wrangler and why. For that data, **Loungeability LLC acts as a processor (service provider)** and handles it only on the venue's instructions and to provide the service. If you are a staff member or a guest of a venue and have a question about how your venue uses your data, or want to exercise your rights over it, contact the venue first. We will help the venue respond.
- **Loungeability LLC is the controller** of the data we need to run our own business: account and sign-in data for the people who use the app, billing and subscription records, security and audit logs, support correspondence, and website visitor data.

Contact: **admin@venuewrangler.com** (privacy requests and questions). Postal address and any EU/UK/South Africa representative or Information Officer details: **[operator to add; counsel to confirm]**.

## 2. What we collect

| Category | Examples | Why | Whose data / our role |
|---|---|---|---|
| Account data | Name, email address, role, venue membership, profile photo (optional), sign-in credentials (passwords are stored only as salted hashes by our authentication provider) | Sign-in, showing your team who you are, access control | Controller for sign-in; processor for the venue's staff directory |
| Work data | Schedules, shift swaps and requests, tasks, chat messages and attachments, announcements, incident reports and evidence photos, inventory counts, floor plans, documents you upload | Operating the venue | Processor |
| Time-clock data | Clock-in and clock-out times, and **GPS coordinates and accuracy at the moment of each punch**, used to check you are at the venue. We do not track location in the background. | Time and attendance, wage records | Processor |
| Photos and files | Profile photos, incident evidence, documents, count sheets, chat attachments. Photos may contain location metadata (EXIF) if your device adds it. | Operating the venue | Processor |
| Guest data | Guest names, phone numbers, email addresses, reservation details, party size, visit history, dietary/allergy and preference notes, CRM leads and contract details a venue enters | Reservations and hospitality operations | Processor |
| HR and pay data | Employee number, hourly rate, PTO balances, employment details a venue enters | Scheduling, payroll export | Processor |
| Point-of-sale data | Check and order data received from a POS the venue connects, which can include a guest name | Reporting | Processor |
| Billing data | Organization and subscription status, Stripe customer ID. Card numbers go directly to Stripe and never reach our servers. | Subscription payments | Controller |
| Device and diagnostic data | Push notification tokens, device and platform type, app version, device attestation results, crash and error reports (with sign-in and request details scrubbed where we can) | Notifications, fraud and abuse prevention, reliability | Controller |
| Audit and security logs | Who did what and when (sign-ins, role changes, time corrections, deletions) | Security, accountability, legal compliance | Controller |
| Website data | Standard server logs when you visit venuewrangler.com | Operating and securing the site | Controller |

We do not sell personal data, we do not share it for third-party advertising, and the apps contain no advertising or analytics SDKs.

**Sensitive information.** Guest notes can contain information about allergies or dietary needs, which may be health-related. Venues should enter only what they need. **[counsel to confirm: special-category/sensitive data handling and whether a DPA addendum is needed.]**

## 3. How we use it

To provide and secure the service (scheduling, time clock, reservations, chat, inventory, reporting, billing, notifications); to authenticate users and prevent abuse; to keep records we are legally required to keep; to communicate with you about the service and respond to support requests; and to diagnose and fix errors. Processor data is used only for the venue's purposes.

**Legal bases (GDPR/UK GDPR, where they apply) [counsel to confirm]:** performance of a contract (providing the service); legitimate interests (security, fraud prevention, diagnostics, service improvement); legal obligation (record keeping); and consent where we ask for it (for example, enabling optional AI features). For venue-controlled staff and guest data, the venue determines the legal basis.

## 4. AI assistant

Venue Wrangler includes optional AI features (an assistant and roster import). They are available only when your organization has enabled them, and the app asks you to consent before first use. When used, the text you submit (which may include names, emails, phone numbers and job titles pasted into a roster import) and relevant context are sent to **Groq** to generate a response. Do not submit personal data you do not need to. Groq's handling of retention and training is governed by our agreement and settings with Groq **[operator to confirm zero-data-retention status]**. Organizations that do not enable AI do not send data to Groq.

## 5. Who we share data with (subprocessors)

We use the following service providers to run Venue Wrangler. They process personal data only for us (and, for venue data, on the venue's behalf) and only as needed to provide their service.

| Subprocessor | What for | Data involved |
|---|---|---|
| **Supabase** | Database, authentication, file storage and server-side functions (edge functions) | All application data |
| **Cloudflare** | Website and web-app hosting and delivery (Cloudflare Pages) and encrypted backup storage (Cloudflare R2) | Web traffic metadata; encrypted database backups and file mirrors |
| **Stripe** | Subscription billing and payments | Billing contact, organization and subscription identifiers, payment details (entered directly with Stripe) |
| **Resend** | Transactional email (invitations, notices, verification and recovery emails) | Recipient email address, name, message content |
| **Sentry** | Crash and error diagnostics | Technical error data, device and app information; no intentional personal content |
| **Groq** | AI assistant, **only when the organization enables AI** | The text and context you submit to the assistant |
| **Google Firebase Cloud Messaging** and **Apple Push Notification service** | Delivering push notifications to Android and iOS devices | Device push token and notification content |
| **Google (Play Integrity) and Apple (App Attest)** | Device and app integrity checks | Device attestation tokens |
| **Cloudmersive** and **ClamAV** (self-operated scanner) | Malware scanning of uploaded documents | The uploaded file |
| **Optional integrations the venue connects**: **Square**, **Toast** (point of sale), **QuickBooks (Intuit)** and **Gusto** (payroll/accounting) | Data exchange the venue chooses to enable | Whatever the venue authorizes (for example sales checks, employee and payroll data). These providers act under the venue's own agreement with them. |

We will update this list before adding a provider. **[Mechanism for notifying customers of subprocessor changes: counsel/operator to confirm.]**

We may also disclose information if required by law, to protect rights and safety, or in a business transfer, subject to this policy.

## 6. Who can see your data inside a venue

Venue data is visible to members of that venue according to their role: for example, managers can see schedules, time entries and the GPS recorded at punches, and staff can see their own records and shared schedules. Venue staff can see other members' names and, depending on role, guest and operational records the venue has chosen to share. Different venues cannot see each other's data.

## 7. Retention

| Data | How long |
|---|---|
| Account and operational data | While the venue's subscription and your account are active; removed when the venue or account is deleted (subject to the legal-retention exceptions below) |
| Audit log | 365 days; time-entry correction and void records 3 years |
| Raw GPS coordinates on finished time punches | 365 days by default; the punch times and the on-site verdict are kept with the time record **[operator to confirm the configured value]** |
| Wage and time records the law requires venues to keep | 3 years, held in a restricted legal-hold store separate from the venue and the account |
| Raw point-of-sale webhook payloads | 90 days (parsed check data remains) |
| Guest personal details on past reservations | Anonymized after 24 months |
| Invitations (accepted, declined or expired) | 90 days after resolution; unaccepted pending invitations 30 days after expiry |
| Notification events | 180 days |
| Device attestation challenges | Minutes (single use) |
| Database backups | 30 days, stored encrypted (see Security) |
| Storage file mirror change history | 30 days |
| Error diagnostics (Sentry) | About 30 days **[operator to confirm]** |

When a venue deletes data or an account, copies in backups age out within the backup window above.

## 8. Your rights and how to exercise them

Depending on where you live (for example the EU/UK under GDPR, California under CCPA/CPRA, South Africa under POPIA) **[counsel to confirm which regimes apply]**, you may have the right to **access** your personal data, **correct** it, **delete** it, **object** to or **restrict** certain processing, **receive a portable copy**, and **withdraw consent**. We do not make decisions about you based solely on automated processing, and we do not sell or "share" personal information for advertising.

**How to ask.**
- **Delete your account:** in the app, **Settings, then Delete account**. Your sign-in and profile are removed; wage records a venue must legally keep are retained as described above.
- **Anything else:** email **admin@venuewrangler.com** from the address on your account. We may ask you to verify your identity.
- If your data was entered by a venue (a staff or guest record), tell us which venue; we will pass the request to the venue as controller and assist it, and we will respond to you about our own data.

We aim to respond **within 30 days**. You may also lodge a complaint with your local data-protection authority.

## 9. International transfers

We and our subprocessors may process data in the United States and other countries. Where personal data is transferred from the EU, UK or Switzerland, we rely on an adequacy decision or on **Standard Contractual Clauses** and the UK addendum **[counsel to confirm the transfer mechanism and that SCCs are in place with each subprocessor]**. The region where Supabase stores the database and the jurisdiction of the Cloudflare R2 backup bucket are **[operator to confirm and state here]**. For South Africa (POPIA s72) **[counsel to confirm the basis for cross-border transfer]**.

## 10. Security

We use measures including: encryption in transit (TLS) and encryption at rest by our hosting providers; tenant isolation enforced in the database by row-level security; role-based access control; a security audit log; malware scanning of uploaded documents; secrets kept out of source code; client-side encryption of database backups before they leave our build system; and automated tests and dependency checks in our build pipeline. Multi-factor authentication is available for accounts but **is not yet mandatory for every account**. No system is perfectly secure, and we cannot guarantee absolute security. If a breach affects your personal data, we will notify affected customers and, where required, regulators without undue delay **[counsel to confirm notification commitments, including the 72-hour regulator window]**.

## 11. Children

The service is for venue staff and operators and is not directed at children under 16. Do not use it if you are under 16.

## 12. Changes

We will post updates here and change the date above. For material changes we will notify account holders in the app or by email.

## 13. Contact

Loungeability LLC, **admin@venuewrangler.com**.

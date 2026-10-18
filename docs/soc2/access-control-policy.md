# Access Control & Authentication Policy

**Document Owner**: Principal (Loungeability LLC)
**Last reviewed**: 2026-10-17
**Review Cycle**: Annual

This policy states what is in place today and separates it from the roadmap. Statuses use the legend in [soc2-controls-matrix.md](./soc2-controls-matrix.md).

---

## 1. Purpose & Scope

Identity, authentication, session management and role-based access for the Venue Wrangler application (Flutter app and web app on Supabase) and for the internal systems used to operate it (GitHub, Supabase, Cloudflare, Stripe, Codemagic, Firebase, Apple and Google developer consoles).

---

## 2. Customer Application Access Controls

### 2.1 Roles (Implemented)

Access is decided in Postgres by row-level security using the live `memberships` table (not stale token claims). Roles include `organization_owner`, `organization_admin`, venue manager roles and staff roles; exact permissions are defined by the RLS policies and helper functions in `supabase/migrations` and covered by tests in `supabase/tests/database`.

Known gaps (tracked, not yet closed): no deprovisioning or ownership-transfer flow for members; administrators can edit their own pay data; managers can approve their own staff requests; line staff can read some guest and incident data they may not need.

### 2.2 Passwords

| Item | Current state | Status |
|---|---|---|
| Hashing | Supabase Auth (bcrypt-based salted hashes); the application never sees or stores passwords | Implemented |
| Minimum length and complexity | `supabase/config.toml` requires 12 characters with lower case, upper case and digits for the local stack. **The hosted project's setting must be applied by hand** (`docs/security/hosted-auth-settings.md`); until then the hosted default (6 characters) applies | Partial **[verify in dashboard]** |
| Leaked-password check | Hosted-only, Pro plan; not enabled | Planned |
| Brute-force protection | Supabase Auth rate limits; no CAPTCHA | Partial |
| Reauthentication for password change | `secure_password_change` set locally; app-side reauthentication flow is being added | Planned |

The previous version of this policy described PBKDF2 hashing, an 8-attempt lockout and 30-day sessions. Those described the retired NestJS API and are not current.

### 2.3 Multi-factor authentication

MFA (TOTP) is available in the Supabase project configuration. **It is not enforced in the app or by database policy today.** Roadmap: in-app TOTP enrolment, mandatory for owners and admins, and RLS requiring `aal2` for HR pay data, billing, payroll/POS connections and account deletion.

### 2.4 Sessions and tokens

- Access tokens (JWT) expire after 1 hour; refresh-token rotation is enabled with a 10-second reuse window (Implemented).
- Absolute session time-box and inactivity timeout are Supabase Pro features and are **not enabled**; they are documented in `config.toml` as commented settings (Planned).
- Sign-out on the device clears local session data. Sign-out triggered by the server (revoked refresh token) does not yet clear every local cache (tracked).

### 2.5 Invitations

Invitation redemption requires a confirmed email. Pending invitations expire and are purged on a schedule.

---

## 3. Internal Infrastructure Access

| Control | Current state | Status |
|---|---|---|
| Accounts | Production consoles (GitHub, Supabase, Cloudflare, Stripe, Codemagic, Apple, Google, Firebase) are held by the principal; there are no other staff with access | Implemented |
| MFA on vendor accounts | Required by policy; the operator must confirm it is enabled on each account **[verify in each console]** | Partial |
| Least privilege | API tokens are scoped where the provider allows (Stripe restricted key, Cloudflare tokens); see `docs/security/secrets-handling.md` | Partial |
| Access reviews | None performed. Roadmap: quarterly review of members, tokens and installed GitHub apps, recorded in the rotation log | Not operated |
| Deprovisioning | No staff or contractors exist, so no offboarding has been exercised. Roadmap: written checklist before the first hire or contractor: revoke GitHub, Supabase, Cloudflare, Stripe, Codemagic and store-console access and rotate shared secrets the same day | Planned |
| Secrets | Held in Supabase secrets, GitHub Environments and Codemagic; not to be stored in the repository or in a cloud-synced folder | Partial (see secrets-handling.md) |
| Source control | `main` is **not** branch-protected and does not require pull-request review. CODEOWNERS and a PR template exist. Protection must be enabled by the operator | Not operated (setting required) |
| Production database | Reached only through the Supabase dashboard/CLI by the principal and through the backup job's credential (GitHub Environment `production-backups`) | Partial |

---

## 4. Audit Trail & Monitoring

Administrative and security-relevant events are written to `public.audit_log` (actor, action, target, metadata) and kept for 365 days (time-entry corrections and voids for 3 years). Sign-in events are recorded by Supabase Auth. There is no scheduled review of these logs and no alerting rules; reads of guest and incident data by line staff are not audited (tracked).

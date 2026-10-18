# Information Security Policy (ISP)

**Document Owner**: Security & Engineering Leadership  
**Effective Date**: August 2026  
**Review Cycle**: Annual  

---

## 1. Purpose & Scope

The purpose of this Information Security Policy is to establish the baseline organizational, technical, and operational safeguards required to protect Venue Wrangler systems, customer data, and employee information from unauthorized access, modification, destruction, or disclosure.

This policy applies to:
* All Venue Wrangler infrastructure, source code repositories, databases, and third-party SaaS services.
* All full-time employees, part-time contractors, and third-party vendors accessing company systems.

---

## 2. Core Security Principles

1. **Least Privilege**: Access to production environments, administrative tools, and sensitive data is granted strictly on a need-to-know, role-appropriate basis.
2. **Defense in Depth**: Security controls are applied across multiple layers—network, application, database, and operational procedures.
3. **Fail Closed**: In the event of system errors or authorization ambiguities, access is denied by default.
4. **Continuous Compliance**: Controls are verified continuously via automated scanning, logging, and third-party audits.

---

## 3. Workstation & Device Security

* **Full-Disk Encryption** (policy; the operator must confirm for each device): laptops must have full-disk encryption enabled (FileVault on macOS, BitLocker on Windows, LUKS on Linux).
* **Password Managers**: Use of an approved password manager (e.g., 1Password, Bitwarden) is mandatory for generating and storing strong, unique credentials.
* **Screen Lock**: Workstations must be configured to automatically lock after 5 minutes of inactivity.
* **Anti-Malware & OS Updates**: Operating systems and software must have automatic security updates enabled.

---

## 4. Software Development Lifecycle (SDLC) Security

Current state, with gaps stated plainly (see [soc2-controls-matrix.md](./soc2-controls-matrix.md)):

* **Version control**: source is on GitHub. **Branch protection and mandatory pull-request review are not enabled on `main`** and direct pushes are possible; enabling them is a manual GitHub setting (`docs/security/secrets-handling.md`, section 6). `.github/CODEOWNERS` and a pull-request security checklist exist.
* **CI checks**: Vitest security and site tests, pgTAP RLS tests, Deno check/lint/test with a frozen lockfile, Flutter analysis and tests, CodeQL for JavaScript/TypeScript, and `npm audit --omit=dev --audit-level=high` for production npm dependencies. GitHub Actions are pinned to commit SHAs and run with least-privilege permissions.
* **Vulnerability management**: Dependabot (npm, pub, GitHub Actions) and GitHub secret scanning with push protection **[verify in dashboard]**. A 14-day patch target for high/critical findings is an objective; it is not tracked or measured.
* **Environments**: there is a single production Supabase project and **no staging environment**. Database migrations and Edge Function deployments are applied by hand from the operator's machine. Local development uses the Supabase CLI stack and test data.

## 5. Network & Cryptographic Safeguards

* **Encryption in transit**: all traffic to Supabase and the Cloudflare-hosted site uses TLS; HSTS is set on the site (without preload).
* **Encryption at rest**: provided by Supabase and Cloudflare. Database backups are additionally encrypted client-side with `age` before upload.
* **Secrets management**: plaintext credentials, private keys and API tokens must never be committed. Production secrets live in Supabase secrets, GitHub Environments and Codemagic; see `docs/security/secrets-handling.md`. The repository must not live in a cloud-synced folder.

## 6. Policy Review & Enforcement

This policy is reviewed annually by engineering leadership. Non-compliance by personnel may result in disciplinary action up to and including termination of employment or contractual agreements.

# Secrets handling

No real secret value may appear in this repository, its documentation, its issues, or its pull
requests. This file lists **where** secrets live, **how** to rotate them, and the workstation
and AI-agent rules that keep them out of the wrong places. It contains names and procedures only.

## 1. Where secrets live

| Secret | Home | Never in |
|---|---|---|
| Supabase service-role key, DB password, Edge Function secrets (Stripe, Resend, Groq, Cloudmersive, FCM/APNs/Play Integrity service accounts, OAuth client secrets, webhook secrets) | Supabase project secrets (`supabase secrets set`) | Git, `.env` files on a synced folder, chat, tickets |
| Production DB URL for backups (`SUPABASE_PRODUCTION_DB_URL`), R2 tokens, age recipient/identity | GitHub **Environments** `production-backups` and `backup-restore-drill` | Repository-level secrets (once migrated), workflow files |
| Cloudflare API token and account ID, Flutter production env JSON | GitHub **Environment** `production` | Repository-level secrets (once migrated) |
| iOS distribution certificate and provisioning profile, App Store Connect API key | **Codemagic** code-signing identities / integrations only | The repo, any workstation, any AI-agent workspace |
| Android upload key and Play App Signing | **Play App Signing** (Google holds the app signing key); the upload keystore is kept offline in a password manager or hardware-backed vault | The repo, `android/key.properties` committed, cloud-synced folders |
| Local development values | `apps/mobile/env/development.json`, `supabase/.env` (both gitignored), populated with **test** values only | Production credentials |

Values that are public by design (Supabase URL and anon key, Sentry DSN, Firebase client
config) are the only exceptions and are allowed in `codemagic.yaml` / client config. The anon key
is only safe because RLS is correct; treat RLS test failures as security incidents.

## 2. Rules

1. **The repository must not live in a cloud-synced folder** (OneDrive, iCloud Drive, Dropbox,
   Google Drive). Sync clients copy `.env`, keystores and credentials to a third party and to
   every other synced device, and keep deleted-file history. Move the working copy to a local,
   non-synced, encrypted-disk path (for example `C:\dev\venuewrangler`) and re-clone.
2. **Signing identities exist only in Codemagic and Play App Signing.** Delete `.p12`,
   `.mobileprovision`, `.p8`, `.jks`/`.keystore` and `credentials.json` copies from workstations
   after confirming Codemagic holds them. `.gitignore` blocks them from being committed; it does
   not stop them being synced or read by tools.
3. **Use the narrowest credential that works**, per environment, and prefer keyless auth
   (OIDC/Workload Identity Federation) over stored keys.
4. **No secrets in committed documents.** Documents and tests may contain placeholders such as
   `rk_live_...` or `AGE-SECRET-KEY-1...`, never real values. Search before committing.
5. **GitHub secret scanning and push protection stay on** (including non-provider patterns and
   validity checks if available).
6. **Production deploys and backups use GitHub Environments** with required reviewers and a
   `main`-only deployment branch rule.

## 3. AI-agent hygiene

AI coding agents read files in the workspace and may send their contents to a model provider.

- Configure **deny-read** rules in every agent's settings (Claude Code `permissions.deny`,
  Codex, Cursor, Copilot, OpenCode, Antigravity, etc.) for: `.env`, `.env.*`, `credentials/`,
  `credentials.json`, `keys/`, `*.jks`, `*.keystore`, `*.p12`, `*.p8`, `*.pem`, `*.mobileprovision`,
  `supabase/.env`, `.opencode/`, `apps/mobile/env/*.json`.
- Example (Claude Code `settings.json`): `{"permissions":{"deny":["Read(./.env)","Read(./.env.*)","Read(./credentials/**)","Read(./keys/**)","Read(./**/*.jks)","Read(./**/*.p12)","Read(./**/*.p8)","Read(./supabase/.env)"]}}`
- Do not paste secrets into prompts, logs or screenshots. Do not give agents production
  credentials; give them local test values and read-only tokens.
- Agent state folders (`.claude/`, `.codex/`, `.agents/`, `.freebuff/`, `.opencode/`,
  `.playwright-cli/`) are gitignored. They can contain OAuth tokens (`.opencode/` held a live
  Supabase token); delete them or rotate the tokens when the tool is retired.
- Local review artifacts (`SECURITY_AUDIT_*.md`, `AUDIT_FINDINGS.md`, `code_review_bundle.txt`,
  `output/`, `ads/`) are gitignored. The repository is public: do not publish internal findings.

## 4. Rotation checklist

Do this immediately if a secret may have been exposed (it sat in a synced folder, an agent
workspace, a log, or a screenshot), and otherwise on the schedule in section 5. Rotate, then
revoke the old value, then confirm the service still works.

### Stripe

- Create a **restricted key** (`rk_live_...`) for the Edge Functions instead of the secret key
  (`sk_live_...`). Required permissions only:
  - Customers: **Write**
  - Checkout Sessions: **Write**
  - Customer portal (Billing Portal): **Write**
  - Subscriptions: **Read**
  - everything else: **None**
- Rotate the **webhook signing secret** (`whsec_...`) and update the `stripe-webhook` function
  secret. Roll with Stripe's expiry window so in-flight events still verify.
- Recommended: run Venue Wrangler on a **dedicated Stripe account** (not one shared with other
  products) with a **test mode** enabled, so a leaked key cannot touch unrelated revenue and
  checkout can be exercised without live charges.
- Delete the old key after the new one is confirmed working; `supabase secrets set STRIPE_...`.

### Supabase

- Rotate the **service-role / secret key** and **JWT secret** (invalidates all sessions, so
  schedule it), the **database password** (update `SUPABASE_PRODUCTION_DB_URL` in the
  `production-backups` environment), and any **S3 access keys** for Storage.
- Regenerate the **anon/publishable key** only if the JWT secret changes; ship a client update
  (Codemagic and `FLUTTER_PRODUCTION_ENV_JSON`) first.
- Revoke personal access tokens and any `.opencode/` or CLI login tokens.

### Cloudflare

- Roll the **Pages deploy API token** (scope: Pages edit for one account) and the **R2 tokens**.
  Use separate tokens for the backup job (Object Read & Write on the backup bucket), the
  restore drill (Object **Read only**) and the storage mirror.

### Backups (age)

- Generate the age key pair on an offline machine: `age-keygen -o backup-identity.txt`. Put the
  **public** recipient (`age1...`) in `BACKUP_AGE_RECIPIENT`; store the **identity file offline**
  (password manager plus a second offline copy) and, only for the drill, as the
  `BACKUP_AGE_IDENTITY` secret of the `backup-restore-drill` environment. Losing the identity
  makes every backup unreadable; rotating it means old backups stay readable only with the old identity.

### Other providers

- **Resend, Groq, Cloudmersive**: roll the API key in the provider console, then
  `supabase secrets set`.
- **Square, QuickBooks (Intuit), Gusto, Toast**: rotate the OAuth client secrets and webhook
  secrets; revoke stored customer tokens if the encryption key or service-role key was exposed.
- **Firebase / FCM, APNs, Play Integrity**: replace service-account JSON keys, delete the old
  keys, and restrict the Firebase API keys by package name / bundle ID.
- **Apple / Google signing**: if a signing identity left Codemagic or Play App Signing, revoke
  and reissue it (Apple Developer portal; Play Console upload-key reset).
- **GitHub**: rotate personal access tokens, review deploy keys and installed apps, and review
  Actions secrets and environments.

### After rotating

1. Search the repository history and issue tracker for the old value (`git log -S`).
2. Record the rotation date, who did it, and why in the table below.
3. If personal data could have been accessed, follow `docs/soc2/incident-response-plan.md`.

## 5. Schedule and dependency review

- Rotate API tokens and OAuth/webhook secrets at least **annually**, service-account keys every
  **90 days**, and always on staff or contractor departure.
- **Dependency review (quarterly):** review semver-major updates that Dependabot ignores for
  npm and pub, review `npm audit` and `deno.lock` changes, and review GitHub Actions pins.
- Review GitHub, Supabase, Cloudflare, Stripe and Codemagic members and tokens quarterly.

## 6. GitHub settings the operator must apply by hand

These are repository/organization settings, not files, so they cannot be committed.

1. **Environments** (Settings -> Environments): create `production` (required reviewer: the
   owner; deployment branches: `main` only), `production-backups` and `backup-restore-drill`
   (required reviewer; `main` only). Move the secrets listed in section 1 into them.
2. **Branch protection / rulesets for `main`**: require a pull request, require the status
   checks `Build and test marketing site`, `Apply migrations and run RLS authorization tests`,
   `Deno check, lint and test Edge Functions` and the Flutter CI job, require CODEOWNERS review
   (`.github/CODEOWNERS`), block force pushes and deletions, require linear history, and require
   signed commits if desired. A single-owner repository cannot approve its own PR: either add a
   second trusted reviewer, or consciously allow the owner to bypass and record that as an
   accepted risk. Until this is enabled, `main` is **not** protected.
3. **Security**: keep secret scanning, push protection, Dependabot alerts/security updates and
   code scanning enabled. Enable private vulnerability reporting.
4. **Actions**: set the default `GITHUB_TOKEN` to read-only and restrict allowed actions to
   SHA-pinned ones.
5. **Visibility**: decide whether the repository should be private. It currently exposes the
   authorization model and internal audit documents.

## 7. Rotation log

| Date | Secret | Reason | Operator |
|---|---|---|---|
| _none recorded_ | | | |

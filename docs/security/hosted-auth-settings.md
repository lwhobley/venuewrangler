# Hosted Supabase auth settings (manual operator checklist)

`supabase/config.toml` configures the **local** development stack only (`supabase start`).
The hosted production project does **not** read it. Every setting below that matters in
production must be applied by hand in the Supabase dashboard (or through the Management API /
`supabase config push`, which is a remote write and must be run deliberately by the operator).

Closes or tracks audit findings A-02, A-03, A-04, A-05, F-02 (see
`SECURITY_AUDIT_2026-10-17.md`, which is local-only and not committed).

Record the date and your initials next to each item when applied, and attach a dashboard
screenshot (with no secrets visible) as SOC 2 evidence.

## 1. Password policy (Authentication -> Sign In / Providers -> Email)

| Setting | Value | Why |
|---|---|---|
| Minimum password length | **12** | `config.toml` sets `minimum_password_length = 12`; the hosted default is 6. |
| Password requirements | **Lowercase, uppercase letters and digits** | Mirrors `password_requirements = "lower_upper_letters_digits"`. |
| Prevent use of leaked passwords | **On** (HaveIBeenPwned check) | Hosted-only; **Pro plan and above**. Has no `config.toml` key. |
| Secure password change | **On** | Requires recent sign-in / reauthentication to change the password (A-03). The app must call `auth.reauthenticate()` before changing the password. |
| Secure email change (double confirm) | **On** | Matches `double_confirm_changes = true`. |
| Confirm email | **On** | Matches `enable_confirmations = true`. |
| Email OTP expiration | **900 seconds** (15 minutes) | Matches `otp_expiry = 900`. |

Existing users are not forced to meet the new policy until they next change their password.

## 2. Bot protection: Cloudflare Turnstile (Authentication -> Attack Protection)

1. In the Cloudflare dashboard create a **Turnstile** widget (Managed mode) for the hostnames
   `venuewrangler.com`. Copy the **site key** (public) and **secret key**.
2. In Supabase: Authentication -> Attack Protection -> enable **CAPTCHA protection**, choose
   **Turnstile**, paste the **secret key** into the dashboard field. Never put the secret in the
   repository or in `config.toml`; for `supabase config push` use `secret = "env(AUTH_CAPTCHA_SECRET)"`.
3. The Flutter client must send the Turnstile token as `captchaToken` on `signUp`,
   `signInWithPassword` and `resetPasswordForEmail`. **Enabling captcha before the client
   ships this change breaks sign-in and sign-up**, so release the client change first.
4. Native apps need a Turnstile-compatible web view or a hosted challenge page. Plan this
   before enabling it for mobile.

## 3. Rate limits (Authentication -> Rate Limits)

Match `[auth.rate_limit]` in `config.toml` unless traffic proves they are too tight:

| Limit | Suggested value |
|---|---|
| Emails sent per hour | 4 with the built-in SMTP (hard-capped by Supabase); raise only after custom SMTP (section 4) |
| Token refreshes per 5 min per IP | 150 |
| Sign-ins / sign-ups per 5 min per IP | 30 |
| Token verifications per 5 min per IP | 30 |
| Anonymous sign-ins per hour per IP | 10 (anonymous sign-ins should stay **disabled**) |

## 4. Custom SMTP (Authentication -> Emails -> SMTP Settings)

The built-in Supabase mail service is for testing only: it is heavily rate limited and sends
from a shared domain. Configure the production sender (Resend is already a subprocessor):

- SMTP host/port/user from the Resend dashboard, stored only in the Supabase dashboard.
- Sender: an address on `venuewrangler.com` with SPF, DKIM and DMARC published.
- Re-test sign-up confirmation, password reset and email-change emails after switching.

## 5. URL configuration (Authentication -> URL Configuration)

| Setting | Value |
|---|---|
| Site URL | `https://venuewrangler.com/app/` (not `http://localhost:3000`) |
| Redirect URLs | `https://venuewrangler.com/app/**` plus the **verified https App Link / Universal Link** used for password reset (below). Remove every `localhost` entry from production. |

**Password-reset redirect (A-05).** The app currently uses the custom scheme
`venuewrangler://reset-password`. Any other Android app can register the same scheme and
receive the link. Migrate to an https link under `venuewrangler.com` that is a verified App Link
(Android `assetlinks.json` with the real signing fingerprint, see
`site/.well-known/assetlinks.json.NEEDS_REAL_FINGERPRINT.md`) and Universal Link (iOS
`apple-app-site-association`). Once the client uses the https redirect, **delete
`venuewrangler://reset-password` from the hosted Redirect URLs and from `config.toml`**.
PKCE means an intercepted code is useless without the verifier, so this is defense in depth,
not an active exploit.

## 6. Tokens and sessions (Authentication -> Sessions, JWT Settings)

| Setting | Value | Notes |
|---|---|---|
| JWT expiry | **3600 s** (1 hour) or lower | Settings -> API -> JWT Settings. Do not raise it. |
| Refresh token rotation | **On**; reuse interval **10 s** | Dashboard default; matches `config.toml`. |
| Session time-box | **7 days** (suggested) | **Pro plan** feature. Absolute session lifetime. |
| Inactivity timeout | **8 hours** for manager/admin devices | **Pro plan** feature. `[auth.sessions]` in `config.toml` is commented out for this reason. |
| Single session per user | Optional | Pro plan; evaluate against shared-tablet use. |

If the project stays on the free plan, time-box and inactivity timeout cannot be enforced
server-side; compensate with the in-app idle lock (audit F-10) and keep JWT expiry short.

## 7. Multi-factor authentication (Authentication -> Sign In / Providers -> Multi-Factor)

- Enable **TOTP** enrolment and verification (matches `[auth.mfa.totp]`).
- Enabling this only exposes the API. MFA is **not enforced** until the app prompts owners and
  admins to enrol and RLS requires `aal2` for sensitive operations (HR pay data, billing,
  payroll/POS connections, account deletion). Track that work separately; do not describe
  MFA as enforced anywhere until it is (see `docs/soc2/soc2-controls-matrix.md`).
- Enable WebAuthn when it becomes generally available.

## 8. Sign-up providers and verified emails

Invitation redemption and tenant membership trust the email on the auth user. Therefore:

- **Email/password**: keep "Confirm email" **on** so an unverified address can never redeem an
  invite addressed to someone else.
- **Social / OIDC providers** (Apple, Google, etc.): enable only providers that issue
  **verified** emails. Apple "Hide My Email" relay addresses will not match an invited address;
  decide how to handle them. Do not enable any provider that can return an unverified email
  claim. After enabling a provider, test that an unverified email cannot join a venue.
- **Anonymous sign-ins**: leave **disabled**.
- **Phone / SMS**: leave disabled unless needed (it adds SMS-pumping cost and abuse surface).

## 9. Other project-level settings to confirm

- **Database -> Network restrictions**: restrict direct Postgres access to known egress IPs if
  the plan allows, or at least require SSL (the backup job uses `sslmode=require`).
- **Database -> Backups**: confirm the plan and whether PITR is enabled. If it is not, the
  recovery point is the nightly dump (up to 24 hours). See `docs/production-operations.md`.
- **API -> Exposed schemas**: only `public` and `graphql_public`; `app_hidden` must not be exposed.
- **Edge Functions secrets**: managed with `supabase secrets set`, never committed
  (`supabase/.env.example` lists names only).
- **Organization settings**: enforce MFA for all Supabase organization members, and review
  members and API keys quarterly.
- **Logs**: confirm log retention for your plan and that Auth/API logs are reviewable during an
  incident.

## Applied-settings log

| Date | Operator | Settings applied | Evidence |
|---|---|---|---|
| _not yet applied_ | | | |

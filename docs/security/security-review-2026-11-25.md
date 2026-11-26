# Security review 2026-11-25

Status of each finding from the 2026-11-25 security review, worked on branch
`fix/security-review`. "Operator" means a setting must be applied by hand in production; the
flags, defaults and rollout order are in `docs/production-operations.md` ("Production flags and
settings") and `docs/security/hosted-auth-settings.md`.

| Finding | Topic | Status | Where |
|---|---|---|---|
| F01 | Unattested punches | **Partly fixed in code; operator.** The client no longer falls back to a direct write after a punch has been sent. Full enforcement needs the operator flags. | `apps/mobile/lib/features/time_clock/data/`; operator: `TIME_CLOCK_ATTESTATION_MODE=enforce`, `require_attested_punches`, `TIME_CLOCK_REQUIRE_ATTESTED=true` (rollout order in `production-operations.md`) |
| F02 | Punches at venues without coordinates | **Already fixed before this review**: the review missed it. Punches at a venue without coordinates are refused, and managers set the location with `set_venue_location`. | `app_hidden.require_clock_in_location` in `supabase/migrations/20261023101510_launch_review_workflows.sql` |
| F03 | Hosted auth configuration | **Operator.** | Checklist in `docs/security/hosted-auth-settings.md` |
| F04 | Sensitive admin actions without MFA | **Fixed**, behind `require_mfa_for_admin_actions` (wage edits, Stripe checkout/portal, payroll OAuth connect, BrightHR connect/disconnect, plus the existing role/ownership actions). Owners and admins must enrol TOTP first. | `supabase/migrations/`, `supabase/functions/` |
| F05 | Toast webhook legacy shared secret | **Fixed**: signed-only by default. Opt-out `POS_WEBHOOK_ALLOW_LEGACY_SECRET=true` for gateways that still send the legacy header. | `supabase/functions/toast-pos` |
| F06 | Password-reset link interception | **Partly fixed**: iOS uses the Universal Link `https://venuewrangler.com/reset-password` (added to `site/.well-known/apple-app-site-association`, with a static fallback page at `site/reset-password/`); web keeps returning to `/app/` on its own origin. Android keeps the custom scheme until `site/.well-known/assetlinks.json` has the real signing fingerprint. | `apps/mobile/lib/core/auth/auth_repository.dart`, `site/`; operator: redirect allowlist (`hosted-auth-settings.md` section 5) |
| F07 | Edge Function CORS | **Fixed**: origin allowlist (defaults: `https://venuewrangler.com`, `https://www.venuewrangler.com`, `https://venue-wrangler.pages.dev`; override with `CORS_ALLOWED_ORIGINS`). Localhost is allowed only when `ENVIRONMENT` is explicitly `development`/`dev`/`local`. | `supabase/functions/_shared/cors.ts` (`serveWithCors`) |
| F08 | Floor table roles | **Fixed**: `merge_floor_tables` and `split_floor_tables` require supervisor or above. Assigning tables to a reservation (seating guests) stays open to all venue staff, because hosts do it. | `supabase/migrations/`; `apps/mobile/lib/features/floor/README.md` |
| F09 | Guest contact details visible to all staff | **Accepted risk** (see below). | n/a |
| F10 | AI "ask" open to all staff | **Fixed**: manager-only. | `supabase/functions/`, `supabase/migrations/` |
| F11 | Attestation verification errors | **Fixed**: fails closed in `enforce` mode. | `supabase/functions/time-clock-punch` |
| F12 | PIN / passcode / kiosk login claims | **Docs corrected.** There is no PIN, passcode or kiosk team login in the product. The legacy PIN login was removed in commit `862f7d2` (2026-06-02). No such claim remains in the site, marketing source or docs text. Any future shared-device login is a plan only and is not available. | `site/`, `packages/marketing/`, `docs/` |
| F13 | SECURITY DEFINER `search_path` | **Fixed**: the 58 DEFINER functions still on `search_path = public` now pin `''` with schema-qualified bodies; a pgTAP check keeps it that way. | `supabase/migrations/20261125120000_security_review_fixes.sql`, `supabase/tests/database/security_review_2026_11_25.test.sql` |
| F14 | Resource-existence disclosure | **Fixed**: manager RPCs (`correct_time_entry`, `void_time_entry`, `erase_guest`, `revoke_invite`, `remove_or_cancel_shift`, `change_member_role`, `remove_member`) answer a missing id with the same `42501` as a forbidden one. | `supabase/migrations/20261125120000_security_review_fixes.sql` |
| F15 | Guest deposit / Stripe Connect claims | **Docs corrected.** Guest and BEO deposit collection and Stripe Connect were removed by `20261004144042_remove_beo_deposit_and_stripe_connect.sql`. Stripe is used only for the app subscription. Migration-era docs that described deploying deposit functions are marked superseded. | `docs/migration/` |
| F16 | Secrets in git history | **No live secret found** (see below). | n/a |
| F17 | iOS push silently disabled without APNs secrets | **Fixed in code** (missing APNs configuration is reported to Sentry); **operator**: set `APNS_KEY`, `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_BUNDLE_ID`. | `supabase/functions/notifications-*` |

## F09 accepted risk: guest contact details visible to all venue staff

**Decision.** Guest and reservation contact fields (name, phone, email, notes) stay readable by
every member of the venue, including the `staff` role.

**Reasoning.** Hosts take and confirm reservations and call guests about them (late arrivals,
table ready, cancellations). Hosts have the `staff` role; the venue roles (`organization_owner`,
`organization_admin`, `venue_manager`, `supervisor`, `staff`) cannot tell a host from a server
or a bartender. Restricting contact fields to
supervisor or above would stop hosts doing their job.

**Exposure accepted.** Any staff member at a venue can read that venue's guest contact details.
Mitigations already in place: access is limited to the venue (RLS, tenant isolation), guest data
on reservations is anonymized after 24 months by retention cleanup, and `erase_guest` handles
erasure requests.

**What would change it.** A dedicated host role (or a host permission on a membership). With it,
contact fields can be limited to hosts and supervisor-or-above, and other staff would see names
and party details only. Revisit this decision when that role exists, or if a venue reports misuse.

## F16: git history check for committed secrets

Checked all refs with `git log --all` for secret-type paths (`.env*`, `*.p8`, `*.p12`, `*.jks`,
`*.keystore`, `google-services.json`, `GoogleService-Info.plist`, service-account JSON, `keys`,
`credentials`), for added files with suspicious names, and with a history-wide search for
secret-shaped strings (Stripe live/test keys, webhook secrets, AWS keys, private-key blocks,
Anthropic/GitHub/Slack/Resend tokens, Google API keys, JWTs). No history was rewritten.

| Path | Commits | Assessment |
|---|---|---|
| `.env.example` (root) | added `ddba59f`, edited in about 40 commits, deleted `2f2c26c` | Template only; no secret-shaped values found. |
| `packages/api/.env.example`, `supabase/.env.example` | various | Templates; names only, no secret-shaped values found. |
| `certs/certificate.pem` | added `7f5cf41`, deleted `2f2c26c` | Public certificate (`BEGIN CERTIFICATE`), not a private key. |
| `convex/secrets.ts` | added `aa27a71`, `160c3a7`; deleted `214fa3d`, `8b253d2` | Code (constant-time compare, secret generator), no secret values. |
| `apps/mobile/android/app/google-services.json` | added `5013326`, still tracked | Firebase Android config with a Google API key. These keys are embedded in every app build and are not secret, but the key should be restricted to the Android app (package and signing certificate) in Google Cloud. |
| `codemagic.yaml` | `19f238a`, still tracked | Contains a Supabase JWT whose role claim is `anon` (the public anon key). Not a secret; the `service_role` key does not appear. |
| `supabase/functions/_shared/google-auth.ts` | `8ec29b3` | PEM header strings used to parse a key at runtime; no key material. |
| `scripts/set-auth-env.mjs` | `31e4597`, `aafaac5`, `3c908c5` | A comment mentioning a PEM header; no key material. |

No `.p8`, `.p12`, `.jks`, `.keystore`, `GoogleService-Info.plist` or service-account JSON was
ever committed. Nothing needs rotating as a result of this check. Recommended follow-up: confirm
the Firebase Android API key is restricted in Google Cloud.

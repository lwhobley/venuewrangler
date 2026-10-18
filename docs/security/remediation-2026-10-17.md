# Security remediation rollout (2026-10-17)

Runbook for deploying the code-level fixes from the October 2026 security audit. It describes
what changed, the order to ship it, and the switches that are deliberately **off** until you
decide to turn them on. Nothing here is applied automatically.

## Deployment order (do not reorder)

1. **Database migrations** (`supabase/migrations`, in filename order):
   - `20261017100000_audit_member_lifecycle_and_integrity.sql`
   - `20261017110000_audit_privacy_retention_and_evidence.sql`
   - `20261017120000_oauth_pending_connections.sql`
   - `20261017130000_attested_punches.sql`
   - `20261017140000_contract_signature_evidence.sql`
   - `20261017150000_least_privilege_reads.sql`

   Take a backup first (see `docs/production-operations.md`). The migrations tighten grants:
   `anon` loses all table/function access in `public`, `authenticated` keeps only the privileges
   that have a matching RLS policy, and new tables/functions in `public` start with no client
   access. Run the SQL suite (`supabase test db` or the CI job) before and after.
2. **Edge Functions** (`supabase functions deploy`, including the new `time-clock-punch`): they call `consume_rate_limit`,
   `org_is_entitled` and read `organizations.ai_enabled`, all created by the migrations above.
3. **Mobile / web app**: uses `team_members`, `remove_member`, `change_member_role`,
   `transfer_ownership`, `my_pending_invites`, `accept_invite`, `set_org_ai_enabled`, the OAuth
   `complete` step, and explicit POS column selection. Older app builds keep working except where
   noted below.

## Behaviour changes to expect

| Area | Change | Who notices |
|---|---|---|
| Invites | Sign-up no longer joins invited users automatically; users accept from an Invitations screen. | New hires, managers sending invites |
| Time entries | Managers can no longer delete punches; they void them (reason required, audited). Raw GPS is removed from audit records and from finished punches after `gps_retention_days` (365). | Managers, payroll |
| Pay and requests | Org admins cannot edit their own or another admin's/owner's pay; reviewers cannot approve their own staff requests (owners excepted). | Org admins |
| AI | Per-organization opt-in (`organizations.ai_enabled`). Existing organizations were backfilled to enabled; new ones start disabled. Released/failed calls now count toward rate limits; failed calls with token usage are billed to the budget. | Owners/admins, all AI users |
| Email | `crm-send-email` requires `lead_id` or `beo_id`, sends only to the stored lead address, and is quota-limited per user (50/day) and per org (200/day). | Managers using CRM email |
| Workspaces | Max 3 per user per 24h, 10 owned in total. | Self-serve signup |
| Payroll OAuth | Connections finish in the app after consent (`/<provider>-oauth/complete`); default scopes are read-only. | Anyone connecting Square/QuickBooks/Gusto |
| POS | `raw_payload` is no longer selectable by clients; purged after 90 days. | Integrations using `select *` on `pos_checks` |
| Time clock | Punches go through `time-clock-punch`, which verifies an App Attest assertion (iOS) or Play Integrity token (Android) bound to the exact punch, then records it. Each end of a punch is stored as attested or not; unattested punches are flagged. Default mode `observe` records unproven punches as unattested instead of refusing them. | Staff, managers reviewing punches |
| Contracts | `partially_signed` / `fully_signed` and the signature columns can only be set with `record_contract_signature` (manager attests; terms hash, who, when, IP recorded); signed terms are frozen. | CRM users |
| Reads | Incidents, their photos and evidence files are readable by the reporter and by supervisors and above; POS checks by supervisors and above. | Staff |
| Release builds | Android release builds are shrunk/obfuscated (R8); iOS builds use Dart `--obfuscate`. | Crash reports need the symbol files |
| Privacy | Guest erasure RPC (`erase_guest`), retention purges for guests, invites, notifications; wage-law fields kept in a restricted table on account deletion. | Privacy requests |

## Switches that ship OFF (single row in `app_hidden.platform_settings`)

Run as the table owner (SQL editor); clients cannot read or write this table.

```sql
-- Paywall: AI, CRM email and document uploads require an active/trialing subscription or a
-- grace trial (trial_days, default 14) once this is true. Decide what existing customers
-- without a subscription row should get BEFORE enabling.
update app_hidden.platform_settings set billing_enforcement = true;

-- Require an aal2 (MFA) session to change manager-level roles / transfer ownership.
-- Enable only after owners and admins have enrolled TOTP in the app.
update app_hidden.platform_settings set require_mfa_for_admin_actions = true;

-- Raw punch GPS retention in days (minimum 30; null keeps it forever).
update app_hidden.platform_settings set gps_retention_days = 365;

-- Refuse self-recorded punches that did not come through time-clock-punch. Turn on only
-- after (1) the app builds with per-punch assertions are the minimum supported versions,
-- (2) TIME_CLOCK_ATTESTATION_MODE=enforce is set for the function, and (3) you have confirmed
-- on real devices that attested punches come back with status "verified".
update app_hidden.platform_settings set require_attested_punches = true;
```

### Rolling out attested punches

1. Deploy the migrations and the `time-clock-punch` function (mode `observe`, the default).
2. Ship app builds that include the per-punch proof. Android needs the Google Cloud project
   number linked to the Play Console app at build time:
   `--dart-define=PLAY_INTEGRITY_PROJECT_NUMBER=<number>`; `PLAY_INTEGRITY_SERVICE_ACCOUNT_JSON`
   and `APP_ATTEST_TEAM_ID` / `APP_ATTEST_BUNDLE_ID` must be set as function secrets.
3. On a real iPhone and a real Android phone, clock in and check the response and the row:
   `select clock_in_attested, punch_source from time_entries order by created_at desc limit 5;`.
   The iOS Swift and Android Kotlin bridges compile (Android debug build verified) but have not
   been run on a device.
4. When most punches show `verified`, switch the function to `enforce`, then flip
   `require_attested_punches`.

## Monitoring

`select * from public.ops_health_report();` (service role) returns one row per failing check:
stuck account/storage deletion jobs, missing Vault secrets for deletion dispatch, failed pg_cron
runs. An empty result is healthy. Poll it from your monitoring and alert on any row.

## Known limits (not fixed by this change)

- Attested punches protect only once enforcement is on (see above) and only as far as App Attest /
  Play Integrity can vouch for the device; a rooted phone with a hooked location provider that
  passes integrity checks is still out of scope. The native iOS/Android code has not been run on
  a device yet.
- Contract signing records a manager attesting the client signed. A client-facing signing page
  (the client's own consent, IP and timestamp) is a separate feature on top of the same table.
- Guests, reservations and CRM remain readable by all venue staff: hosts and servers both need
  guest names, allergies and contact details, and the five roles cannot yet tell them apart.
  Add finer roles (for example a host role) before narrowing this.
- Venue time zones still use a maintained table of about 60 zones (the `timezone` package is not
  a dependency); an unlisted zone shows a warning and blocks saving times.
- `crm-send-email` abuse is bounded (stored recipient, quotas, entitlement, separate sender
  identity) but a paying tenant can still email any address they place on a lead; keep the sender
  on a dedicated subdomain and watch Resend complaint rates.
- Abandoned OAuth consent flows are revoked at the provider on the next callback for that
  provider (after 15 minutes); a quiet period with no callbacks leaves the grant parked, encrypted,
  for up to 24 hours before the database backstop deletes the row.

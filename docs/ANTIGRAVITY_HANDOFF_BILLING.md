# Antigravity handoff — SMB billing

Date: 2026-09-09. Repository: `lwhobley/venuewrangler`.
Workspace: `C:/Users/lwhob/OneDrive/Downloads/a0-project`.
Base: `main`, commit `62bef90c6b947fa080c9c43840ef7d64361f4db3` (verify with `git rev-parse HEAD`; working changes are uncommitted).

## User direction and boundaries

The user asked to fix the SMB audit, then explicitly said: **stop after billing and write a passoff for Antigravity**. Codex stopped further non-billing implementation at that point. No commit, push, production migration, deployment, cloud configuration change, or native build was performed.

Read AGENTS.md first. Preserve `.env.local`: it is the complete local production configuration, remains ignored, and must never be printed, staged, committed, sanitized, or replaced. Do not publish detailed security reports to the public repository. Supabase live advisory access was denied; production RLS/schema state was not verified. Never run integration tests against production.

## Billing implementation completed locally

- Added `Subscription.revenueCatSubscriberId` (unique canonical customer allocation) and `billingSubscriptionId` (explicit link to a paying Subscription).
- Kept provider transaction IDs and webhook event IDs unique. RevenueCat webhooks now update one bound payer rather than copying the same transaction/event into multiple venue records.
- Authenticated Apple sync binds the verified RevenueCat original customer identity, serializes allocation changes, rejects reuse of a single-venue purchase, and checks billing membership at both venues before allocating multi-venue coverage.
- Removed legacy verification by raw venue ID. Ambiguous historical Apple allocations fail with an actionable error rather than being silently reassigned.
- New additional venues link to the paying subscription. Authorization and billing responses resolve that payer's current status; covered venues lose access on cancellation/downgrade rather than relying on independent trials or cached Venue.active.
- Covered rows have no provider identifiers or independent trial. Database constraints enforce no chains and at most five venues total. Deleting the payer detaches coverage into an expired state.
- Apple access requires a matching entitlement and finite future expiry. Sync preserves cancellation intent and avoids overwriting a newer webhook with an older provider lookup snapshot.
- Stripe checkout rejects an existing Apple or covered allocation to prevent accidental double-provider billing.

Primary code: `packages/api/src/billing/billing-coverage.ts`, `subscription-status.ts`, `billing.controller.ts`; `packages/api/src/modules/app/app-billing.controller.ts`, `app.controller.ts`; `packages/api/prisma/schema.prisma`.

Migration: `packages/api/prisma/migrations/20260909150000_subscription_coverage/migration.sql`.
This is additive and intentionally does **not** guess historical payer/venue mappings.

## Verification

- Targeted billing/application tests: **108 passed** in 6 files.
- Full core unit suite: **1,351 passed** in 122 files.
- Typecheck: passed after regenerating Prisma.
- Real PostgreSQL billing integration: **4 passed**, including the new migration, five-venue limit, unique customer allocation, replayed cancellation, inherited access, and payer deletion.
- `git diff --check`: passed (only Windows line-ending warnings).

Integration used a newly initialized local PostgreSQL 18 cluster, loopback port 6549, database `billing_review_test`. Its data lives under ignored `.local-security/billing-review-db`; no production data was copied. The test instance was stopped after verification. `vitest.integration.config.mts` now sets `envDir: false` to avoid loading the production-backed root environment snapshot.

Useful commands:

```powershell
npm run api:prisma:generate
npm run typecheck
npx vitest run packages/api/src/billing packages/api/src/modules/app/app-billing.controller.spec.ts packages/api/src/modules/app/app.controller.spec.ts
npm test
# With a verified disposable TEST_DATABASE_URL only:
npx vitest run --config vitest.integration.config.mts packages/api/src/billing/webhook-idempotency.integration.spec.ts
```

## Required before billing deployment

1. Review the diff and rerun the full integration suite, including tenant scoping and registration concurrency. Only the billing integration file was run here. Coverage thresholds, UI suite, native release build, and API production build were not rerun in this implementation turn.
2. Prepare an explicit, reviewed migration plan for historical subscriptions. Existing secondary venues need their payer links assigned; historical ambiguous Apple rows are intentionally not auto-bound. Do not infer ownership solely from any staff membership.
3. Test real Stripe and RevenueCat sandbox purchase/restore/renewal/cancel flows, alias handling, multi-owner concurrent allocation, and the five-venue ceiling. Confirm RevenueCat transfer behavior remains "Do not transfer". A webhook before the first authenticated sync has no allocation and is ignored; sync must succeed to establish it.
4. Review provider switching and payer management UX. Covered-venue billing responses expose `billingVenueId`; Stripe portal management still happens from the paying venue. No new covered-venue management UI was added.
5. Apply the additive migration before deploying the new API through the normal approved release process. Once payer links are populated, an old API cannot interpret them safely; do not assume a code-only rollback preserves access semantics.

## Non-billing edits started BEFORE the stop instruction — not signed off

These remain in the same working tree. Do not blindly `git add .`; review or separate them from the billing commit.

- **Chat/web images:** `site/_worker.js`, `lib/site-routing.spec.ts`, chat controller/service/tests. Adds the API image origin to CSP and streams private S3 bytes through the token-checked API with a cross-origin resource policy. Unit checks passed as part of the full suite, but actual deployed browser/native image behavior, response-stream failures, and any overlapping static CSP headers need review.
- **Payroll:** controller/tests add real date validation, a 366-day interval cap, and 20,000-row guard with explicit rejection instead of truncation. Unit checks passed; product limits and broader export UX need review.
- **Dependencies:** `package.json` proposes a Multer 2.3.0 override; `scripts/audit-gate.mjs` removes the previous exemptions; `.github/dependabot.yml` removes the Multer ignore. An install was started before the stop instruction and finished, but still reported **2 high vulnerabilities** and **no tracked package-lock diff** was observed. This is **unfinished**: reconcile the installed/locked dependency tree and audit before retaining these changes. Do not claim the vulnerabilities are fixed or relax the gate.

Other audit follow-up remains: production RLS/grants/migration drift, native release validation, alert delivery, deployed-image provenance, browser accessibility/responsive checks, and incremental controller refactoring. Do not expand scope or change production without the user's direction.

# Production release evidence — 2026-09-18

This report covers the release fixes prepared from main commit
`381c660ed5388a81c5a360c3e0c28f273f6e71b3` and the existing restaurant/labor
working-tree changes. It is not a production or real-device sign-off.

## Repository fixes

- Removed unsafe automatic offline clock replay. Punch errors remain visible;
  correction requests provide the existing path for missed punches.
- Restaurant Tonight reads daily-brief counts and the new venue-scoped roster,
  with explicit loading, error/retry, subscription, and stale-data states.
- Preserved the full venue dashboard and push registration. Both editions use
  explicit build/deploy flags; restaurant-only tabs are explicitly hidden.
- Hid the unimplemented shared-tablet toggle while retaining its additive schema.
- Fixed the home migration guard and UI tests; restored existing mapper tests
  alongside the new hourly-rate privacy regression.
- Installed compatible Expo SDK 57 patch versions and refreshed the lockfile.
- Declared Vite explicitly for the test runtime on both release branches and
  completed the mapper regression fixture so API TypeScript checks include it.
- Release jobs use numbered database secret versions. Migration refuses a
  different project/database/schema; retention checks migrations before deletion.
- Deployment drift checks now report the failing line instead of failing silently.

## Automated verification

Windows local runs, with tests prevented from loading the production snapshot:

| Check | Observed result |
| --- | --- |
| App TypeScript | Passed |
| API build / Prisma generation | Passed |
| Core coverage run | 1,422 tests across 127 files passed |
| Core coverage | Statements 64.26%, branches 56.98%, functions 57.80%, lines 67.45%; all gates passed |
| UI coverage run | 325 tests across 57 files passed |
| UI coverage | Statements 57.92%, branches 49.88%, functions 50.54%, lines 61.06%; all gates passed |
| PostgreSQL integration | 41 tests across 10 files passed against an isolated loopback PostgreSQL 18 instance |
| Migration preflight | All 107 packaged migrations present in the isolated database |
| Expo diagnostics | 21/21 passed after patch updates |
| Dependency audit | No unexempted high/critical advisories; installer also reported zero vulnerabilities |
| Web export | Marketing and current Expo client built successfully under `/app` |

## Live checks and repaired configuration

- [Latest database backup workflow](https://github.com/lwhobley/venuewrangler/actions/runs/35322304425)
  completed successfully, including its configured restore verification.
- Supabase security advisor returned only informational RLS-without-policy
  notices, consistent with the API-only data-access lockdown. A read-only query
  confirmed `RetainedTimeEntry` exists and 91 migrations are recorded in the
  linked project; local migrations must still be released through the normal job.
- The serving API revision is `venue-wrangler-api-00111-2w7`, with database secret
  version `1`. Both jobs used `latest`; recent retention executions failed because
  their database had no `RetainedTimeEntry` table.
- Retention's database reference is now pinned to the serving version `1`.
  Migration's pooled and direct references are also pinned to verified version
  `1`. An in-memory comparison confirmed both credentials address the same
  project/database/schema and match the preserved local snapshot. No credential
  values were displayed or committed.
- The latest [retention](https://github.com/lwhobley/venuewrangler/actions/runs/35338899178),
  [deployment drift](https://github.com/lwhobley/venuewrangler/actions/runs/35253236263),
  and [API branch parity](https://github.com/lwhobley/venuewrangler/actions/runs/35251970969)
  runs were red when inspected. A repaired configuration is not proof of a green
  execution. Deployment drift's prior logs did not identify the failing command.

## Post-merge verification

- Main release PR #118 is merged at `5a43bee`; post-merge API/Mobile CI,
  CodeQL, and dependency gates passed.
- [Desktop reconciliation PR #119](https://github.com/lwhobley/venuewrangler/pull/119)
  is merged at `1bdf0a5`, including the marketing site. Its post-merge desktop
  CI and [Cloudflare deployment](https://github.com/lwhobley/venuewrangler/actions/runs/35373709628)
  passed. [API parity](https://github.com/lwhobley/venuewrangler/actions/runs/35373713756)
  and [site parity](https://github.com/lwhobley/venuewrangler/actions/runs/35373716326)
  now pass.
- The drift check had used direct federated credentials because the deployment
  service-account setting existed only in the protected production environment.
  The same deployment identity is now configured for the repository's read-only
  drift job. [Verification](https://github.com/lwhobley/venuewrangler/actions/runs/35373415659)
  reaches the serving image and fails closed because that image predates manifests.
- Cloud Build `9db4755c-d6d2-42d5-bf4a-96a8f1e5758b` successfully built main
  `5a43bee` from a tracked-file-only API context. The immutable candidate is
  `us-east1-docker.pkg.dev/venuewrangler/stadium-wrangler/venue-wrangler-api@sha256:0eebc7adbbc88694afaa794abd3a9101a6e1631989726153c0cc408dd5e15e30`.
  It has not been promoted or used to migrate production.
- Live API health returned `200`; unauthenticated documents returned `401`.
  The 5xx alert policy and both email channels are enabled. Delivery is unverified.
- Read-only Stripe inventory returned 21 live products and 10 live webhook
  endpoints, including an enabled production billing webhook. Purchases, restore,
  entitlements, and RevenueCat's no-transfer setting remain unverified. The
  RevenueCat v2 project-inventory request returned `401`; this does not establish
  whether the configured key supports the API's v1 subscriber calls.
- Scanner execution `venue-wrangler-scanner-preflight-snhw8` succeeded over the
  production private network using the release image: clean content was accepted
  and the harmless EICAR test signature was rejected. It had no database secrets
  and did not upload documents or alter API traffic.
- EAS is authenticated as `venuewrangler` but returned an authorization error
  reading the existing project. Project identifiers were preserved; native build
  verification requires account access.
- After explicit user approval, production retention execution
  `venue-wrangler-api-retention-jw7gw` completed successfully on 2026-09-18
  at 18:00 UTC (one task succeeded; audit logs, wage records, and challenges
  deleted: zero each). The repaired database reference is now
  verified by execution, rather than configuration alone.

## Remaining release sign-off

- Obtain green serving-image drift evidence after deploying the verified candidate.
- Build and deploy the immutable release image through the normal migration and
  candidate-health gates. Production migrations and traffic promotion have not
  been performed as part of this repo fix.
- Verify native iOS onboarding/email, clock/break/correction, purchase/restore,
  offline recovery, accessibility, and representative operator journeys on the
  release build. First restore EAS project access. Capture current platform-native
  store screenshots.
- Test alert delivery, live billing, scanner connectivity, error capture, and the
  previous-version rollback path. Existing configuration and passing unit tests
  do not provide this evidence.

Use `docs/release-quality-gates.md` for the required platform, scenario, tested
commit, and observed-outcome record. Do not mark the release production-ready
until these independent gates are signed off.

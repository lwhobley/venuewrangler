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

## Remaining release sign-off

- Approve the concrete production retention execution. Automatic approval review
  rejected it because normal cleanup can permanently delete expired audit and
  wage records. No alternate execution path was used.
- Publish and reconcile the release branches, then obtain green current-commit
  API/Mobile CI, API branch parity, and serving-image drift evidence.
- Build and deploy the immutable release image through the normal migration and
  candidate-health gates. Production migrations and traffic promotion have not
  been performed as part of this repo fix.
- Verify native iOS onboarding/email, clock/break/correction, purchase/restore,
  offline recovery, accessibility, and representative operator journeys on the
  release build. Capture current platform-native store screenshots.
- Test alert delivery, live billing, scanner connectivity, error capture, and the
  previous-version rollback path. Existing configuration and passing unit tests
  do not provide this evidence.

Use `docs/release-quality-gates.md` for the required platform, scenario, tested
commit, and observed-outcome record. Do not mark the release production-ready
until these independent gates are signed off.

# Claude handoff — repository review fixes

## State and boundaries

- Workspace: `C:/Users/lwhob/OneDrive/Downloads/a0-project`
- SMB repository: `lwhobley/venuewrangler`, branch `main`, starting HEAD `3769e61`.
- Checkout was clean when this implementation started. Changes below are **uncommitted and not pushed or deployed**.
- User requested fixes, then explicitly asked Codex to stop and hand off to Claude. Review the diff before proceeding; do not assume deployment or production migration approval.
- Preserve `.env.local` exactly as production configuration: ignored, never printed, staged, sanitized, or committed. Do not run production-connected diagnostic/migration scripts casually.
- Detailed cloud-security reports must remain local/private; this repository is public.

## Implemented changes

### Inventory correctness

- `lib/offline-inventory-queue.ts`: platform-specific persistent storage (React Native also defines `window`), errors on failed/unreadable storage, serialized read/modify/write operations, browser Web Locks where available, coalesced per-venue sync, and removals merged into current storage instead of overwriting an old snapshot.
- Queue IDs are sent as `operationId` on every attempt. After a failure, later movements for the same item remain queued to preserve ordering. Automatic retries skip permanent errors and entries with three failures; explicit retries remain possible.
- `app/(tabs)/bar-stock.tsx`: persist before the **first** network attempt, surface persistence failures, do not advance past an unsaved count, and use bounded focus-triggered retry delays instead of an `isSyncing` feedback loop.
- `lib/railway-hooks.ts`: forwards `operationId` to the API.
- New `packages/api/src/modules/bar-inventory/inventory-movement.service.ts`: shared transactional sign validation, item locking, stock update, frozen-cost ledger entry, and manager alerts. API controller and Wrangler operator both use it.
- Idempotency is locked by venue/operation ID and protected by a database unique constraint. Replays return the existing movement; mismatched payloads or actors are rejected. Alerts are not repeated on replay.
- Wrangler requires an exact, unambiguous venue-scoped item name and records a count through the shared service instead of directly changing `onHand`.

### Required migration

`packages/api/prisma/migrations/20260910010000_inventory_operation_id/migration.sql`

Adds nullable `BarInventoryMovement.operationId` and unique `(venueId, operationId)`. Existing rows remain valid. Verified against local PostgreSQL only. **Apply through the approved release process before deploying this API, and deploy the API before distributing the updated client.** The old API rejects the client's new field under strict DTO validation.

### Media, tests, dependencies and deployment visibility

- New `common/stream-private-image.ts` shares authenticated image streaming between chat and checklist photos. Checklist photos no longer redirect to an S3 host blocked by the web CSP. Token validation precedes object retrieval.
- Retention orchestration unit tests mock the module dependency graph, preventing slow imports inside a timed test from overlapping the next test's mocks.
- Multer is locked and overridden to **2.3.0**. Removed its Dependabot ignore and all accepted high-severity audit advisories.
- Root dev dependency `@nestjs/platform-express: 12.0.1` is intentional: it anchors the already-installed API adapter at the root so pinned npm 11.12.1 honors the Multer override across workspace links. Do not delete it without verifying `npm ls multer`, audit and clean-install behavior. Relevant upstream issue: https://github.com/npm/cli/issues/9659 . Temporary `npx npm@11.18.0` was used for resolver diagnosis; global npm was not replaced.
- `scripts/api-source-manifest.mjs` fingerprints API build inputs, including root lockfile and Dockerfile, excluding environment files and generated/dependency directories. Docker packages that manifest in the runtime image.
- Drift workflow now inspects each actual traffic-serving Cloud Run image, copies its manifest without executing the container, and compares it with main. It no longer equates a deployment workflow SHA with image source. No image contents or detailed infrastructure reports are uploaded.

## Verification completed

- Full core unit suite: **1,356 passed / 123 files**. This run preceded the final dependency anchor and manifest test addition.
- Subsequent targeted inventory/operator/manifest tests: **30 passed / 3 files**.
- Full UI suite: **311 passed / 55 files**; coverage 60.78% lines, 49.66% branches.
- Full PostgreSQL integration suite: **37 passed / 8 files**, including concurrent inventory replay protection and the migration.
- API build, final TypeScript check and `git diff --check`: passed (Git emits Windows line-ending warnings only).
- `npm ls multer`: **2.3.0 overridden**. Latest install audit: **zero vulnerabilities**. Audit gate: zero accepted advisories, passed.
- `npm ci --ignore-scripts --legacy-peer-deps --dry-run`: passed. This is not a clean-room install/build.
- Drift workflow YAML parses; manifest unit test passes. Actual Docker build and authenticated live drift workflow were **not** run.
- Integration used only the existing disposable PostgreSQL cluster at `.local-security/billing-review-db`, loopback port 6549, database `billing_review_test`. No production data was copied. Cluster is **stopped**, confirmed by `pg_ctl status`.

## Claude's next steps

1. Inspect the complete diff, especially offline persistence/retries, Nest service injection, and the additive migration. Run final tests against the complete current tree and a clean install before committing.
2. Add/perform an HTTP-level Multer/Nest compatibility smoke test if retaining the override, and validate the Docker production dependency prune path. Do not simply suppress audit findings again.
3. Build a new API image and validate manifest extraction in a disposable container. Confirm the drift workflow's existing GCP identity can read serving revisions and pull images; no IAM grants were made. Older serving images lack the manifest and will intentionally fail the check until rebuilt. The manifest is build-input metadata, not signed provenance attestation.
4. Follow the existing gated deployment/migration process only with authorization. Do not publish the new client before server compatibility is available.
5. On a real iPhone: queue inventory offline, force-close/reopen, reconnect, and verify quantities/history exactly once. Test rejected requests and exhausted storage. Verify checklist evidence images in the deployed web app. These device/browser checks remain outstanding.
6. Large scheduling/CRM/app controllers remain architectural debt. This pass extracted shared inventory rules and media delivery; it did **not** arbitrarily split every oversized file or claim the whole app is production-certified. Live RLS/backup verification and broader performance work also remain outside this completed local pass.

No commit, push, release, public artifact upload, or production configuration change was performed.

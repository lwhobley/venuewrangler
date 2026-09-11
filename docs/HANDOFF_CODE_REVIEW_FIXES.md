# Handoff — fix the code-review findings on the uncommitted inventory diff

## State and boundaries

- Workspace: `C:/Users/lwhob/OneDrive/Downloads/a0-project` (repo `lwhobley/venuewrangler`, branch `main`).
- There is a large **uncommitted, unpushed** working-tree diff already in this checkout (offline
  bar-inventory queue, a shared `InventoryMovementService`, a Prisma migration adding
  `BarInventoryMovement.operationId`, private-image streaming, and CI/dependency changes). See
  `docs/CLAUDE_HANDOFF_REPO_REVIEW_FIXES.md` for the full description of that diff — read it first,
  it explains what all the surrounding code is for.
- A code review of that diff (using Claude Code's `/code-review` at `high` effort, 4 finder angles,
  1-vote verification) surfaced the 10 findings below. **None of them have been fixed yet.** Your job
  is to fix them in place, in this same working tree, without reverting or redoing the rest of the
  diff.
- Do not commit, push, deploy, or touch `.env.local`. Do not run production-connected scripts. This
  repo is public — keep anything sensitive local.
- After fixing, run the relevant unit/integration/UI test suites (see "Verification" at the bottom)
  and report results; do not claim something works without running it.

## Fixes, ranked most severe first

### 1. Manual inventory syncs never enforce the retry limit

**File:** `app/(tabs)/bar-stock.tsx`, functions `recordInventoryMovement` (~line 347) and
`submitCount` (~line 365).

**Bug:** Both call `syncOfflineQueue(recordMovement)` — i.e. the hook's `syncNow(recordMovement)`
with no second argument, so `automatic` defaults to `false`. In
`lib/offline-inventory-queue.ts`, `runSync()` only applies its retry-limit gate
(`item.retryable === false || item.retryCount >= 3`) `if (options.automatic)`. So a permanently-failed
queued movement (e.g. a validation error, a 403) is retried on **every single tap** of a
plus/minus button or count submission, forever, instead of backing off after 3 attempts like the
background focus-effect sync does.

**Fix:** Make the retry-limit gate in `runSync` (`lib/offline-inventory-queue.ts`) apply
unconditionally — drop the `options.automatic &&` prefix so it reads:

```ts
if (item.retryable === false || item.retryCount >= 3) {
  blockedItems.add(item.itemId);
  continue;
}
```

There is no good reason a manually-triggered sync should hammer a permanently-dead item any more
than an automatic one should. Keep the `automatic` flag for anything else it's used for (e.g.
messaging/telemetry), just remove it from this specific gate. After this change, a permanently
failed item stays queued (visible to the user, retryable by explicit user action if you add one
later) but stops being silently re-attempted on unrelated taps.

**Test:** Update/extend `tests/ui/offline-inventory-queue.spec.tsx` (and/or
`tests/ui/offline-inventory-native.spec.tsx`) with a case: enqueue an item, fail it 3 times via a
manual (non-automatic) sync call, then assert a 4th manual sync does **not** call
`recordMovement` again for that item.

---

### 2. Wrangler's `UPDATE_BAR_STOCK` skips idempotency entirely

**File:** `packages/api/src/modules/operations/wrangler/wrangler-operator.service.ts`, ~line 705,
inside the `UPDATE_BAR_STOCK` branch of `execute()`:

```ts
const { movement } = await this.inventory.record({ venueId, itemId: item.id, createdBy: actor.profileId,
  movementType: 'count', quantity: onHand, notes: 'Wrangler operator count' });
```

**Bug:** No `operationId` is passed. `InventoryMovementService.record()`
(`packages/api/src/modules/bar-inventory/inventory-movement.service.ts`) only does idempotency
dedup (advisory lock + `findFirst` replay check) `if (operationId)`. Without it, a retried or
duplicated AI tool invocation creates a **second** `BarInventoryMovement` ledger row for the same
logical request and re-runs `alert()` a second time — duplicate manager notifications and a
corrupted audit trail. (The final `onHand` happens to stay correct only because a `count` movement
is naturally idempotent — the movement history is not.)

**Fix:** Generate a stable operation id from the plan/request so retries of the *same* logical
Wrangler call are deduped, the same way the mobile client uses its queue-entry id. Look at how the
plan/request object is shaped in this file (search for `plan.tool === 'UPDATE_BAR_STOCK'` and
whatever request/correlation id is already available on the wrangler request context — e.g. an
existing `plan.id`, `requestId`, or similar). If nothing suitable already exists on the inbound
request, add one at the call site that constructed `plan` (so retries of the *same* HTTP/tool call
reuse the same id, but two independently-issued commands don't collide) and thread it down. Then:

```ts
const { movement } = await this.inventory.record({
  venueId, itemId: item.id, createdBy: actor.profileId,
  movementType: 'count', quantity: onHand, notes: 'Wrangler operator count',
  operationId: `wrangler-${plan.id ?? /* whatever stable id you found/added */},
});
```

**Test:** Extend `packages/api/src/modules/operations/wrangler/wrangler-operator.service.spec.ts`
(the `'Wrangler inventory writes'` describe block) with a case that calls `execute()` twice with
the same plan/request id and asserts `record` (or, at the integration level, the DB) shows only one
movement row and the notification fires once, not twice.

---

### 3. Migration takes a full table lock (no `CONCURRENTLY`)

**File:** `packages/api/prisma/migrations/20260910010000_inventory_operation_id/migration.sql`:

```sql
ALTER TABLE "BarInventoryMovement" ADD COLUMN "operationId" TEXT;
CREATE UNIQUE INDEX "BarInventoryMovement_venueId_operationId_key"
ON "BarInventoryMovement"("venueId", "operationId");
```

**Bug:** `CREATE UNIQUE INDEX` (no `CONCURRENTLY`) takes an `ACCESS EXCLUSIVE` lock on
`BarInventoryMovement` for the entire index build. On the production table, which already has real
row history, this blocks every concurrent `recordMovement` call (reads and writes) for the
duration of the build — on a busy venue during deploy this can queue up or time out requests
against Cloud Run's request deadline.

**Fix:** `CREATE INDEX CONCURRENTLY` cannot run inside a transaction, and Prisma wraps each
migration file in one transaction by default. Split this into two migration files (or use Prisma's
documented pattern for concurrent indexes):

1. Migration A: `ALTER TABLE "BarInventoryMovement" ADD COLUMN "operationId" TEXT;` only.
2. Migration B, marked non-transactional. If using `prisma migrate dev`/`deploy` with a plain SQL
   migration, add this exact marker comment at the top of the file (Prisma reads it to skip
   wrapping the file in a transaction):

   ```sql
   -- CreateIndex
   -- This migration is intentionally not wrapped in a transaction so the index
   -- can be built CONCURRENTLY without an ACCESS EXCLUSIVE lock.
   CREATE UNIQUE INDEX CONCURRENTLY "BarInventoryMovement_venueId_operationId_key"
   ON "BarInventoryMovement"("venueId", "operationId");
   ```

   Confirm the exact syntax Prisma expects for "non-transactional migration" in whatever Prisma
   version this repo pins (check `packages/api/package.json`) — recent Prisma versions support this
   via a `migration_lock.toml`/directory convention or an explicit flag; look it up rather than
   guessing, since getting this wrong silently re-wraps it in a transaction and Postgres will then
   reject `CONCURRENTLY` outright (that failure is at least loud, not silent — but confirm you've
   actually gotten the non-transactional form before treating this as fixed).

**Test:** There's no way to unit-test lock behavior meaningfully; instead confirm (a) the migration
applies cleanly against a local disposable Postgres, and (b) `EXPLAIN`/`\d BarInventoryMovement`
shows the same resulting index as before. Do not test this against any production-connected
database.

---

### 4. Client now sends `operationId` on *every* movement, not just offline retries — deploy-order hazard is broader than documented

**Files:** `lib/railway-hooks.ts` (~line 413, the `recordBarStockMovement` body builder),
`app/(tabs)/bar-stock.tsx` (all movement paths now go through `enqueueOfflineMovement` +
`syncOfflineQueue`), `packages/api/src/main.ts` (~line 110, global
`whitelist: true, forbidNonWhitelisted: true`).

**Bug:** `docs/CLAUDE_HANDOFF_REPO_REVIEW_FIXES.md` already flags that the migration/API must ship
before the client because "the old API rejects the client's new field under strict DTO
validation" — but it's worse than that phrasing suggests. Because `bar-stock.tsx` now routes
**every** stock movement (not just offline-queue replays) through the same
`enqueueOfflineMovement` → `syncOfflineQueue` → `recordMovement({ ..., operationId })` path, **every
single bar-stock request** from an updated client carries `operationId`. If the client update
reaches devices before the API deploy that adds the `operationId` DTO field, `forbidNonWhitelisted`
makes the old API reject **all** bar-stock recording with a 400 — not just retried/offline ones.
Fleet-wide breakage, not a corner case.

**Fix (pick one, in order of preference):**

- **Preferred:** Add a client-side capability gate so the app only sends `operationId` when it
  knows the API supports it (e.g. an API version/feature-flag check already present elsewhere in
  `lib/railway-hooks.ts` — search for how this codebase handles API version gating, if it does; if
  there's no existing mechanism, this is worth raising with the user rather than inventing a new
  one silently).
- **Acceptable if the above isn't feasible quickly:** Leave the code as-is but make the deploy-order
  constraint impossible to violate by accident — e.g. add a note to the deploy runbook/CI (see
  `.github/workflows/api-deploy-drift.yml`) and confirm with the user that API deploy is a hard
  precondition gate before the client build is distributed. This is a process fix, not a code fix —
  do not silently skip it; call it out explicitly in your summary back to the user.

**Do not** ship the client build to app stores/OTA until you've confirmed with the user that the
API is deployed with the new DTO field live in production.

---

### 5. `submitCount`'s "offline" status is a whole-queue aggregate, not per-item

**File:** `app/(tabs)/bar-stock.tsx`, ~line 383:

```ts
isOffline = (await syncOfflineQueue(recordMovement)).failed > 0;
```

**Bug:** This treats the aggregate failure count across the **entire venue queue flush** as the
status of the item the manager just submitted. If an unrelated, older item is stuck permanently
failing in the queue, every subsequent count submission reports "queued offline" and shows the
wrong end-of-workflow message, even though the just-entered count synced successfully.

**Fix:** Track whether the specific just-enqueued entry (from `enqueueOfflineMovement`, which
returns the created `QueuedMovement` with its `id`) is still present in the queue (or check whether
it appears in `result.errors`) after the sync call, rather than using the aggregate `failed` count.
Concretely:

```ts
const entry = await enqueueOfflineMovement({ itemId: item._id, itemName: item.name, movementType: 'count', quantity: qty });
...
const result = await syncOfflineQueue(recordMovement);
isOffline = (await getOfflineQueue(venue.id)).some((m) => m.id === entry.id);
```

(Adjust to whatever queue-inspection helper already exists in
`lib/offline-inventory-queue.ts` — `getOfflineQueue` is exported there — rather than adding a new
one.)

**Test:** Add a case to `tests/ui/bar-stock.spec.tsx`: seed the queue with one permanently-failing
unrelated item, submit a count for a different item that succeeds, and assert the UI shows the
"count complete" (not "offline queued") message.

---

### 6. Shared `isSyncing` flag can mask an unsynced count (race)

**File:** `lib/offline-inventory-queue.ts`, `useOfflineInventoryQueue`'s `syncNow` (~line 295):

```ts
if (!venueId || isSyncing) {
  return { synced: 0, failed: 0, errors: [] };
}
```

**Bug:** `bar-stock.tsx` shares a single `useOfflineInventoryQueue` instance between the
focus-effect's automatic background retries and the direct calls from `recordInventoryMovement`/
`submitCount`. If a manual sync call arrives while a background retry is already in flight
(`isSyncing === true`), it immediately returns `{failed: 0}` without waiting for the in-flight sync
— even though the movement it cares about may still be sitting unsynced. Because of finding #5's
pattern in particular, this can make the UI report success for an item that isn't actually synced
yet.

**Fix:** Instead of short-circuiting to a zeroed result, have `syncNow` join the same in-flight
promise that `syncOfflineInventoryQueue`'s module-level `activeSyncs` map (same file, ~line 31)
already tracks per-venue — that map already exists specifically to coalesce concurrent syncs
correctly. Something like:

```ts
const syncNow = useCallback(async (recordMovement, automatic = false) => {
  if (!venueId) return { synced: 0, failed: 0, errors: [] };
  setIsSyncing(true);
  setSyncStatus(null);
  try {
    // syncOfflineInventoryQueue already dedupes concurrent calls per venueId
    // via its own activeSyncs map — just call it, don't gate on local isSyncing.
    const result = await syncOfflineInventoryQueue({ venueId, automatic, recordMovement });
    ...
    return result;
  } finally { setIsSyncing(false); }
}, [venueId]);
```

Drop `isSyncing` from the dependency array / early-return check since the module-level map is
already the source of truth for "is a sync in flight for this venue."

**Test:** Add a test to `tests/ui/offline-inventory-queue.spec.tsx` that starts a slow sync, then
calls `syncNow` again concurrently, and asserts the second call resolves to the *actual* result
(not a zeroed stub) once the shared sync completes.

---

### 7. Per-item queue removal does a full read-modify-write for each synced item

**File:** `lib/offline-inventory-queue.ts`, `runSync` (~line 224):

```ts
await removeOfflineMovement(item.id);
```

**Bug:** Called once per successfully-synced item inside the loop; each call does a full
`readRawQueue()` + `writeRawQueue()` (full JSON parse/stringify, plus a `localStorage` or file I/O
round trip) of the **entire** queue. For N items syncing in one pass, that's N sequential full
read-modify-writes instead of one.

**Fix:** Accumulate the ids to remove (and the failed-entry patches) during the loop, then issue a
single `mutateQueue` call at the end that both removes the synced ids and patches the failed
entries in one read-modify-write:

```ts
const toRemove = new Set<string>();
const toPatch = new Map<string, Partial<QueuedMovement>>();
// ...inside the loop, instead of awaiting removeOfflineMovement / mutateQueue per item:
//   toRemove.add(item.id)  on success
//   toPatch.set(item.id, { retryCount: ..., lastError: ..., retryable })  on failure
// after the loop:
if (toRemove.size || toPatch.size) {
  await mutateQueue((current) => current
    .filter((entry) => !toRemove.has(entry.id))
    .map((entry) => toPatch.has(entry.id) ? { ...entry, ...toPatch.get(entry.id) } : entry));
}
```

Keep the per-item `try/catch` around the actual `recordMovement` network call — only the
storage-write side needs batching.

**Test:** Existing tests in `tests/ui/offline-inventory-queue.spec.tsx` should still pass unchanged
if behavior is preserved; add an assertion (spy on `localStorage.setItem` or the file-write mock)
that a sync of N items results in a small constant number of storage writes rather than N.

---

### 8. CI drift check lost its per-file diagnostic summary

**File:** `.github/workflows/api-deploy-drift.yml` (~line 132 onward).

**Bug:** The previous version of this job wrote a detailed `$GITHUB_STEP_SUMMARY` (commits-behind
count, days-behind, `git diff --name-status` file list) when drift was detected. The rewritten
version (which correctly switched to inspecting the actual serving Cloud Run image instead of
trusting the last deploy workflow's SHA — keep that part) only emits single-line `::error::`
messages with no list of which build inputs actually differ.

**Fix:** When the manifest comparison in `scripts/api-source-manifest.mjs` detects a mismatch, have
it (or the workflow step that calls it) also write a `$GITHUB_STEP_SUMMARY` block listing which
files differ between the serving image's manifest and `main`'s current manifest — reuse whatever
diffing the manifest comparison already does internally (it must already know which entries differ
to decide mismatch vs. match) rather than re-deriving it. Keep the `::error::` line for CI status,
add the summary alongside it, not instead of it.

**Test:** `scripts/api-source-manifest.spec.ts` — add a case asserting the comparison function
returns (or the CLI prints) the list of differing file paths, not just a boolean/exit code.

---

### 9. Controller bypasses DI to default-construct its own service

**File:** `packages/api/src/modules/bar-inventory/bar-inventory.controller.ts`, ~line 338:

```ts
constructor(
  private readonly prisma: PrismaService,
  private readonly notifications: NotificationsService,
  private readonly email: EmailService,
  private readonly parser: BarInventoryParserService,
  private readonly reports: BarInventoryReportsService,
  private readonly movements: InventoryMovementService = new InventoryMovementService(prisma, notifications),
) {}
```

**Bug:** `InventoryMovementService` is already registered and exported as a provider in
`bar-inventory.module.ts`. Manually `new`-ing it as a constructor default bypasses Nest's DI
container, creating a second, unmanaged instance per controller construction instead of reusing the
module's singleton. This only exists to avoid updating the handful of tests that construct
`BarInventoryController` directly without passing all six args.

**Fix:** Remove the default value so `movements` is an ordinary required constructor-injected
dependency:

```ts
private readonly movements: InventoryMovementService,
```

Then update every test that does `new BarInventoryController(...)` with fewer than 6 args (grep for
`new BarInventoryController(` across `packages/api/src`) to pass a real or mocked
`InventoryMovementService` explicitly, the same way they already mock `NotificationsService` etc.

**Test:** Run `packages/api/src` unit tests for `bar-inventory.controller.spec.ts` (or wherever its
tests live) after the fixture update; they should pass with the explicit mock and exercise the same
behavior as before.

---

### 10. Wrangler's optional `inventory` dependency silently disables a tool

**File:** `packages/api/src/modules/operations/wrangler/wrangler-operator.service.ts` (~line 704)
and `packages/api/src/modules/operations/wrangler/safe-wrangler-operator.service.ts` (~line 65-67).

**Bug:** `inventory?: InventoryMovementService` is declared TypeScript-optional with no
`@Optional()` DI decorator, and `execute()` hard-fails with a 400
(`'Inventory service is unavailable'`) whenever it's absent. This is a manual runtime check
standing in for a real dependency — it exists only so existing test constructors like
`new WranglerOperatorService(prisma)` (used for unrelated read-path/schedule tests in
`wrangler-operator.service.spec.ts`) keep compiling without passing a 2nd argument. In production,
`AppModule` always wires this via `BarInventoryModule`, so the branch is currently unreachable
there — but nothing at the type level prevents a future caller from constructing the service
without it and silently losing `UPDATE_BAR_STOCK`.

**Fix:** Make `inventory: InventoryMovementService` a required constructor parameter (drop the
`?`). Update the handful of test constructors that don't need `UPDATE_BAR_STOCK` behavior (the
`executeRead`/`assertNoShiftOverlap` tests at ~line 36 and ~427 of
`wrangler-operator.service.spec.ts`) to pass a throwaway mock (e.g. `{ record: vi.fn() } as never`)
instead of omitting the argument. This makes "inventory is required" a compile-time guarantee
instead of a runtime 400, and removes the dead defensive branch.

**Test:** After the required-param change, `tsc`/build should catch any remaining call site that
doesn't pass `inventory` — that's the point. Run the existing wrangler spec files to confirm no
behavior changed for the read-path tests.

---

## Verification (do this after applying the fixes above)

Mirror what `docs/CLAUDE_HANDOFF_REPO_REVIEW_FIXES.md` already ran, and re-run it after your
changes — don't assume the earlier numbers still hold:

1. Full API unit suite (`packages/api`).
2. Full UI suite (`tests/ui`), including the new/updated specs from findings #1, #5, #6, #7 above.
3. Full PostgreSQL integration suite (`packages/api` integration specs), including a fresh check
   that migration #3's split still applies cleanly end-to-end against the existing disposable local
   Postgres cluster only — never a production-connected database.
4. `git diff --check` and a TypeScript build (`tsc`/`nest build` as this repo already does) to catch
   the DI-signature fallout from findings #9 and #10.
5. Re-run `scripts/audit-gate.mjs` and `npm ls multer` if your changes touch dependencies (they
   shouldn't for this pass) — just confirm nothing regressed.

Do not commit, push, or deploy without the user's explicit go-ahead, and do not touch
`.env.local` or run production-connected diagnostic scripts.

# Handoff — fix the P0/P1 findings from the Grok Prisma/DB audit

## State and boundaries

- Workspace: `C:/Users/lwhob/OneDrive/Downloads/a0-project` (repo `lwhobley/venuewrangler`, branch `main`).
- A separate full-repo audit (Grok, "Venue Wrangler Full Prisma and Database Code Audit") reviewed
  the Prisma schema, migrations, API controllers, tenancy/RBAC model, and test coverage. It produced
  94 numbered findings (AUD-001 through AUD-094). This doc turns the **P0 and highest-value P1**
  findings into concrete fix instructions. It is a separate body of work from
  `docs/CLAUDE_HANDOFF_REPO_REVIEW_FIXES.md` / `docs/HANDOFF_CODE_REVIEW_FIXES.md` (the offline
  inventory / operationId diff) — do not conflate them, though some findings here touch the same
  files (e.g. `BarInventoryMovement.operationId` NULL-hole is AUD-030, related to but distinct from
  that other diff's idempotency work).
- **Spot-check before you code.** The five findings below were independently verified against the
  current tree (schema.prisma, reservation-mutation.service.ts, guests.controller.ts,
  floor.service.ts, workforce.controller.ts) before writing this doc — the file/line references and
  code excerpts are accurate as of now. The remaining ~89 findings in the source audit were **not**
  independently re-verified line-by-line; grep for the referenced symbol/pattern yourself before
  editing, since large audits can drift or have minor line-number staleness.
- This is a live multi-tenant hospitality system with real venue data (per the audit: Prisma on
  Supabase Postgres, API on Cloud Run). Every fix here touches either data-deletion behavior,
  tenant isolation, or a uniqueness constraint — treat all of it as requiring careful migration
  planning, not just a code edit. Do not commit, push, or deploy without the user's explicit
  go-ahead. Do not touch `.env.local` or run anything against a production-connected database.
- Where a fix requires a schema/migration change, **write the migration to be safe against existing
  production data** (no blind `NOT NULL`, no non-concurrent index builds on tables with real rows,
  no unique constraint added without first checking for existing duplicates) — the patterns below
  spell out the safe sequence for each one.

## P0 fixes (block unconstrained production use)

### P0-1 — Venue deletion destroys wage and revenue history (AUD-001, AUD-002, AUD-003)

**Files:** `packages/api/prisma/schema.prisma` — `TimeEntry` (~line 847-877, `venue` relation at
874), `PosLaborPunch` (~line 1220-1245, `venue` relation at 1238), `PosCheck` (~line 1183-1220,
`venue` relation at 1210). All three declare `venue Venue @relation(fields: [venueId], references:
[id], onDelete: Cascade)`.

**Confirmed:** all three models cascade-delete when their parent `Venue` is deleted. There is a
`RetainedTimeEntry` model that survives account deletion, but (per the audit, and consistent with
`app.controller.ts`'s account-delete flow being the only place that populates it) it is only
populated on that one specific deletion path — not on every path that can delete a `Venue` row.

**Why this matters:** if any other code path ever calls `prisma.venue.delete(...)` (venue closure,
admin tooling, a future feature), all time-clock punches, POS labor records, and POS checks
(payment/revenue history) for that venue vanish permanently with no archive — this is FLSA/wage and
revenue-record risk, not just a UX bug.

**Fix — sequence matters, do not skip steps:**

1. First, audit every call site of `prisma.venue.delete(` (and any raw SQL `DELETE FROM "Venue"`)
   across `packages/api/src`. Confirm the only production path today is the account-deletion flow
   in `app.controller.ts` (search for where `RetainedTimeEntry` is created to find it), and that it
   already copies `TimeEntry` rows before deleting. Do not assume this — check it.
2. Add a Postgres trigger that runs **before** any `Venue` delete and copies `TimeEntry` rows into
   `RetainedTimeEntry` unconditionally, so archival no longer depends on the calling code
   remembering to do it. Base it on this shape (adapt column names to match
   `RetainedTimeEntry`'s actual columns in `schema.prisma` — read that model first, don't guess):

   ```sql
   CREATE OR REPLACE FUNCTION retain_time_entries_before_venue_delete()
   RETURNS trigger LANGUAGE plpgsql SET search_path = public AS $$
   BEGIN
     INSERT INTO "RetainedTimeEntry" (id, "originVenueId", "originVenueName", "profileFullName",
       "clockInAt", "clockOutAt", "isOpen", breaks, "originCreatedAt")
     SELECT gen_random_uuid()::text, OLD.id, OLD.name, te."profileFullName",
            te."clockInAt", te."clockOutAt", te."isOpen", te.breaks, te."createdAt"
     FROM "TimeEntry" te WHERE te."venueId" = OLD.id
     ON CONFLICT DO NOTHING;
     RETURN OLD;
   END $$;

   CREATE TRIGGER trg_retain_time_entries_before_venue_delete
   BEFORE DELETE ON "Venue"
   FOR EACH ROW EXECUTE FUNCTION retain_time_entries_before_venue_delete();
   ```

   Use whatever ID generation matches the rest of the schema (the codebase uses Prisma `cuid()` for
   app-level inserts — for a DB trigger, `gen_random_uuid()::text` is fine as long as
   `RetainedTimeEntry.id` doesn't have a format CHECK constraint; check that first).
3. Change the FK in `schema.prisma` from `onDelete: Cascade` to `onDelete: Restrict` for
   `TimeEntry.venue`, `PosLaborPunch.venue`, and `PosCheck.venue`. **Do this only after step 2's
   trigger is live** — otherwise any venue delete will simply start failing instead of being
   archived, which breaks the account-deletion flow that currently relies on cascade for these
   three tables (re-check that flow's delete order after this change: it likely needs to explicitly
   delete/move these rows before deleting the `Venue` row, since `Restrict` will now reject the
   cascade Prisma used to do automatically).
4. For `PosLaborPunch` and `PosCheck`, there is no existing retain table. Either (a) add
   `RetainedPosLaborPunch` / `RetainedPosCheck` models mirroring `RetainedTimeEntry`'s pattern, with
   their own before-delete triggers, or (b) if the user decides POS history doesn't need
   post-venue-deletion retention (raise this as a product question rather than deciding it
   yourself), use `onDelete: SetNull` on a nullable `venueId` instead of `Restrict`+archive — that
   preserves the rows but detaches them from the deleted venue. **Ask the user which of these two
   they want before implementing** — this is a product/compliance decision, not a pure code fix.
5. Write the Prisma migration by hand (this isn't something `prisma migrate dev` can generate
   correctly for a trigger) and test the full sequence against a local disposable Postgres: create a
   venue with time entries, delete it, confirm `RetainedTimeEntry` has the rows and the `Venue`
   delete succeeds (or fails cleanly if you chose Restrict-without-archive for POS tables).

**Test:** an integration test that creates a venue with `TimeEntry`/`PosCheck`/`PosLaborPunch` rows,
deletes the venue through whatever path you decided is the sanctioned one, and asserts wage rows
survive in the retain table while the original rows are gone (or, for `Restrict`-only tables,
asserts the delete is rejected until those rows are moved).

---

### P0-2 — Soft-deleted guests and reservations can be revived/mutated (AUD-004, AUD-005, AUD-006, AUD-091)

**Files and exact lines, verified against the current tree:**

- `packages/api/src/modules/reservations/reservation-mutation.service.ts:115-117`:
  ```ts
  const existing = await transaction.reservation.findFirst({
    where: { id: args.reservationId, venueId: args.venueId },
  });
  ```
  No `deletedAt: null`. The subsequent `.update()` at line 121-124 can mutate a cancelled/deleted
  reservation's status/notes/table assignment.

- `packages/api/src/modules/guests/guests.controller.ts:425-427` (inside `upsertGuest`):
  ```ts
  const existing = await this.prisma.guest.findFirst({
    where: { id: body.guestId, venueId: scope.venueId },
  });
  ```
  No `deletedAt: null`. A soft-deleted guest (dietary notes, contact info) can be silently
  overwritten and effectively revived into normal list views that filter `deletedAt: null`
  elsewhere.

- `packages/api/src/modules/floor/floor.service.ts:599-601` (inside `assignReservationToTables`):
  ```ts
  const reservation = await this.prisma.reservation.findFirst({
    where: { id: reservationId, venueId },
  });
  ```
  No `deletedAt: null`. A host can seat a cancelled/deleted reservation onto live tables.

**Fix — apply the same pattern in all three places:**

```ts
// reservation-mutation.service.ts:115-117
const existing = await transaction.reservation.findFirst({
  where: { id: args.reservationId, venueId: args.venueId, deletedAt: null },
});
if (!existing) throw new BadRequestException('Reservation not found');
```

```ts
// guests.controller.ts:425-427
const existing = await this.prisma.guest.findFirst({
  where: { id: body.guestId, venueId: scope.venueId, deletedAt: null },
});
if (!existing) throw new BadRequestException('Guest not found');
```

```ts
// floor.service.ts:599-601
const reservation = await this.prisma.reservation.findFirst({
  where: { id: reservationId, venueId, deletedAt: null },
});
if (!reservation) throw new NotFoundException('Reservation not found');
```

Treat "not found because deleted" the same as "not found because it never existed" — do not leak
whether a deleted row exists via a different error message.

**Also check while you're in these files** (same class of bug, not separately numbered in the
audit): grep both `reservation-mutation.service.ts` and `guests.controller.ts` for every other
`findFirst`/`findUnique` on `reservation`/`guest` that loads a row for a subsequent write, and add
the same `deletedAt: null` filter if missing. The audit's `removeGuest` excerpt
(`guests.controller.ts:441`) already includes it correctly — use that as the reference pattern.

**Test:** add the three tests from the audit's own test plan:
- Soft-deleted guest upsert → 400/404, row stays deleted, fields unchanged.
- Soft-deleted reservation save → 400/404.
- Soft-deleted reservation floor-assign → 404.

Each should assert both the error response **and** that the underlying row's `deletedAt` and
content are unchanged after the attempted call.

---

### P0-3 — Global-uniqueness constraints can collide across tenants (AUD-007, AUD-008)

**Files:**
- `packages/api/prisma/schema.prisma:1362`: `CrmContract` has `@@unique([contractNumber])` (global).
- `packages/api/prisma/schema.prisma:830`: `PushToken` has `token String @unique` (global).

**Confirmed:** both are global uniques, not scoped to `venueId`, verified directly against the
current schema.

**Bug:** Two different venues (tenants) can legitimately generate/receive the same
`contractNumber` or the same device `token` (a device used at two different venues, or two venues'
independent numbering schemes colliding), and the second venue's write will fail with a unique
constraint violation that has nothing to do with an actual collision within that venue.

**Fix for `CrmContract`:**

1. Before migrating, query for existing cross-venue duplicates:
   ```sql
   SELECT "contractNumber", COUNT(DISTINCT "venueId") FROM "CrmContract"
   GROUP BY "contractNumber" HAVING COUNT(DISTINCT "venueId") > 1;
   ```
   If any exist, decide with the user how to resolve them (append a venue-scoped suffix to one of
   the colliding rows) before applying the schema change — do not silently rename data.
2. Change the schema:
   ```prisma
   @@unique([venueId, contractNumber])
   ```
   Migration: `DROP INDEX/CONSTRAINT "CrmContract_contractNumber_key"` then
   `CREATE UNIQUE INDEX "CrmContract_venueId_contractNumber_key" ON "CrmContract"("venueId",
   "contractNumber")`.
3. Grep the CRM module for any code that looks up a contract by `contractNumber` alone (without
   `venueId`) and add the venue predicate — the old global-unique assumption may be baked into a
   lookup, not just the constraint.

**Fix for `PushToken`:**

1. Same duplicate check first:
   ```sql
   SELECT token, COUNT(DISTINCT "venueId") FROM "PushToken"
   GROUP BY token HAVING COUNT(DISTINCT "venueId") > 1;
   ```
2. Change the schema:
   ```prisma
   @@unique([venueId, token])
   ```
   (drop the bare `@unique` on the `token` field itself, add the composite `@@unique`.)
3. Find the upsert logic that writes `PushToken` rows (search for where push tokens are registered)
   and confirm it upserts on `(venueId, token)`, not on `token` alone — the application code likely
   assumed a global-unique token and will need updating alongside the constraint.

**Test:** for each, a test that creates the "same" contract number / device token under two
different venues and asserts both writes succeed and both rows exist independently.

---

### P0-4 — Workforce controller is entirely unscoped from tenant isolation (AUD-009)

**File:** `packages/api/src/modules/workforce/workforce.controller.ts:73`:

```ts
@SkipVenueScope()
export class WorkforceController {
```

**Confirmed:** `@SkipVenueScope()` is applied at the **class** level, meaning every single handler
in this controller — not just the public invite-check endpoint that legitimately needs to run
before a venue membership exists — bypasses the Prisma tenant-isolation extension's automatic
`venueId` scoping. Isolation for every other handler in this file depends entirely on manually
correct `venueId` predicates in raw SQL/RPC calls and post-load checks, with no safety net if a
future handler forgets one.

**Fix:**

1. Remove the class-level `@SkipVenueScope()` decorator.
2. Identify which specific handler(s) actually need to run without a venue in scope — per the
   audit, this is the public invite-check/preview endpoint (unauthenticated users checking an
   invite before they have any venue membership). Apply `@SkipVenueScope()` to **that method only**.
3. For every other handler in the controller, verify it now gets normal tenant scoping. Read each
   one and confirm: does it use `@VenueScope()` to get the venue from the request context, and do
   its Prisma calls run inside that scope (so the extension can AND `venueId` in automatically)? If
   a handler currently does its own manual `venueId` filtering because it assumed no scoping was
   applied, that manual filtering is now redundant but harmless — leave it as defense in depth
   rather than removing it.
4. Pay special attention to the role check the audit flagged in the same controller (AUD-043,
   ~line 305-316): a manager-permission check there apparently omits `allAccess`, using something
   like `role IN ('admin','owner','manager')` instead of `canManageVenue(role, allAccess)`. Fix that
   in the same pass since you'll already be reading this file closely — use whatever
   `canManageVenue`/`requireManager` helper the rest of the codebase uses (grep for
   `canManageVenue` to find its definition and current call sites) rather than inlining a new role
   check.

**Test:** add a regression test that fails CI if `@SkipVenueScope()` reappears at the class level —
e.g. a unit test that reflects on `WorkforceController`'s class-level decorators and asserts it's
absent, plus the standard cross-tenant IDOR test (venue A token, venue B's workforce/join-request
id → 403/404) for whichever handlers now get scoping for the first time.

---

### P0-5 — Malware scanning is optional (fail-open) on chat and checklist photo uploads (AUD-060, AUD-061)

**Files:**
- `packages/api/src/modules/operations/operations.controller.ts:265, 1033-1035` — checklist photo
  upload treats the malware scanner as `@Optional()`.
- `packages/api/src/modules/chat/chat.controller.ts:839-841` — chat image upload only invokes the
  scanner `if (this.malwareScanner)`.

Verify the exact current lines yourself (grep `malwareScanner` in both files) before editing —
these weren't in the set independently re-checked above.

**Bug:** if the ClamAV integration is ever misconfigured, down, or not wired up in a given
environment, these two upload paths silently skip malware scanning and accept the file anyway. The
audit notes the **documents** upload path (`documents.controller.ts`) already does this correctly
(fails closed — rejects the upload if the scanner is unavailable), so there's an existing pattern
to copy rather than invent.

**Fix:**

1. Find how `documents.controller.ts` handles a missing/unavailable scanner (search for how it
   fails closed — likely throwing a 503 or similar before accepting the file).
2. Apply the identical pattern to the checklist-photo path in `operations.controller.ts` and the
   chat-image path in `chat.controller.ts`: if the scanner dependency is unavailable, reject the
   upload with a clear error instead of proceeding.
3. Confirm this is guarded appropriately for local/test environments (the documents path must
   already handle test/dev environments somehow without requiring a live ClamAV instance — mirror
   however it does that, e.g. an environment check or a test double, rather than making local dev
   painful).

**Test:** for both upload paths, a unit test with the scanner dependency mocked as unavailable
(undefined/throwing) asserting the upload is rejected (matching whatever the documents path's
existing "scanner unavailable" test already asserts — find and mirror it).

---

## Selected P1 fixes worth doing in the same pass (lower urgency, similar shape)

These weren't independently re-verified line-by-line the way the P0s above were — grep for the
referenced symbol first, confirm the current line numbers, then apply.

- **AUD-013 — Floor merge/split/release aren't under the same lock as assign.** In
  `floor.service.ts`, wrap merge/split/release in the same `withSerializableRetry` +
  `pg_advisory_xact_lock` pattern already used for `assignReservationToTables`/table assignment.
  Reuse the existing lock-key convention in that file (grep for `pg_advisory_xact_lock` in
  `floor.service.ts` to see the pattern already in use for assign) rather than inventing a new one.
- **AUD-014 — Inventory cost PATCH isn't under the same advisory lock as movements.** In
  `bar-inventory.controller.ts`, the cost-update handler should take the same
  `bar-inventory-{itemId}` advisory lock that `inventory-movement.service.ts`'s `record()` method
  already takes (see that file's `pg_advisory_xact_lock(hashtext(${lockKey}))` call) before reading
  and writing `unitCostCents`, so a concurrent movement and cost edit can't interleave.
- **AUD-030 — `BarInventoryMovement.operationId` uniqueness has a NULL hole.** This is closely
  related to (but not fixed by) the offline-inventory-queue diff covered in
  `docs/HANDOFF_CODE_REVIEW_FIXES.md` finding #2 — that doc already covers making Wrangler's
  `UPDATE_BAR_STOCK` pass an `operationId`. Once every write path supplies one, consider whether
  `operationId` should become required (non-null) rather than optional, closing the NULL-porous
  unique constraint permanently. Coordinate this with whoever implements that other handoff doc so
  the two pieces of work don't conflict.
- **AUD-019 — Paid/void POS checks can be overwritten by a replayed webhook.** In the POS ingest
  upsert (`pos.controller.ts`), add a guard: if the existing `PosCheck.status` is already `paid` or
  `void`, ignore payload changes on replay (update only a `lastExternalEventAt`-style watermark, not
  the financial fields) rather than overwriting a closed check.
- **AUD-049 — Staff-request approval ignores `updateMany`'s affected-row count.** In
  `staff-requests.controller.ts` (~line 569-591), check the `count` returned by `updateMany` and
  throw/report failure if it's `0` — right now an approval can report success while the underlying
  schedule row didn't actually change.
- **AUD-016 — Waitlist exposes guest phone numbers to any staff member, not just managers.** In
  `floor.controller.ts`/`floor.service.ts`, this is a **product decision**, not a pure bug — ask the
  user whether hosts/servers are supposed to see guest phone numbers on the waitlist. If not,
  strip `phone` from the payload for non-manager roles (mirror how `bar-inventory` already strips
  cost fields for non-managers — grep for that pattern as a precedent in this codebase).

## Do not attempt in this pass (flag back to the user instead)

- **AUD-012 (Force RLS)** and **AUD-067 (Organization/venue-group layer)** are explicitly framed by
  the audit as product/architecture decisions, not bugs — don't implement either without the user
  weighing in first.
- Anything under the audit's "Areas that could not be verified" section (live production row
  contents, whether `allAccess` rows exist, whether EXCLUDE-constraint migrations would fail against
  real overlapping data) requires the user's involvement — you cannot check these safely yourself
  without production database access, which this handoff does not authorize.

## Verification

After each fix:
1. Run the relevant unit/integration suite for the touched module (`packages/api` — look for the
   `.spec.ts` alongside each file you changed, e.g. `reservation-mutation.service.spec.ts`,
   `guests.controller.spec.ts`, `floor.service.spec.ts`, `workforce.controller.spec.ts`).
2. For any schema/migration change (P0-1, P0-3), apply the migration against a local disposable
   Postgres only, and confirm with a duplicate-check query (shown inline above) that no existing
   data violates the new constraint before it goes live anywhere real.
3. Add the specific regression tests called out in each section above — don't just fix the code and
   assume it's covered.
4. Do not commit, push, or deploy. Summarize what you changed and why, and flag the two product
   decisions above (POS retention strategy in P0-1 step 4; waitlist phone visibility in the P1 list)
   explicitly rather than deciding them yourself.

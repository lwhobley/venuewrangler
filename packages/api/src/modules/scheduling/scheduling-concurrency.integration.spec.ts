import { describe, it, expect, beforeAll, afterAll, afterEach } from 'vitest';
import { PrismaClient, Prisma } from '@prisma/client';
import {
  setupTestDb,
  seedSchedulingFixtures,
  cleanSchedulingData,
} from '../../test/setup-test-db';
import { withSerializableRetry } from '../../common/tx-retry';

type TxClient = Parameters<Parameters<PrismaClient['$transaction']>[0]>[0];

// Mirror the controller's locking and double-book helpers so we test the
// actual transaction semantics, not a mock.
async function lockAssignmentKeys(
  tx: TxClient,
  keys: Array<{ venueId: string; profileId: string; dayIndex: number }>,
) {
  const uniqueKeys = Array.from(
    new Set(keys.map((k) => `schedule:${k.venueId}:${k.profileId}:${k.dayIndex}`)),
  ).sort();
  for (const key of uniqueKeys) {
    await tx.$executeRaw`SELECT pg_advisory_xact_lock(hashtext(${key}))`;
  }
}

async function assertNoDoubleBookTx(
  tx: TxClient,
  venueId: string,
  profileId: string,
  dayIndex: number,
  startMinutes: number,
  endMinutes: number,
  ...excludeShiftIds: Array<string | undefined>
) {
  const excluded = excludeShiftIds.filter((id): id is string => Boolean(id));
  const overlapping = await tx.scheduleShift.findFirst({
    where: {
      venueId,
      profileId,
      dayIndex,
      ...(excluded.length > 0 ? { id: { notIn: excluded } } : {}),
      startMinutes: { lt: endMinutes },
      endMinutes: { gt: startMinutes },
    },
  });
  if (overlapping) throw new Error('DOUBLE_BOOK');
}

let prisma: PrismaClient;
let teardown: () => Promise<void> = async () => {};

// Cast PrismaClient as PrismaService for withSerializableRetry compatibility
const asPrismaService = () => prisma as unknown as Parameters<typeof withSerializableRetry>[0];

beforeAll(async () => {
  const db = await setupTestDb();
  prisma = db.prisma;
  teardown = db.teardown;
});

afterAll(async () => {
  await teardown();
}, 15_000);

describe('scheduling concurrency (integration)', () => {
  afterEach(async () => {
    await cleanSchedulingData(prisma);
  });

  // ── Double-book prevention ─────────────────────────────────────────────
  describe('double-book prevention via assignShift', () => {
    it('blocks two concurrent assignments to the same person on the same time slot', async () => {
      const { venue, profileA } = await seedSchedulingFixtures(prisma);

      // Create two open shifts at the same time
      const [shift1, shift2] = await Promise.all([
        prisma.scheduleShift.create({
          data: { venueId: venue.id, weekStart: '2026-08-24', dayIndex: 2, startMinutes: 480, endMinutes: 720, jobTitle: 'Server', station: 'Bar', status: 'open' },
        }),
        prisma.scheduleShift.create({
          data: { venueId: venue.id, weekStart: '2026-08-24', dayIndex: 2, startMinutes: 480, endMinutes: 720, jobTitle: 'Server', station: 'Patio', status: 'open' },
        }),
      ]);

      // Simulate two concurrent manager assigns of the same person to overlapping shifts.
      // One should succeed, one should fail with DOUBLE_BOOK or serialization conflict.
      const assign = (shiftId: string) =>
        withSerializableRetry(asPrismaService(), async (tx) => {
          await lockAssignmentKeys(tx, [{ venueId: venue.id, profileId: profileA.id, dayIndex: 2 }]);
          await assertNoDoubleBookTx(tx, venue.id, profileA.id, 2, 480, 720, shiftId);
          await tx.scheduleShift.update({ where: { id: shiftId }, data: { profileId: profileA.id, status: 'scheduled' } });
          return shiftId;
        });

      const results = await Promise.allSettled([assign(shift1.id), assign(shift2.id)]);

      const fulfilled = results.filter((r) => r.status === 'fulfilled');
      const rejected = results.filter((r) => r.status === 'rejected');

      expect(fulfilled.length).toBe(1);
      expect(rejected.length).toBe(1);

      // Verify only one shift is actually assigned in the DB
      const assigned = await prisma.scheduleShift.findMany({
        where: { venueId: venue.id, profileId: profileA.id, dayIndex: 2 },
      });
      expect(assigned.length).toBe(1);
    });
  });

  // ── Claim race ─────────────────────────────────────────────────────────
  describe('claim race via claimOpenShift', () => {
    it('only one of two simultaneous claims wins', async () => {
      const { venue, profileA, profileB, openShift } = await seedSchedulingFixtures(prisma);

      // Mirror the controller's optimistic updateMany pattern
      const claim = (profileId: string) =>
        prisma.scheduleShift.updateMany({
          where: { id: openShift.id, venueId: venue.id, status: 'open', profileId: null },
          data: { profileId, status: 'covered' },
        });

      const [r1, r2] = await Promise.all([claim(profileA.id), claim(profileB.id)]);

      // Exactly one updateMany should have matched (count=1), the other sees count=0
      expect(r1.count + r2.count).toBe(1);

      const shift = await prisma.scheduleShift.findUnique({ where: { id: openShift.id } });
      expect(shift!.status).toBe('covered');
      expect(shift!.profileId).toBeTruthy();
    });
  });

  // ── Swap atomicity ─────────────────────────────────────────────────────
  describe('swap approval atomicity', () => {
    it('concurrent swap approvals cannot both succeed', async () => {
      const { venue, profileA, profileB } = await seedSchedulingFixtures(prisma);

      // Create two shifts, one per person
      const [shiftA, shiftB] = await Promise.all([
        prisma.scheduleShift.create({
          data: { venueId: venue.id, weekStart: '2026-08-24', profileId: profileA.id, dayIndex: 3, startMinutes: 600, endMinutes: 900, jobTitle: 'Server', station: 'Bar', status: 'scheduled' },
        }),
        prisma.scheduleShift.create({
          data: { venueId: venue.id, weekStart: '2026-08-24', profileId: profileB.id, dayIndex: 3, startMinutes: 600, endMinutes: 900, jobTitle: 'Server', station: 'Patio', status: 'scheduled' },
        }),
      ]);

      // Create a swap request (A wants B's shift)
      const swap = await prisma.shiftSwap.create({
        data: {
          venueId: venue.id,
          requesterProfileId: profileA.id,
          requesterShiftId: shiftA.id,
          targetProfileId: profileB.id,
          targetShiftId: shiftB.id,
          status: 'accepted',
        },
      });

      // Simulate two concurrent manager approvals of the same swap
      const approveSwap = () =>
        withSerializableRetry(asPrismaService(), async (tx) => {
          const requesterShift = await tx.scheduleShift.findFirst({ where: { id: swap.requesterShiftId, venueId: venue.id } });
          const targetShift = await tx.scheduleShift.findFirst({ where: { id: swap.targetShiftId!, venueId: venue.id } });
          if (!requesterShift || !targetShift) throw new Error('SHIFT_NOT_FOUND');

          await lockAssignmentKeys(tx, [
            { venueId: venue.id, profileId: swap.targetProfileId!, dayIndex: requesterShift.dayIndex },
            { venueId: venue.id, profileId: swap.requesterProfileId!, dayIndex: targetShift.dayIndex },
          ]);

          await assertNoDoubleBookTx(tx, venue.id, swap.targetProfileId!, requesterShift.dayIndex, requesterShift.startMinutes, requesterShift.endMinutes, requesterShift.id, targetShift.id);
          await assertNoDoubleBookTx(tx, venue.id, swap.requesterProfileId!, targetShift.dayIndex, targetShift.startMinutes, targetShift.endMinutes, targetShift.id, requesterShift.id);

          await tx.scheduleShift.update({ where: { id: requesterShift.id }, data: { profileId: swap.targetProfileId, status: 'scheduled' } });
          await tx.scheduleShift.update({ where: { id: targetShift.id }, data: { profileId: swap.requesterProfileId, status: 'scheduled' } });

          const reviewed = await tx.shiftSwap.updateMany({
            where: { id: swap.id, status: { in: ['accepted', 'proposed'] } },
            data: { status: 'approved' },
          });
          if (reviewed.count === 0) throw new Error('SWAP_ALREADY_REVIEWED');
        });

      const results = await Promise.allSettled([approveSwap(), approveSwap()]);

      const fulfilled = results.filter((r) => r.status === 'fulfilled');
      // At most one should succeed; the other hits serialization failure or the
      // updateMany guard (status already 'approved').
      expect(fulfilled.length).toBeLessThanOrEqual(1);

      // Verify DB state is consistent: each shift belongs to exactly one person
      const finalA = await prisma.scheduleShift.findUnique({ where: { id: shiftA.id } });
      const finalB = await prisma.scheduleShift.findUnique({ where: { id: shiftB.id } });
      expect(finalA!.profileId).not.toBe(finalB!.profileId);
    });
  });

  // ── Non-overlapping shifts should both succeed ─────────────────────────
  describe('non-overlapping shifts', () => {
    it('allows the same person to hold two non-overlapping shifts on the same day', async () => {
      const { venue, profileA } = await seedSchedulingFixtures(prisma);

      const [morning, evening] = await Promise.all([
        prisma.scheduleShift.create({
          data: { venueId: venue.id, weekStart: '2026-08-24', dayIndex: 4, startMinutes: 480, endMinutes: 720, jobTitle: 'Server', station: 'Bar', status: 'open' },
        }),
        prisma.scheduleShift.create({
          data: { venueId: venue.id, weekStart: '2026-08-24', dayIndex: 4, startMinutes: 960, endMinutes: 1200, jobTitle: 'Server', station: 'Patio', status: 'open' },
        }),
      ]);

      const assign = (shiftId: string) =>
        withSerializableRetry(asPrismaService(), async (tx) => {
          await lockAssignmentKeys(tx, [{ venueId: venue.id, profileId: profileA.id, dayIndex: 4 }]);
          const shift = await tx.scheduleShift.findFirst({ where: { id: shiftId } });
          await assertNoDoubleBookTx(tx, venue.id, profileA.id, 4, shift!.startMinutes, shift!.endMinutes, shiftId);
          await tx.scheduleShift.update({ where: { id: shiftId }, data: { profileId: profileA.id, status: 'scheduled' } });
        });

      // Both should succeed — no overlap
      const results = await Promise.allSettled([assign(morning.id), assign(evening.id)]);
      expect(results.every((r) => r.status === 'fulfilled')).toBe(true);

      const assigned = await prisma.scheduleShift.findMany({
        where: { venueId: venue.id, profileId: profileA.id, dayIndex: 4 },
      });
      expect(assigned.length).toBe(2);
    });
  });
});

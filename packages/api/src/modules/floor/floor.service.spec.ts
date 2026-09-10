import { ConflictException } from '@nestjs/common';
import { describe, expect, it, vi } from 'vitest';
import { FloorService } from './floor.service';

describe('FloorService regressions', () => {
  it('serializes floor-plan saves per venue', async () => {
    const transaction = {
      $executeRaw: vi.fn().mockResolvedValue(undefined),
      floorPlan: {
        findFirst: vi.fn().mockResolvedValue({ id: 'plan-1', width: 800, height: 600 }),
        update: vi.fn().mockResolvedValue({ id: 'plan-1' }),
      },
      floorTable: { findMany: vi.fn().mockResolvedValue([]), deleteMany: vi.fn() },
      tableAssignment: { count: vi.fn().mockResolvedValue(0) },
      floorChair: { deleteMany: vi.fn().mockResolvedValue({ count: 0 }), createMany: vi.fn() },
    };
    const prisma = {
      $transaction: vi.fn((callback: (tx: typeof transaction) => unknown) => callback(transaction)),
    };
    const service = new FloorService(prisma as any, {} as any);

    await service.saveFloorPlan('venue-1', { tables: [] });

    expect(transaction.$executeRaw).toHaveBeenCalledOnce();
    expect(transaction.floorPlan.findFirst).toHaveBeenCalledWith({ where: { venueId: 'venue-1', isActive: true } });
  });

  it('writes floor-plan table creates and updates as set-based batches, not per-row', async () => {
    // Regression for the sequential for-loop that drove one create()/update()
    // round-trip per table inside this same advisory-locked transaction —
    // unbounded before @ArrayMaxSize(500), and still up to 500 round-trips
    // even capped. This asserts the batch shape directly rather than just
    // checking the save succeeds.
    const transaction = {
      $executeRaw: vi.fn().mockResolvedValue(undefined),
      floorPlan: {
        findFirst: vi.fn().mockResolvedValue({ id: 'plan-1', width: 800, height: 600 }),
        update: vi.fn().mockResolvedValue({ id: 'plan-1' }),
      },
      floorTable: {
        findMany: vi.fn().mockResolvedValue([{ id: 'existing-1' }]),
        deleteMany: vi.fn(),
        createMany: vi.fn().mockResolvedValue({ count: 1 }),
        create: vi.fn(),
        update: vi.fn(),
      },
      tableState: {
        createMany: vi.fn().mockResolvedValue({ count: 1 }),
        create: vi.fn(),
      },
      tableAssignment: { count: vi.fn().mockResolvedValue(0) },
      floorChair: { deleteMany: vi.fn().mockResolvedValue({ count: 0 }), createMany: vi.fn() },
    };
    const prisma = {
      $transaction: vi.fn((callback: (tx: typeof transaction) => unknown) => callback(transaction)),
    };
    const service = new FloorService(prisma as any, {} as any);

    await service.saveFloorPlan('venue-1', {
      tables: [
        { id: 'existing-1', label: 'A1', x: 0, y: 0, width: 10, height: 10, shape: 'round', capacity: 4 },
        { label: 'A2', x: 1, y: 1, width: 10, height: 10, shape: 'square', capacity: 2 },
      ],
    });

    expect(transaction.floorTable.createMany).toHaveBeenCalledTimes(1);
    expect(transaction.floorTable.createMany.mock.calls[0][0].data).toHaveLength(1);
    // Regression for VW-09: FloorTable now carries its own venueId.
    expect(transaction.floorTable.createMany.mock.calls[0][0].data[0]).toEqual(
      expect.objectContaining({ venueId: 'venue-1' }),
    );
    expect(transaction.floorTable.create).not.toHaveBeenCalled();
    expect(transaction.floorTable.update).not.toHaveBeenCalled();
    expect(transaction.tableState.createMany).toHaveBeenCalledTimes(1);
    expect(transaction.tableState.create).not.toHaveBeenCalled();
    // One advisory-lock call plus exactly one bulk UPDATE...FROM (VALUES) —
    // not one $executeRaw per updated table.
    expect(transaction.$executeRaw).toHaveBeenCalledTimes(2);
    const updateSql = (transaction.$executeRaw.mock.calls[1][0] as TemplateStringsArray).join('');
    expect(updateSql).toContain('UPDATE "FloorTable"');
    expect(updateSql).toContain('FROM (VALUES');
  });

  it('skips both the create and update batches when saveFloorPlan is called with no tables', async () => {
    const transaction = {
      $executeRaw: vi.fn().mockResolvedValue(undefined),
      floorPlan: {
        findFirst: vi.fn().mockResolvedValue({ id: 'plan-1', width: 800, height: 600 }),
        update: vi.fn().mockResolvedValue({ id: 'plan-1' }),
      },
      floorTable: { findMany: vi.fn().mockResolvedValue([]), deleteMany: vi.fn(), createMany: vi.fn() },
      tableState: { createMany: vi.fn() },
      tableAssignment: { count: vi.fn().mockResolvedValue(0) },
      floorChair: { deleteMany: vi.fn().mockResolvedValue({ count: 0 }), createMany: vi.fn() },
    };
    const prisma = {
      $transaction: vi.fn((callback: (tx: typeof transaction) => unknown) => callback(transaction)),
    };
    const service = new FloorService(prisma as any, {} as any);

    await service.saveFloorPlan('venue-1', { tables: [] });

    expect(transaction.floorTable.createMany).not.toHaveBeenCalled();
    expect(transaction.tableState.createMany).not.toHaveBeenCalled();
    // Only the advisory lock — no bulk UPDATE issued for zero updated tables.
    expect(transaction.$executeRaw).toHaveBeenCalledTimes(1);
  });

  it('returns the saved seat-label style in the active floor payload', async () => {
    const now = new Date();
    const prisma = {
      floorPlan: { findFirst: vi.fn().mockResolvedValue({
        id: 'plan-1', venueId: 'venue-1', name: 'Main', width: 900, height: 600,
        backgroundImageUrl: null, isActive: true, createdAt: now, updatedAt: now,
        chairs: [],
        tables: [{
          id: 'table-1', floorPlanId: 'plan-1', label: '12', shape: 'round', seats: 4,
          seatLabelStyle: 'letter', x: 10, y: 20, width: 80, height: 80, rotation: 0,
          section: 'main', minSpend: 0, isReservable: true,
        }],
      }) },
      tableState: { findMany: vi.fn().mockResolvedValue([]) },
      tableAssignment: { findMany: vi.fn().mockResolvedValue([]) },
    };
    const service = new FloorService(prisma as any, {} as any);

    const result = await service.getActiveFloorPlan('venue-1');

    expect(result?.tables[0].table.seatLabelStyle).toBe('letter');
  });

  it('requires an existing merge to be split before those tables are merged again', async () => {
    const transaction = {
      $executeRaw: vi.fn().mockResolvedValue(undefined),
      tableState: { findMany: vi.fn().mockResolvedValue([
        { id: 's1', tableId: 't1', status: 'seated', mergeGroupId: 'group-1' },
        { id: 's2', tableId: 't2', status: 'seated', mergeGroupId: 'group-1' },
      ]), updateMany: vi.fn() },
    };
    const prisma = {
      floorPlan: { findFirst: vi.fn().mockResolvedValue({ tables: [{ id: 't1' }, { id: 't2' }] }) },
      $transaction: vi.fn((callback: (tx: typeof transaction) => unknown) => callback(transaction)),
    };
    const service = new FloorService(prisma as any, {} as any);

    await expect(service.mergeTablesForParty('venue-1', ['t1', 't2'], 6)).rejects.toThrow(ConflictException);
    expect(transaction.tableState.updateMany).not.toHaveBeenCalled();
  });

  it('rejects a table-status write that loses an optimistic concurrency race', async () => {
    const lastActivityAt = new Date();
    const prisma = {
      tableState: {
        findFirst: vi.fn().mockResolvedValue({ id: 'state-1', lastActivityAt }),
        updateMany: vi.fn().mockResolvedValue({ count: 0 }),
      },
    };
    const service = new FloorService(prisma as any, {} as any);

    await expect(service.updateTableStatus('venue-1', 'table-1', 'dirty')).rejects.toThrow(
      'Table status changed. Refresh and try again.',
    );
    expect(prisma.tableState.updateMany).toHaveBeenCalledWith(expect.objectContaining({
      where: { id: 'state-1', venueId: 'venue-1', lastActivityAt },
    }));
  });
  it('keeps a party marked Ready in the queue that offers the Seat action', async () => {
    // Regression: getOpenWaitlist filtered to status 'waiting', while
    // markWaitlistReady moves the row to 'assigned' — so marking a party Ready
    // removed it from the only list a host can seat from.
    const prisma = {
      waitlist: {
        findMany: vi.fn().mockResolvedValue([
          { id: 'w-1', guestName: 'Ana', partySize: 2, guestPhone: null, notes: null, status: 'assigned', readyAt: new Date('2026-09-02T18:00:00Z'), requestedAt: new Date('2026-09-02T17:30:00Z') },
        ]),
      },
    };
    const service = new FloorService(prisma as any, {} as any);

    const rows = await service.getOpenWaitlist('venue-1');

    expect(prisma.waitlist.findMany).toHaveBeenCalledWith(expect.objectContaining({
      where: { venueId: 'venue-1', status: { in: ['waiting', 'assigned'] } },
    }));
    expect(rows).toHaveLength(1);
    expect(rows[0].isReady).toBe(true);
  });

  it('walks seated bookings back when clearing the floor plan deletes their assignments', async () => {
    // Regression: clearing the plan deleted the assignments but left the
    // reservation reading 'seated' and the waitlist entry 'seated'/'assigned',
    // pointing at a table that no longer exists.
    const prisma = {
      floorPlan: {
        findFirst: vi.fn().mockResolvedValue({ id: 'plan-1', tables: [{ id: 't1' }], chairs: [{ id: 'c1' }] }),
        update: vi.fn(),
      },
      tableAssignment: {
        findMany: vi.fn().mockResolvedValue([
          { reservationId: 'res-1', waitlistId: null },
          { reservationId: null, waitlistId: 'w-1' },
        ]),
        deleteMany: vi.fn(),
      },
      tableState: { deleteMany: vi.fn() },
      floorChair: { deleteMany: vi.fn() },
      floorTable: { deleteMany: vi.fn() },
      reservation: { updateMany: vi.fn() },
      waitlist: { updateMany: vi.fn() },
      $transaction: vi.fn().mockResolvedValue([]),
    };
    const service = new FloorService(prisma as any, {} as any);

    const result = await service.clearActiveFloorPlan('venue-1');

    expect(prisma.reservation.updateMany).toHaveBeenCalledWith({
      where: { id: { in: ['res-1'] }, venueId: 'venue-1', status: 'seated' },
      data: { status: 'confirmed' },
    });
    expect(prisma.waitlist.updateMany).toHaveBeenCalledWith({
      where: { id: { in: ['w-1'] }, venueId: 'venue-1', status: { in: ['seated', 'assigned'] } },
      data: { status: 'waiting', readyAt: null },
    });
    expect(result.releasedReservations).toBe(1);
    expect(result.releasedWaitlistEntries).toBe(1);
  });

  describe('refreshTableStates via releaseAssignment', () => {
    const makePrisma = (currentStatus: string) => ({
      tableAssignment: {
        findFirst: vi.fn().mockResolvedValue({ id: 'assign-1', tableId: 'table-1', reservationId: null, waitlistId: null }),
        updateMany: vi.fn().mockResolvedValue({ count: 1 }),
        findMany: vi.fn().mockResolvedValue([]),
        count: vi.fn().mockResolvedValue(0),
      },
      tableState: {
        findMany: vi.fn().mockResolvedValue([{ tableId: 'table-1', status: currentStatus }]),
        updateMany: vi.fn().mockResolvedValue({ count: 1 }),
      },
      floorTable: { findFirst: vi.fn().mockResolvedValue({ seats: 0 }) },
    });

    it.each(['dirty', 'out_of_service'])(
      'leaves a %s table in that state when no seating is active on it',
      async (status) => {
        const prisma = makePrisma(status);
        await new FloorService(prisma as any, {} as any).releaseAssignment('venue-1', 'assign-1');

        const stateWrite = prisma.tableState.updateMany.mock.calls.at(-1)?.[0];
        expect(stateWrite.data).not.toHaveProperty('status');
        expect(stateWrite.data).toEqual(expect.objectContaining({ partySize: null, seatedAt: null }));
      },
    );

    it('returns a held party to the queue instead of completing them', async () => {
      // getOpenWaitlist lists 'waiting' and 'assigned' only, and it is the one
      // list with a Seat action — completing an 'assigned' party made them
      // vanish and left re-seating throwing NotFound.
      const prisma = makePrisma('held');
      prisma.tableAssignment.findFirst.mockResolvedValue({ id: 'assign-1', tableId: 'table-1', reservationId: null, waitlistId: 'wl-1' });
      (prisma as any).waitlist = {
        findFirst: vi.fn().mockResolvedValue({ status: 'assigned' }),
        update: vi.fn().mockResolvedValue({}),
      };

      await new FloorService(prisma as any, {} as any).releaseAssignment('venue-1', 'assign-1');

      expect((prisma as any).waitlist.update).toHaveBeenCalledWith(
        expect.objectContaining({ data: { status: 'waiting', readyAt: null } }),
      );
    });

    it('completes a seated party when their table is released', async () => {
      const prisma = makePrisma('seated');
      prisma.tableAssignment.findFirst.mockResolvedValue({ id: 'assign-1', tableId: 'table-1', reservationId: null, waitlistId: 'wl-1' });
      (prisma as any).waitlist = {
        findFirst: vi.fn().mockResolvedValue({ status: 'seated' }),
        update: vi.fn().mockResolvedValue({}),
      };

      await new FloorService(prisma as any, {} as any).releaseAssignment('venue-1', 'assign-1');

      expect((prisma as any).waitlist.update).toHaveBeenCalledWith(
        expect.objectContaining({ data: { status: 'completed' } }),
      );
    });

    it('frees an ordinary table back to available', async () => {
      const prisma = makePrisma('seated');
      await new FloorService(prisma as any, {} as any).releaseAssignment('venue-1', 'assign-1');

      const stateWrite = prisma.tableState.updateMany.mock.calls.at(-1)?.[0];
      expect(stateWrite.data).toEqual(expect.objectContaining({ status: 'available', partySize: null }));
    });
  });


  describe('seating window', () => {
    const makeAssignPrisma = () => {
      const tx = {
        tableAssignment: {
          findMany: vi.fn().mockResolvedValue([]),
          findFirst: vi.fn().mockResolvedValue(null),
          updateMany: vi.fn().mockResolvedValue({ count: 0 }),
          create: vi.fn().mockResolvedValue({}),
        },
        tableState: { updateMany: vi.fn().mockResolvedValue({ count: 1 }), findMany: vi.fn().mockResolvedValue([]) },
        reservation: { update: vi.fn().mockResolvedValue({}) },
      };
      const prisma: any = {
        reservation: { findFirst: vi.fn().mockResolvedValue({ id: 'res-1', partySize: 4, durationMinutes: 120, reservationTime: new Date() }) },
        floorPlan: { findFirst: vi.fn().mockResolvedValue({ tables: [{ id: 'table-1' }] }) },
        tableAssignment: tx.tableAssignment,
        tableState: tx.tableState,
        $transaction: vi.fn((cb: any) => cb(tx)),
      };
      return { prisma, tx };
    };

    it('seats a party who arrived before their booking time', async () => {
      // The host screen sends the reservation's scheduled startsAt, so an early
      // seat has a window that has not opened yet. It must still take the table.
      const { prisma, tx } = makeAssignPrisma();
      const inThirtyMinutes = Date.now() + 30 * 60 * 1000;

      await new FloorService(prisma, {} as any).assignReservationToTables('venue-1', 'res-1', ['table-1'], {
        holdType: 'seated',
        startsAt: inThirtyMinutes,
        endsAt: inThirtyMinutes + 120 * 60 * 1000,
      });

      expect(tx.tableState.updateMany).toHaveBeenCalledWith(
        expect.objectContaining({ data: expect.objectContaining({ status: 'seated' }) }),
      );
      expect(tx.reservation.update).toHaveBeenCalledWith(
        expect.objectContaining({ data: { status: 'seated' } }),
      );
    });

    it('records an early seating as starting now, not at the booked time', async () => {
      // Consumers select assignments with startsAt <= now < endsAt. Persisting
      // the scheduled 19:00 start while writing a seated TableState left the
      // two disagreeing: merging the party's tables threw, and any refresh
      // before 19:00 reset the table to available with guests still at it.
      const { prisma, tx } = makeAssignPrisma();
      const before = Date.now();
      const inThirtyMinutes = before + 30 * 60 * 1000;

      await new FloorService(prisma, {} as any).assignReservationToTables('venue-1', 'res-1', ['table-1'], {
        holdType: 'seated',
        startsAt: inThirtyMinutes,
        endsAt: inThirtyMinutes + 120 * 60 * 1000,
      });

      const row = tx.tableAssignment.create.mock.calls[0][0].data;
      expect(row.startsAt.getTime()).toBeGreaterThanOrEqual(before);
      expect(row.startsAt.getTime()).toBeLessThan(inThirtyMinutes);
      // The booked duration is preserved, just shifted.
      expect(row.endsAt.getTime() - row.startsAt.getTime()).toBe(120 * 60 * 1000);
      expect(row.startsAt.getTime()).toBeLessThanOrEqual(Date.now());
      expect(row.endsAt.getTime()).toBeGreaterThan(Date.now());
    });

    it('records a late seating as starting now too', async () => {
      const { prisma, tx } = makeAssignPrisma();
      const threeHoursAgo = Date.now() - 3 * 60 * 60 * 1000;

      await new FloorService(prisma, {} as any).assignReservationToTables('venue-1', 'res-1', ['table-1'], {
        holdType: 'seated',
        startsAt: threeHoursAgo,
        endsAt: threeHoursAgo + 90 * 60 * 1000,
      });

      const row = tx.tableAssignment.create.mock.calls[0][0].data;
      // The booked window closed an hour and a half ago; a party sitting down
      // now still has to occupy the table now.
      expect(row.endsAt.getTime()).toBeGreaterThan(Date.now());
      expect(row.startsAt.getTime()).toBeLessThanOrEqual(Date.now());
    });

    it('keeps a future reservation hold on its booked window', async () => {
      const { prisma, tx } = makeAssignPrisma();
      const tomorrow = Date.now() + 24 * 60 * 60 * 1000;

      await new FloorService(prisma, {} as any).assignReservationToTables('venue-1', 'res-1', ['table-1'], {
        holdType: 'reserved',
        startsAt: tomorrow,
        endsAt: tomorrow + 120 * 60 * 1000,
      });

      const row = tx.tableAssignment.create.mock.calls[0][0].data;
      expect(row.startsAt.getTime()).toBe(tomorrow);
    });

    it('leaves the table free for a reservation hold whose window has not opened', async () => {
      const { prisma, tx } = makeAssignPrisma();
      const tomorrow = Date.now() + 24 * 60 * 60 * 1000;

      await new FloorService(prisma, {} as any).assignReservationToTables('venue-1', 'res-1', ['table-1'], {
        holdType: 'reserved',
        startsAt: tomorrow,
        endsAt: tomorrow + 120 * 60 * 1000,
      });

      // The hold is recorded, but the table stays free until its window opens:
      // the only state write is the refresh settling it back to available.
      const statuses = tx.tableState.updateMany.mock.calls.map((call: any[]) => call[0].data.status);
      expect(statuses).not.toContain('reserved');
      expect(statuses).not.toContain('seated');
      expect(statuses).toContain('available');
      expect(tx.reservation.update).not.toHaveBeenCalled();
    });
  });

});

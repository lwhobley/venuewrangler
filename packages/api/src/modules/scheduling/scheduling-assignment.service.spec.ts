import { BadRequestException, NotFoundException } from '@nestjs/common';
import { describe, expect, it, vi } from 'vitest';
import { SchedulingAssignmentService } from './scheduling-assignment.service';

describe('SchedulingAssignmentService', () => {
  it('rejects non-members during assignment', async () => {
    const prisma = {
      scheduleShift: {
        findFirst: vi.fn().mockResolvedValue({
          id: 'shift-1',
          venueId: 'venue-1',
          dayIndex: 2,
          startMinutes: 480,
          endMinutes: 720,
          profileId: null,
          status: 'open',
        }),
      },
      profile: { findFirst: vi.fn().mockResolvedValue(null) },
    };
    const service = new SchedulingAssignmentService(prisma as any);

    await expect(
      service.assignShift({ venueId: 'venue-1', shiftId: 'shift-1', profileId: 'profile-1' }),
    ).rejects.toThrow(BadRequestException);
  });

  it('rejects overlap checks when another shift conflicts', async () => {
    const prisma = {
      scheduleShift: {
        findMany: vi.fn().mockResolvedValue([{ weekStart: null, dayIndex: 2, startMinutes: 480, endMinutes: 720 }]),
      },
    };
    const service = new SchedulingAssignmentService(prisma as any);

    await expect(
      service.assertNoDoubleBook('venue-1', 'profile-1', 2, 480, 720, 'shift-1'),
    ).rejects.toThrow('This assignment overlaps another shift.');
  });

  it('rejects a Monday morning shift that overlaps Sunday overnight', async () => {
    const prisma = {
      scheduleShift: {
        findMany: vi.fn().mockResolvedValue([
          { weekStart: null, dayIndex: 0, startMinutes: 1320, endMinutes: 1560 },
        ]),
      },
    };
    const service = new SchedulingAssignmentService(prisma as any);

    await expect(
      service.assertNoDoubleBookTx(
        prisma as any,
        'venue-1',
        'profile-1',
        1,
        60,
        180,
      ),
    ).rejects.toThrow('This assignment overlaps another shift.');
  });

  it('throws when the venue shift does not exist', async () => {
    const prisma = {
      scheduleShift: {
        findFirst: vi.fn().mockResolvedValue(null),
      },
    };
    const service = new SchedulingAssignmentService(prisma as any);

    await expect(service.getVenueShift('venue-1', 'missing')).rejects.toThrow(NotFoundException);
  });

  it('applies an open assignment and marks the schedule edited', async () => {
    const shift = {
      id: 'shift-1',
      venueId: 'venue-1',
      dayIndex: 2,
      startMinutes: 480,
      endMinutes: 720,
      profileId: null,
      status: 'open',
      jobTitle: 'Server',
      station: 'Patio',
    };
    const prisma = {
      scheduleShift: {
        findFirst: vi.fn().mockResolvedValue(shift),
        findMany: vi.fn().mockResolvedValue([]),
        update: vi.fn().mockResolvedValue({}),
      },
      profile: {
        findFirst: vi.fn().mockResolvedValue({ id: 'profile-1', venueId: 'venue-1' }),
      },
      venue: {
        update: vi.fn().mockResolvedValue({}),
      },
      $executeRaw: vi.fn().mockResolvedValue(1),
      $transaction: vi.fn(async (fn: (tx: unknown) => Promise<unknown>) => fn(prisma as unknown)),
    };
    const service = new SchedulingAssignmentService(prisma as any);
    vi.spyOn(service, 'lockAssignmentKeys').mockResolvedValue(undefined);
    vi.spyOn(service, 'assertNoDoubleBookTx').mockResolvedValue(undefined);

    const result = await service.applyOpenAssignments({
      venueId: 'venue-1',
      assignments: [{ shiftId: 'shift-1', profileId: 'profile-1' }],
      canAssign: () => true,
    });

    expect(result.assigned).toBe(1);
    expect(result.skipped).toBe(0);
    expect(result.assignedShifts[0]?.shiftId).toBe('shift-1');
    expect(prisma.venue.update).toHaveBeenCalled();
  });

  it('creates a scheduled shift with trimmed fields and venue touch', async () => {
    const createdShift = { id: 'shift-2' };
    const prisma = {
      scheduleShift: {
        create: vi.fn().mockResolvedValue(createdShift),
        findMany: vi.fn().mockResolvedValue([]),
      },
      profile: {
        findFirst: vi.fn().mockResolvedValue({ id: 'profile-1', venueId: 'venue-1' }),
      },
      venue: {
        update: vi.fn().mockResolvedValue({}),
      },
      $executeRaw: vi.fn().mockResolvedValue(1),
      $transaction: vi.fn(async (fn: (tx: unknown) => Promise<unknown>) => fn(prisma as unknown)),
    };
    const service = new SchedulingAssignmentService(prisma as any);
    vi.spyOn(service, 'lockAssignmentKeys').mockResolvedValue(undefined);
    vi.spyOn(service, 'assertNoDoubleBookTx').mockResolvedValue(undefined);

    const result = await service.createShift({
      venueId: 'venue-1',
      weekStart: '2026-08-24',
      profileId: 'profile-1',
      dayIndex: 3,
      startMinutes: 600,
      endMinutes: 900,
      jobTitle: '  Server  ',
      station: '  Patio  ',
      notes: '  Closing  ',
    });

    expect(result).toBe(createdShift);
    expect(prisma.scheduleShift.create).toHaveBeenCalledWith({
      data: expect.objectContaining({
        venueId: 'venue-1',
        weekStart: '2026-08-24',
        profileId: 'profile-1',
        dayIndex: 3,
        startMinutes: 600,
        endMinutes: 900,
        jobTitle: 'Server',
        station: 'Patio',
        notes: 'Closing',
        status: 'scheduled',
      }),
    });
    expect(prisma.venue.update).toHaveBeenCalled();
  });

  it('updates an assigned shift with overlap locking and normalized fields', async () => {
    const shift = {
      id: 'shift-3',
      venueId: 'venue-1',
      profileId: 'profile-1',
      dayIndex: 1,
      startMinutes: 480,
      endMinutes: 720,
      jobTitle: 'Barback',
      station: 'Main',
      status: 'scheduled',
    };
    const prisma = {
      scheduleShift: {
        findFirst: vi.fn().mockResolvedValue(shift),
        findMany: vi.fn().mockResolvedValue([]),
        update: vi.fn().mockResolvedValue({}),
      },
      venue: {
        update: vi.fn().mockResolvedValue({}),
      },
      $executeRaw: vi.fn().mockResolvedValue(1),
      $transaction: vi.fn(async (fn: (tx: unknown) => Promise<unknown>) => fn(prisma as unknown)),
    };
    const service = new SchedulingAssignmentService(prisma as any);
    const lockSpy = vi.spyOn(service, 'lockAssignmentKeys').mockResolvedValue(undefined);

    const result = await service.updateShift({
      venueId: 'venue-1',
      shiftId: 'shift-3',
      dayIndex: 2,
      startMinutes: 540,
      endMinutes: 780,
      jobTitle: '  Lead Server ',
      station: '  Roof ',
      notes: '  Swap approved ',
    });

    expect(result).toEqual(shift);
    expect(lockSpy).toHaveBeenCalled();
    expect(prisma.scheduleShift.findMany).toHaveBeenCalled();
    expect(prisma.scheduleShift.update).toHaveBeenCalledWith({
      where: { id: 'shift-3' },
      data: {
        dayIndex: 2,
        startMinutes: 540,
        endMinutes: 780,
        jobTitle: 'Lead Server',
        station: 'Roof',
        notes: 'Swap approved',
      },
    });
    expect(prisma.venue.update).toHaveBeenCalled();
  });

  it('re-reads the shift inside the transaction so a concurrent reassignment is checked against the current assignee', async () => {
    const staleShift = {
      id: 'shift-5',
      venueId: 'venue-1',
      profileId: 'profile-1',
      dayIndex: 1,
      startMinutes: 480,
      endMinutes: 720,
      jobTitle: 'Barback',
      station: 'Main',
      status: 'scheduled',
    };
    const reassignedShift = { ...staleShift, profileId: 'profile-2' };
    const prisma = {
      scheduleShift: {
        findFirst: vi.fn()
          .mockResolvedValueOnce(staleShift)
          .mockResolvedValueOnce(reassignedShift),
        findMany: vi.fn().mockResolvedValue([]),
        update: vi.fn().mockResolvedValue({}),
      },
      venue: {
        update: vi.fn().mockResolvedValue({}),
      },
      $executeRaw: vi.fn().mockResolvedValue(1),
      $transaction: vi.fn(async (fn: (tx: unknown) => Promise<unknown>) => fn(prisma as unknown)),
    };
    const service = new SchedulingAssignmentService(prisma as any);
    const lockSpy = vi.spyOn(service, 'lockAssignmentKeys').mockResolvedValue(undefined);

    const result = await service.updateShift({
      venueId: 'venue-1',
      shiftId: 'shift-5',
      dayIndex: 2,
      startMinutes: 540,
      endMinutes: 780,
      jobTitle: 'Lead Server',
      station: 'Roof',
    });

    expect(lockSpy).toHaveBeenCalledWith(
      expect.anything(),
      expect.arrayContaining([expect.objectContaining({ profileId: 'profile-2' })]),
    );
    expect(prisma.scheduleShift.findMany).toHaveBeenCalled();
    expect(result.profileId).toBe('profile-2');
  });

  it('deletes a venue shift and marks the schedule edited', async () => {
    const shift = {
      id: 'shift-4',
      venueId: 'venue-1',
      profileId: 'profile-1',
      dayIndex: 4,
      startMinutes: 660,
      endMinutes: 900,
      jobTitle: 'Host',
      station: 'Front',
      status: 'scheduled',
      notes: null,
    };
    const prisma = {
      scheduleShift: {
        findFirst: vi.fn().mockResolvedValue(shift),
        delete: vi.fn().mockResolvedValue({}),
      },
      venue: {
        update: vi.fn().mockResolvedValue({}),
      },
    };
    const service = new SchedulingAssignmentService(prisma as any);

    const result = await service.deleteShift({
      venueId: 'venue-1',
      shiftId: 'shift-4',
    });

    expect(result).toBe(shift);
    expect(prisma.scheduleShift.delete).toHaveBeenCalledWith({
      where: { id: 'shift-4' },
    });
    expect(prisma.venue.update).toHaveBeenCalled();
  });

  it('restores shifts and drops assignments for non-members', async () => {
    const prisma: any = {
      profile: {
        findMany: vi.fn().mockResolvedValue([{ id: 'profile-1' }]),
      },
      scheduleShift: {
        findFirst: vi.fn().mockResolvedValue(null),
        findMany: vi.fn().mockResolvedValue([]),
        create: vi
          .fn()
          .mockResolvedValueOnce({ id: 'shift-5' })
          .mockResolvedValueOnce({ id: 'shift-6' }),
      },
      venue: {
        update: vi.fn().mockResolvedValue({}),
      },
      $executeRaw: vi.fn().mockResolvedValue(undefined),
      $transaction: vi.fn(async (callback: any) => callback(prisma)),
    };
    const service = new SchedulingAssignmentService(prisma as any);

    const result = await service.restoreShifts({
      venueId: 'venue-1',
      weekStart: '2026-08-24',
      shifts: [
        {
          dayIndex: 1,
          startMinutes: 480,
          endMinutes: 720,
          jobTitle: 'Server',
          station: 'Patio',
          status: 'scheduled',
          profileId: 'profile-1',
          notes: 'keep',
        },
        {
          dayIndex: 2,
          startMinutes: 720,
          endMinutes: 900,
          jobTitle: 'Host',
          station: 'Front',
          status: 'covered',
          profileId: 'missing-member',
          notes: undefined,
        },
      ],
    });

    expect(result).toEqual({ restored: 2 });
    expect(prisma.profile.findMany).toHaveBeenCalledWith({
      where: {
        id: { in: ['profile-1', 'missing-member'] },
        venueId: 'venue-1',
        OR: [{ membershipStatus: null }, { membershipStatus: 'active' }],
      },
      select: { id: true },
    });
    expect(prisma.scheduleShift.create).toHaveBeenNthCalledWith(1, {
      data: expect.objectContaining({
        venueId: 'venue-1',
        weekStart: '2026-08-24',
        profileId: 'profile-1',
        status: 'scheduled',
      }),
    });
    expect(prisma.scheduleShift.create).toHaveBeenNthCalledWith(2, {
      data: expect.objectContaining({
        venueId: 'venue-1',
        weekStart: '2026-08-24',
        profileId: undefined,
        status: 'open',
      }),
    });
    expect(prisma.$transaction).toHaveBeenCalled();
    expect(prisma.venue.update).toHaveBeenCalled();
  });

  it('copies one day of shifts into target days as open shifts', async () => {
    const prisma: any = {
      scheduleShift: {
        findMany: vi.fn().mockResolvedValue([
          {
            startMinutes: 480,
            endMinutes: 720,
            jobTitle: 'Server',
            station: 'Patio',
          },
          {
            startMinutes: 720,
            endMinutes: 900,
            jobTitle: 'Host',
            station: 'Front',
          },
        ]),
        create: vi
          .fn()
          .mockResolvedValueOnce({ id: 'shift-7' })
          .mockResolvedValueOnce({ id: 'shift-8' })
          .mockResolvedValueOnce({ id: 'shift-9' })
          .mockResolvedValueOnce({ id: 'shift-10' }),
      },
      venue: {
        update: vi.fn().mockResolvedValue({}),
      },
      $executeRaw: vi.fn().mockResolvedValue(undefined),
      $transaction: vi.fn(async (callback: any) => callback(prisma)),
    };
    const service = new SchedulingAssignmentService(prisma as any);

    const result = await service.copyDayShifts({
      venueId: 'venue-1',
      weekStart: '2026-08-24',
      fromDay: 1,
      toDays: [1, 3, 3, 5],
    });

    expect(result).toEqual({ added: 4 });
    expect(prisma.scheduleShift.findMany).toHaveBeenCalledWith({
      where: { venueId: 'venue-1', weekStart: '2026-08-24', dayIndex: 1 },
    });
    expect(prisma.scheduleShift.create).toHaveBeenNthCalledWith(1, {
      data: expect.objectContaining({
        venueId: 'venue-1',
        weekStart: '2026-08-24',
        dayIndex: 3,
        status: 'open',
      }),
    });
    expect(prisma.scheduleShift.create).toHaveBeenNthCalledWith(3, {
      data: expect.objectContaining({
        venueId: 'venue-1',
        weekStart: '2026-08-24',
        dayIndex: 5,
        status: 'open',
      }),
    });
    expect(prisma.$transaction).toHaveBeenCalled();
    expect(prisma.venue.update).toHaveBeenCalled();
  });

  it('clears the week and returns snapshots for restore', async () => {
    const shifts = [
      {
        dayIndex: 1,
        startMinutes: 480,
        endMinutes: 720,
        jobTitle: 'Server',
        station: 'Patio',
        status: 'scheduled',
        profileId: 'profile-1',
        notes: 'opening',
      },
      {
        dayIndex: 2,
        startMinutes: 720,
        endMinutes: 900,
        jobTitle: 'Host',
        station: 'Front',
        status: 'open',
        profileId: null,
        notes: null,
      },
    ];
    const prisma: any = {
      scheduleShift: {
        findMany: vi.fn().mockResolvedValue(shifts),
        deleteMany: vi.fn().mockResolvedValue({ count: 2 }),
      },
      venue: {
        update: vi.fn().mockResolvedValue({}),
      },
      $executeRaw: vi.fn().mockResolvedValue(undefined),
      $transaction: vi.fn(async (callback: any) => callback(prisma)),
    };
    const service = new SchedulingAssignmentService(prisma as any);

    const result = await service.clearWeek({
      venueId: 'venue-1',
      weekStart: '2026-08-24',
    });

    expect(result).toEqual({
      removed: 2,
      shifts,
    });
    expect(prisma.scheduleShift.deleteMany).toHaveBeenCalledWith({
      where: { venueId: 'venue-1', weekStart: '2026-08-24' },
    });
    expect(prisma.venue.update).toHaveBeenCalled();
  });

  it('applies a template by optionally replacing the week and creating open shifts in one batch', async () => {
    const prisma: any = {
      scheduleShift: {
        create: vi.fn(),
        createMany: vi.fn().mockResolvedValue({ count: 2 }),
        deleteMany: vi.fn().mockResolvedValue({ count: 4 }),
      },
      venue: {
        update: vi.fn().mockResolvedValue({}),
      },
      $executeRaw: vi.fn().mockResolvedValue(undefined),
      $transaction: vi.fn(async (callback: any) => callback(prisma)),
    };
    const service = new SchedulingAssignmentService(prisma as any);

    const result = await service.applyTemplate({
      venueId: 'venue-1',
      weekStart: '2026-08-24',
      replace: true,
      slots: [
        {
          dayIndex: 1,
          startMinutes: 480,
          endMinutes: 720,
          jobTitle: 'Server',
          station: 'Patio',
          notes: '  opening  ',
        },
        {
          dayIndex: 2,
          startMinutes: 720,
          endMinutes: 900,
          jobTitle: 'Host',
          station: 'Front',
          notes: null,
        },
      ],
    });

    expect(result).toEqual({ added: 2 });
    // A single createMany batch, not one create() round-trip per slot — a
    // template can carry up to 1000 slots (@ArrayMaxSize) inside one locked
    // transaction (see lockBulkSchedule above).
    expect(prisma.scheduleShift.create).not.toHaveBeenCalled();
    expect(prisma.scheduleShift.createMany).toHaveBeenCalledOnce();
    expect(prisma.scheduleShift.createMany).toHaveBeenCalledWith({
      data: [
        {
          venueId: 'venue-1',
          weekStart: '2026-08-24',
          dayIndex: 1,
          startMinutes: 480,
          endMinutes: 720,
          jobTitle: 'Server',
          station: 'Patio',
          notes: 'opening',
          status: 'open',
        },
        {
          venueId: 'venue-1',
          weekStart: '2026-08-24',
          dayIndex: 2,
          startMinutes: 720,
          endMinutes: 900,
          jobTitle: 'Host',
          station: 'Front',
          notes: null,
          status: 'open',
        },
      ],
    });
    expect(prisma.scheduleShift.deleteMany).toHaveBeenCalledWith({
      where: { venueId: 'venue-1', weekStart: '2026-08-24' },
    });
    expect(prisma.$transaction).toHaveBeenCalled();
    expect(prisma.venue.update).toHaveBeenCalled();
  });

  it('skips the createMany batch entirely for an empty template', async () => {
    const prisma: any = {
      scheduleShift: {
        createMany: vi.fn(),
        deleteMany: vi.fn().mockResolvedValue({ count: 0 }),
      },
      venue: { update: vi.fn().mockResolvedValue({}) },
      $executeRaw: vi.fn().mockResolvedValue(undefined),
      $transaction: vi.fn(async (callback: any) => callback(prisma)),
    };
    const service = new SchedulingAssignmentService(prisma as any);

    const result = await service.applyTemplate({
      venueId: 'venue-1',
      weekStart: '2026-08-24',
      replace: false,
      slots: [],
    });

    expect(result).toEqual({ added: 0 });
    expect(prisma.scheduleShift.createMany).not.toHaveBeenCalled();
  });

  it('proposes a swap after validating requester shift and teammate shift', async () => {
    const requesterShift = {
      id: 'shift-a',
      venueId: 'venue-1',
      profileId: 'profile-a',
      dayIndex: 1,
      startMinutes: 480,
      endMinutes: 720,
    };
    const targetShift = {
      id: 'shift-b',
      venueId: 'venue-1',
      profileId: 'profile-b',
      dayIndex: 2,
      startMinutes: 720,
      endMinutes: 900,
    };
    const target = { id: 'profile-b', venueId: 'venue-1' };
    const swap = { id: 'swap-0' };
    const prisma = {
      scheduleShift: {
        findFirst: vi
          .fn()
          .mockResolvedValueOnce(requesterShift)
          .mockResolvedValueOnce(targetShift),
      },
      profile: {
        findFirst: vi.fn().mockResolvedValue(target),
      },
      shiftSwap: {
        create: vi.fn().mockResolvedValue(swap),
      },
    };
    const service = new SchedulingAssignmentService(prisma as any);

    const result = await service.proposeSwap({
      venueId: 'venue-1',
      requesterProfileId: 'profile-a',
      requesterShiftId: 'shift-a',
      targetProfileId: 'profile-b',
      targetShiftId: 'shift-b',
      note: '  can you trade? ',
    });

    expect(result).toEqual({ swap, requesterShift, target });
    expect(prisma.shiftSwap.create).toHaveBeenCalledWith({
      data: {
        venueId: 'venue-1',
        requesterProfileId: 'profile-a',
        requesterShiftId: 'shift-a',
        targetProfileId: 'profile-b',
        targetShiftId: 'shift-b',
        status: 'proposed',
        note: 'can you trade?',
      },
    });
  });

  it('responds to a proposed swap with an atomic status change', async () => {
    const swap = {
      id: 'swap-respond',
      venueId: 'venue-1',
      status: 'proposed',
      targetProfileId: 'profile-b',
    };
    const prisma = {
      shiftSwap: {
        findFirst: vi.fn().mockResolvedValue(swap),
        updateMany: vi.fn().mockResolvedValue({ count: 1 }),
      },
    };
    const service = new SchedulingAssignmentService(prisma as any);

    const result = await service.respondToSwap({
      venueId: 'venue-1',
      swapId: 'swap-respond',
      profileId: 'profile-b',
      accept: true,
    });

    expect(result).toBe(swap);
    expect(prisma.shiftSwap.updateMany).toHaveBeenCalledWith({
      where: { id: 'swap-respond', status: 'proposed' },
      data: { status: 'accepted' },
    });
  });

  it('approves a swap and updates both shifts under schedule locks', async () => {
    const swap = {
      id: 'swap-1',
      venueId: 'venue-1',
      status: 'accepted',
      requesterProfileId: 'profile-a',
      targetProfileId: 'profile-b',
      requesterShiftId: 'shift-a',
      targetShiftId: 'shift-b',
    };
    const requesterShift = {
      id: 'shift-a',
      venueId: 'venue-1',
      dayIndex: 1,
      startMinutes: 480,
      endMinutes: 720,
    };
    const targetShift = {
      id: 'shift-b',
      venueId: 'venue-1',
      dayIndex: 2,
      startMinutes: 720,
      endMinutes: 900,
    };
    const prisma = {
      shiftSwap: {
        findFirst: vi.fn().mockResolvedValue(swap),
        updateMany: vi.fn().mockResolvedValue({ count: 1 }),
      },
      scheduleShift: {
        findFirst: vi
          .fn()
          .mockResolvedValueOnce(requesterShift)
          .mockResolvedValueOnce(targetShift),
        findMany: vi.fn().mockResolvedValue([]),
        update: vi.fn().mockResolvedValue({}),
      },
      venue: {
        update: vi.fn().mockResolvedValue({}),
      },
      $executeRaw: vi.fn().mockResolvedValue(1),
      $transaction: vi.fn(async (fn: (tx: unknown) => Promise<unknown>) => fn(prisma as unknown)),
    };
    const service = new SchedulingAssignmentService(prisma as any);
    vi.spyOn(service, 'lockAssignmentKeys').mockResolvedValue(undefined);
    vi.spyOn(service, 'assertNoDoubleBookTx').mockResolvedValue(undefined);

    const result = await service.reviewSwap({
      venueId: 'venue-1',
      swapId: 'swap-1',
      approve: true,
    });

    expect(result).toBe(swap);
    expect(prisma.scheduleShift.update).toHaveBeenNthCalledWith(1, {
      where: { id: 'shift-a' },
      data: { profileId: 'profile-b', status: 'scheduled' },
    });
    expect(prisma.scheduleShift.update).toHaveBeenNthCalledWith(2, {
      where: { id: 'shift-b' },
      data: { profileId: 'profile-a', status: 'scheduled' },
    });
    expect(prisma.shiftSwap.updateMany).toHaveBeenCalledWith({
      where: { id: 'swap-1', status: { in: ['accepted', 'proposed'] } },
      data: { status: 'approved' },
    });
    expect(prisma.venue.update).toHaveBeenCalled();
  });

  it('declines a swap instead of applying it when a party no longer has an account', async () => {
    const swap = {
      id: 'swap-orphaned',
      venueId: 'venue-1',
      status: 'accepted',
      requesterProfileId: 'profile-a',
      // The target's profile was deleted (account deletion) after this swap
      // was accepted — ShiftSwap.targetProfileId is now null via SetNull.
      targetProfileId: null,
      requesterShiftId: 'shift-a',
      targetShiftId: 'shift-b',
    };
    const updateMany = vi.fn().mockResolvedValue({ count: 1 });
    const prisma = {
      shiftSwap: {
        findFirst: vi.fn().mockResolvedValue(swap),
        updateMany,
      },
      scheduleShift: { update: vi.fn() },
      venue: { update: vi.fn() },
      $executeRaw: vi.fn().mockResolvedValue(1),
      $transaction: vi.fn(async (fn: (tx: unknown) => Promise<unknown>) => fn(prisma as unknown)),
    };
    const service = new SchedulingAssignmentService(prisma as any);

    await expect(service.reviewSwap({
      venueId: 'venue-1',
      swapId: 'swap-orphaned',
      approve: true,
    })).rejects.toThrow('no longer has an account');

    expect(updateMany).toHaveBeenCalledWith({
      where: { id: 'swap-orphaned', status: { in: ['accepted', 'proposed'] } },
      data: { status: 'declined' },
    });
    expect(prisma.scheduleShift.update).not.toHaveBeenCalled();
  });

  it('denies a swap without touching schedule shifts', async () => {
    const swap = {
      id: 'swap-2',
      venueId: 'venue-1',
      status: 'proposed',
      requesterProfileId: 'profile-a',
      targetProfileId: 'profile-b',
      requesterShiftId: 'shift-a',
      targetShiftId: null,
    };
    const prisma = {
      shiftSwap: {
        findFirst: vi.fn().mockResolvedValue(swap),
        update: vi.fn().mockResolvedValue({}),
      },
      scheduleShift: {
        update: vi.fn().mockResolvedValue({}),
      },
      $executeRaw: vi.fn().mockResolvedValue(1),
      $transaction: vi.fn(async (fn: (tx: unknown) => Promise<unknown>) => fn(prisma as unknown)),
    };
    const service = new SchedulingAssignmentService(prisma as any);

    const result = await service.reviewSwap({
      venueId: 'venue-1',
      swapId: 'swap-2',
      approve: false,
    });

    expect(result).toBe(swap);
    expect(prisma.shiftSwap.update).toHaveBeenCalledWith({
      where: { id: 'swap-2' },
      data: { status: 'denied' },
    });
    expect(prisma.scheduleShift.update).not.toHaveBeenCalled();
  });
});

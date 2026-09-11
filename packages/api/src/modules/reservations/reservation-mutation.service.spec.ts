import { BadRequestException } from '@nestjs/common';
import { describe, expect, it, vi } from 'vitest';
import { ReservationMutationService } from './reservation-mutation.service';

function withTransaction<T extends Record<string, any>>(prisma: T) {
  const transaction = Object.assign(prisma, {
    $executeRaw: prisma.$executeRaw ?? vi.fn().mockResolvedValue(undefined),
  });
  return Object.assign(transaction, {
    $transaction: vi.fn((callback: (tx: any) => unknown) => callback(transaction)),
  });
}

describe('ReservationMutationService', () => {
  it('creates a reservation after normalizing fields', async () => {
    const reservation = {
      id: 'reservation-1',
      status: 'confirmed',
      guestEmail: 'guest@example.com',
    };
    const prisma = withTransaction({
      reservationHold: {
        findFirst: vi.fn().mockResolvedValue(null),
      },
      reservation: {
        create: vi.fn().mockResolvedValue(reservation),
      },
      guest: {
        findFirst: vi.fn().mockResolvedValue({ id: 'guest-9' }),
      },
    });
    const service = new ReservationMutationService(prisma as any);

    const result = await service.saveReservation({
      venueId: 'venue-1',
      guestName: '  Alex Guest ',
      partySize: 4,
      reservationTime: '2026-06-28T19:00:00.000Z',
      notes: '  window seat ',
      specialRequests: '  anniversary ',
      phone: ' 555-1212 ',
      email: ' guest@example.com ',
    });

    expect(result).toEqual({ reservation, previousStatus: null });
    expect(prisma.reservation.create).toHaveBeenCalledWith({
      data: expect.objectContaining({
        venueId: 'venue-1',
        guestName: 'Alex Guest',
        partySize: 4,
        status: 'confirmed',
        source: 'direct',
        notes: 'window seat',
        specialRequests: 'anniversary',
        guestPhone: '555-1212',
        guestEmail: 'guest@example.com',
        durationMinutes: 90,
        // The booking is filed under the recognised guest, not just their name.
        guestId: 'guest-9',
      }),
    });
    expect(prisma.guest.findFirst).toHaveBeenCalledWith(expect.objectContaining({
      where: expect.objectContaining({
        venueId: 'venue-1',
        deletedAt: null,
        OR: [{ email: 'guest@example.com' }, { phone: '5551212' }],
      }),
    }));
  });

  it('persists legacy table numbers as conflict-checked relational assignments', async () => {
    const reservation = {
      id: 'reservation-1',
      venueId: 'venue-1',
      reservationTime: new Date('2026-06-28T19:00:00.000Z'),
      durationMinutes: 90,
      status: 'confirmed',
    };
    const prisma = withTransaction({
      reservationHold: { findFirst: vi.fn().mockResolvedValue(null) },
      reservation: { create: vi.fn().mockResolvedValue(reservation) },
      floorPlan: {
        findFirst: vi.fn().mockResolvedValue({ tables: [{ id: 'table-12', label: '12' }] }),
      },
      tableAssignment: {
        findFirst: vi.fn().mockResolvedValue(null),
        updateMany: vi.fn().mockResolvedValue({ count: 0 }),
        create: vi.fn().mockResolvedValue({}),
      },
    });
    const service = new ReservationMutationService(prisma as any);

    await service.saveReservation({
      venueId: 'venue-1',
      guestName: 'Alex Guest',
      partySize: 4,
      reservationTime: '2026-06-28T19:00:00.000Z',
      tableNumbers: ['12'],
    });

    expect(prisma.tableAssignment.create).toHaveBeenCalledWith({
      data: expect.objectContaining({
        venueId: 'venue-1',
        reservationId: 'reservation-1',
        tableId: 'table-12',
        holdType: 'reserved',
      }),
    });
  });

  it('creates an execution workspace immediately for a private event', async () => {
    const reservation = {
      id: 'reservation-private', venueId: 'venue-1', status: 'confirmed', isPrivateEvent: true,
      eventName: 'Launch Party', guestName: 'Alex Guest', reservationTime: new Date('2026-08-01T18:00:00Z'),
      durationMinutes: 240, setupStyle: 'cocktail', eventSpace: 'Main Room',
    };
    const prisma = withTransaction({
      reservationHold: { findFirst: vi.fn().mockResolvedValue(null) },
      reservation: { create: vi.fn().mockResolvedValue(reservation) },
    });
    const autopilot = { ensureWorkspace: vi.fn().mockResolvedValue({ id: 'workspace-1' }) };
    const service = new ReservationMutationService(prisma as any, autopilot as any);

    await service.saveReservation({
      venueId: 'venue-1', guestName: 'Alex Guest', partySize: 50,
      reservationTime: '2026-08-01T18:00:00Z', durationMinutes: 240,
      isPrivateEvent: true, eventName: 'Launch Party', setupStyle: 'cocktail',
    });

    expect(autopilot.ensureWorkspace).toHaveBeenCalledWith(
      expect.objectContaining({ venueId: 'venue-1', sourceType: 'reservation', sourceId: 'reservation-private', title: 'Launch Party' }),
      prisma,
    );
  });

  it('surfaces workspace failures from the reservation transaction', async () => {
    const reservation = {
      id: 'reservation-private', venueId: 'venue-1', status: 'confirmed', isPrivateEvent: true,
      eventName: 'Launch Party', guestName: 'Alex Guest', reservationTime: new Date('2026-08-01T18:00:00Z'),
      durationMinutes: 240, setupStyle: null, eventSpace: 'Main Room',
    };
    const prisma = withTransaction({
      reservationHold: { findFirst: vi.fn().mockResolvedValue(null) },
      reservation: { create: vi.fn().mockResolvedValue(reservation) },
    });
    const autopilot = { ensureWorkspace: vi.fn().mockRejectedValue(new Error('workspace failed')) };
    const service = new ReservationMutationService(prisma as any, autopilot as any);

    await expect(service.saveReservation({
      venueId: 'venue-1', guestName: 'Alex Guest', partySize: 50,
      reservationTime: '2026-08-01T18:00:00Z', isPrivateEvent: true,
    })).rejects.toThrow('workspace failed');

    expect(prisma.$transaction).toHaveBeenCalledOnce();
    expect(autopilot.ensureWorkspace).toHaveBeenCalledWith(expect.any(Object), prisma);
  });

  it('rejects reservations that overlap a hold', async () => {
    const prisma = withTransaction({
      reservationHold: {
        findFirst: vi.fn().mockResolvedValue({ reason: 'Private event buyout' }),
      },
    });
    const service = new ReservationMutationService(prisma as any);

    await expect(
      service.saveReservation({
        venueId: 'venue-1',
        guestName: 'Alex Guest',
        partySize: 4,
        reservationTime: '2026-06-28T19:00:00.000Z',
      }),
    ).rejects.toThrow('This time conflicts with a hold: Private event buyout');
  });

  it('updates an existing reservation and returns previous status', async () => {
    const existing = { id: 'reservation-2', status: 'requested' };
    const updated = { id: 'reservation-2', status: 'confirmed', guestEmail: 'guest@example.com' };
    const prisma = withTransaction({
      reservationHold: {
        findFirst: vi.fn().mockResolvedValue(null),
      },
      reservation: {
        findFirst: vi.fn().mockResolvedValue(existing),
        update: vi.fn().mockResolvedValue(updated),
      },
    });
    const service = new ReservationMutationService(prisma as any);

    const result = await service.saveReservation({
      venueId: 'venue-1',
      reservationId: 'reservation-2',
      guestName: 'Alex Guest',
      partySize: 4,
      reservationTime: '2026-06-28T19:00:00.000Z',
      status: 'confirmed',
    });

    expect(result).toEqual({ reservation: updated, previousStatus: 'requested' });
  });

  it('rejects reopening a cancelled reservation', async () => {
    // Regression for VW-05: status was a raw cast with no transition check,
    // so a cancelled reservation could be moved straight to seated.
    const existing = { id: 'reservation-3', status: 'cancelled' };
    const prisma = withTransaction({
      reservationHold: { findFirst: vi.fn().mockResolvedValue(null) },
      reservation: {
        findFirst: vi.fn().mockResolvedValue(existing),
        update: vi.fn(),
      },
    });
    const service = new ReservationMutationService(prisma as any);

    await expect(
      service.saveReservation({
        venueId: 'venue-1',
        reservationId: 'reservation-3',
        guestName: 'Alex Guest',
        partySize: 4,
        reservationTime: '2026-06-28T19:00:00.000Z',
        status: 'seated',
      }),
    ).rejects.toThrow('A cancelled reservation cannot be changed to seated.');
    expect(prisma.reservation.update).not.toHaveBeenCalled();
  });

  it('allows a no-op update that leaves status unchanged, even on a closed reservation', async () => {
    const existing = { id: 'reservation-4', status: 'completed' };
    const updated = { id: 'reservation-4', status: 'completed', notes: 'Updated notes' };
    const prisma = withTransaction({
      reservationHold: { findFirst: vi.fn().mockResolvedValue(null) },
      reservation: {
        findFirst: vi.fn().mockResolvedValue(existing),
        update: vi.fn().mockResolvedValue(updated),
      },
    });
    const service = new ReservationMutationService(prisma as any);

    const result = await service.saveReservation({
      venueId: 'venue-1',
      reservationId: 'reservation-4',
      guestName: 'Alex Guest',
      partySize: 4,
      reservationTime: '2026-06-28T19:00:00.000Z',
      status: 'completed',
      notes: 'Updated notes',
    });

    expect(result).toEqual({ reservation: updated, previousStatus: 'completed' });
  });

  it('creates and trims a reservation hold', async () => {
    const created = { id: 'hold-1' };
    const prisma = withTransaction({
      reservationHold: {
        create: vi.fn().mockResolvedValue(created),
        findFirst: vi.fn().mockResolvedValue(null),
      },
      reservation: {
        findMany: vi.fn().mockResolvedValue([]),
      },
    });
    const service = new ReservationMutationService(prisma as any);

    const result = await service.createHold({
      venueId: 'venue-1',
      startsAt: '2026-06-28T18:00:00.000Z',
      endsAt: '2026-06-28T20:00:00.000Z',
      reason: '  Staff training ',
    });

    expect(result).toBe(created);
    expect(prisma.reservationHold.create).toHaveBeenCalledWith({
      data: expect.objectContaining({
        venueId: 'venue-1',
        reason: 'Staff training',
      }),
    });
  });

  it('rejects a hold that overlaps an existing reservation under the shared lock', async () => {
    const prisma = withTransaction({
      reservationHold: { create: vi.fn(), findFirst: vi.fn().mockResolvedValue(null) },
      reservation: {
        findMany: vi.fn().mockResolvedValue([
          { reservationTime: new Date('2026-06-28T19:00:00.000Z'), durationMinutes: 90 },
        ]),
      },
    });
    const service = new ReservationMutationService(prisma as any);

    await expect(
      service.createHold({
        venueId: 'venue-1',
        startsAt: '2026-06-28T20:00:00.000Z',
        endsAt: '2026-06-28T21:00:00.000Z',
        reason: 'Private buyout',
      }),
    ).rejects.toThrow('This hold overlaps an existing reservation');
    expect(prisma.reservationHold.create).not.toHaveBeenCalled();
  });

  it('rejects a hold that overlaps another hold', async () => {
    // Regression for VW-08: previously only checked against reservations.
    const prisma = withTransaction({
      reservationHold: {
        create: vi.fn(),
        findFirst: vi.fn().mockResolvedValue({ id: 'hold-existing' }),
      },
      reservation: {
        findMany: vi.fn().mockResolvedValue([]),
      },
    });
    const service = new ReservationMutationService(prisma as any);

    await expect(
      service.createHold({
        venueId: 'venue-1',
        startsAt: '2026-06-28T20:00:00.000Z',
        endsAt: '2026-06-28T21:00:00.000Z',
        reason: 'Private buyout',
      }),
    ).rejects.toThrow('This hold overlaps another hold already on the calendar.');
    expect(prisma.reservationHold.create).not.toHaveBeenCalled();
  });

  it('rejects deleting a missing hold', async () => {
    const prisma = {
      reservationHold: {
        findFirst: vi.fn().mockResolvedValue(null),
      },
    };
    const service = new ReservationMutationService(prisma as any);

    await expect(service.deleteHold({ venueId: 'venue-1', holdId: 'missing' })).rejects.toThrow(
      BadRequestException,
    );
  });

  describe('cancellation cascades', () => {
    const makePrisma = () => withTransaction({
      reservation: {
        findFirst: vi.fn().mockResolvedValue({ id: 'reservation-1', status: 'seated', tags: ['beo:beo-1'] }),
        update: vi.fn().mockResolvedValue({ id: 'reservation-1' }),
      },
      tableAssignment: {
        findMany: vi.fn().mockResolvedValue([{ tableId: 'table-1' }]),
        updateMany: vi.fn().mockResolvedValue({ count: 1 }),
      },
      tableState: {
        findMany: vi.fn().mockResolvedValue([{ tableId: 'table-1', status: 'seated' }]),
        updateMany: vi.fn().mockResolvedValue({ count: 1 }),
      },
      crmBeo: { updateMany: vi.fn().mockResolvedValue({ count: 1 }) },
      eventExecutionWorkspace: { updateMany: vi.fn().mockResolvedValue({ count: 1 }) },
    });

    it('frees the tables it released instead of leaving them showing occupied', async () => {
      // Releasing a TableAssignment does not move TableState, so without the
      // refresh the floor plan kept an occupied table with nothing to release.
      const prisma = makePrisma();
      // No assignment covers "now" once the holds are released.
      prisma.tableAssignment.findMany
        .mockResolvedValueOnce([{ tableId: 'table-1' }])
        .mockResolvedValue([]);

      await new ReservationMutationService(prisma as any).removeReservation({
        venueId: 'venue-1',
        reservationId: 'reservation-1',
      });

      expect(prisma.tableAssignment.updateMany).toHaveBeenCalledWith(
        expect.objectContaining({ data: expect.objectContaining({ releasedReason: 'cancelled' }) }),
      );
      expect(prisma.tableState.updateMany).toHaveBeenCalledWith(
        expect.objectContaining({
          where: expect.objectContaining({ tableId: 'table-1' }),
          data: expect.objectContaining({ status: 'available' }),
        }),
      );
    });

    it('cancels the BEO the reservation was created for', async () => {
      const prisma = makePrisma();
      prisma.tableAssignment.findMany.mockResolvedValue([]);

      await new ReservationMutationService(prisma as any).removeReservation({
        venueId: 'venue-1',
        reservationId: 'reservation-1',
      });

      expect(prisma.crmBeo.updateMany).toHaveBeenCalledWith(
        expect.objectContaining({
          where: expect.objectContaining({ id: 'beo-1', venueId: 'venue-1' }),
          data: expect.objectContaining({ status: 'cancelled' }),
        }),
      );
    });
  });

});

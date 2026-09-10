import { ForbiddenException } from '@nestjs/common';
import { describe, expect, it, vi } from 'vitest';
import { StaffRequestsController } from './staff-requests.controller';

describe('StaffRequestsController', () => {
  it('scopes a staff member to only their own venue requests', async () => {
    const findMany = vi.fn().mockResolvedValue([]);
    const controller = new StaffRequestsController({ staffRequest: { findMany } } as any, {} as any, {} as any);

    await expect(controller.listStaffRequests({
      venueId: 'venue-1',
      profileId: 'profile-1',
      role: 'staff',
    } as any)).resolves.toEqual([]);

    expect(findMany).toHaveBeenCalledWith(expect.objectContaining({
      where: { venueId: 'venue-1', profileId: 'profile-1' },
    }));
  });

  it('returns no data without venue scope and rejects mutations', async () => {
    const controller = new StaffRequestsController({} as any, {} as any, {} as any);
    await expect(controller.listStaffRequests(undefined)).resolves.toEqual([]);
    await expect(controller.createStaffRequest(undefined, {} as any)).rejects.toBeInstanceOf(ForbiddenException);
  });

  it('opens only the dated shifts covered by an approved unavailable-day request', async () => {
    const now = new Date('2026-08-05T12:00:00.000Z');
    const request = {
      id: 'request-1',
      venueId: 'venue-1',
      profileId: 'profile-1',
      kind: 'time_off',
      status: 'pending',
      title: 'Unavailable',
      details: 'Family event',
      requestedForDate: null,
      requestedShiftId: null,
      requestedRangeStart: '2026-08-04',
      requestedRangeEnd: '2026-08-05',
      availability: null,
      reviewerId: null,
      reviewedAt: null,
      responseNotes: null,
      createdAt: now,
      updatedAt: now,
    };
    const updated = { ...request, status: 'approved', reviewerId: 'manager-1', reviewedAt: now };
    const updateMany = vi.fn().mockResolvedValue({ count: 2 });
    const tx = {
      $executeRaw: vi.fn().mockResolvedValue(1),
      staffRequest: {
        findUnique: vi.fn().mockResolvedValue(request),
        update: vi.fn().mockResolvedValue(updated),
      },
      profile: { findUniqueOrThrow: vi.fn().mockResolvedValue({ id: 'manager-1', fullName: 'Manager' }) },
      scheduleShift: {
        findMany: vi.fn().mockResolvedValue([
          { id: 'before', weekStart: '2026-08-02', dayIndex: 1 },
          { id: 'covered-1', weekStart: '2026-08-02', dayIndex: 2 },
          { id: 'covered-2', weekStart: '2026-08-02', dayIndex: 3 },
          { id: 'after', weekStart: '2026-08-02', dayIndex: 4 },
        ]),
        updateMany,
      },
    };
    const prisma = { $transaction: vi.fn((callback) => callback(tx)) };
    const notifications = { notifyProfile: vi.fn().mockResolvedValue(undefined) };
    const email = { sendToProfile: vi.fn().mockResolvedValue(undefined) };
    const controller = new StaffRequestsController(prisma as any, notifications as any, email as any);

    await controller.reviewStaffRequest({
      venueId: 'venue-1',
      profileId: 'manager-1',
      role: 'manager',
    } as any, 'request-1', { status: 'approved' } as any);

    expect(updateMany).toHaveBeenCalledWith({
      where: { id: { in: ['covered-1', 'covered-2'] } },
      data: { profileId: null, status: 'open' },
    });
  });

  it('opens an overnight shift whose spill overlaps the first unavailable day', async () => {
    const now = new Date('2026-08-24T12:00:00.000Z');
    const request = {
      id: 'request-overnight', venueId: 'venue-1', profileId: 'profile-1',
      kind: 'time_off', status: 'pending', title: 'Unavailable', details: '',
      requestedForDate: '2026-08-24', requestedShiftId: null,
      requestedRangeStart: null, requestedRangeEnd: null, availability: null,
      reviewerId: null, reviewedAt: null, responseNotes: null,
      createdAt: now, updatedAt: now,
    };
    const updateMany = vi.fn().mockResolvedValue({ count: 1 });
    const tx = {
      $executeRaw: vi.fn().mockResolvedValue(1),
      staffRequest: {
        findUnique: vi.fn().mockResolvedValue(request),
        update: vi.fn().mockResolvedValue({ ...request, status: 'approved' }),
      },
      profile: { findUniqueOrThrow: vi.fn().mockResolvedValue({ id: 'manager-1', fullName: 'Manager' }) },
      scheduleShift: {
        findMany: vi.fn().mockResolvedValue([
          { id: 'sat-night', weekStart: '2026-08-23', dayIndex: 0, startMinutes: 1320, endMinutes: 1560 },
        ]),
        updateMany,
      },
    };
    const controller = new StaffRequestsController(
      { $transaction: vi.fn((callback) => callback(tx)) } as any,
      { notifyProfile: vi.fn().mockResolvedValue(undefined) } as any,
      { sendToProfile: vi.fn().mockResolvedValue(undefined) } as any,
    );

    await controller.reviewStaffRequest(
      { venueId: 'venue-1', profileId: 'manager-1', role: 'manager' } as any,
      request.id,
      { status: 'approved' } as any,
    );

    expect(updateMany).toHaveBeenCalledWith({
      where: { id: { in: ['sat-night'] } },
      data: { profileId: null, status: 'open' },
    });
  });

  it('records a manager-approved missing punch without fabricated GPS coordinates', async () => {
    const now = new Date('2026-08-24T12:00:00.000Z');
    const request = {
      id: 'request-correction', venueId: 'venue-1', profileId: 'profile-1',
      kind: 'time_correction', status: 'pending', title: 'Missing punch', details: '',
      requestedForDate: null, requestedShiftId: null, requestedRangeStart: null,
      requestedRangeEnd: null,
      availability: {
        clockInAt: '2026-08-24T14:00:00.000Z',
        clockOutAt: '2026-08-24T22:00:00.000Z',
      },
      reviewerId: null, reviewedAt: null, responseNotes: null,
      createdAt: now, updatedAt: now,
    };
    const create = vi.fn().mockResolvedValue({ id: 'entry-correction' });
    const tx = {
      $executeRaw: vi.fn().mockResolvedValue(1),
      staffRequest: {
        findUnique: vi.fn().mockResolvedValue(request),
        update: vi.fn().mockResolvedValue({ ...request, status: 'approved' }),
      },
      profile: { findUniqueOrThrow: vi.fn().mockResolvedValue({ id: 'manager-1', fullName: 'Manager' }) },
      venue: { findUnique: vi.fn().mockResolvedValue({ timezone: 'UTC' }) },
      // findMany is the same-day punch lookup (no punch that day); findFirst
      // remains the open-entry and overlap checks.
      timeEntry: { findMany: vi.fn().mockResolvedValue([]), findFirst: vi.fn().mockResolvedValue(null), create },
    };
    const controller = new StaffRequestsController(
      { $transaction: vi.fn((callback) => callback(tx)) } as any,
      { notifyProfile: vi.fn().mockResolvedValue(undefined) } as any,
      { sendToProfile: vi.fn().mockResolvedValue(undefined) } as any,
    );

    await controller.reviewStaffRequest(
      { venueId: 'venue-1', profileId: 'manager-1', role: 'manager' } as any,
      request.id,
      { status: 'approved' } as any,
    );

    expect(create).toHaveBeenCalledWith({
      data: expect.objectContaining({
        clockInLat: null, clockInLng: null, clockInAccuracyM: null, clockInMocked: null,
        clockOutLat: null, clockOutLng: null, clockOutAccuracyM: null, clockOutMocked: null,
      }),
    });
  });

  it('rejects approving a correction whose clock-out is not after its clock-in', async () => {
    // Regression for VW-03: submission validates order, but the manager can
    // edit either field again on the approval screen. That path never
    // re-checked order before this fix.
    const now = new Date('2026-08-24T12:00:00.000Z');
    const request = {
      id: 'request-correction', venueId: 'venue-1', profileId: 'profile-1',
      kind: 'time_correction', status: 'pending', title: 'Missing punch', details: '',
      requestedForDate: null, requestedShiftId: null, requestedRangeStart: null,
      requestedRangeEnd: null,
      availability: {
        clockInAt: '2026-08-24T22:00:00.000Z',
        clockOutAt: '2026-08-24T14:00:00.000Z',
      },
      reviewerId: null, reviewedAt: null, responseNotes: null,
      createdAt: now, updatedAt: now,
    };
    const create = vi.fn();
    const tx = {
      $executeRaw: vi.fn().mockResolvedValue(1),
      staffRequest: {
        findUnique: vi.fn().mockResolvedValue(request),
        update: vi.fn(),
      },
      profile: { findUniqueOrThrow: vi.fn().mockResolvedValue({ id: 'manager-1', fullName: 'Manager' }) },
      venue: { findUnique: vi.fn().mockResolvedValue({ timezone: 'UTC' }) },
      // findMany is the same-day punch lookup (no punch that day); findFirst
      // remains the open-entry and overlap checks.
      timeEntry: { findMany: vi.fn().mockResolvedValue([]), findFirst: vi.fn().mockResolvedValue(null), create },
    };
    const controller = new StaffRequestsController(
      { $transaction: vi.fn((callback) => callback(tx)) } as any,
      { notifyProfile: vi.fn().mockResolvedValue(undefined) } as any,
      { sendToProfile: vi.fn().mockResolvedValue(undefined) } as any,
    );

    await expect(controller.reviewStaffRequest(
      { venueId: 'venue-1', profileId: 'manager-1', role: 'manager' } as any,
      request.id,
      { status: 'approved' } as any,
    )).rejects.toThrow('Clock-out time must be after clock-in time.');
    expect(create).not.toHaveBeenCalled();
  });

  it('rejects approving a correction that overlaps another punch already on record', async () => {
    // Regression for VW-03: no database constraint stops two closed punches
    // from overlapping. This transaction-scoped check is the only backstop.
    const now = new Date('2026-08-24T12:00:00.000Z');
    const request = {
      id: 'request-correction', venueId: 'venue-1', profileId: 'profile-1',
      kind: 'time_correction', status: 'pending', title: 'Missing punch', details: '',
      requestedForDate: null, requestedShiftId: null, requestedRangeStart: null,
      requestedRangeEnd: null,
      availability: {
        clockInAt: '2026-08-24T14:00:00.000Z',
        clockOutAt: '2026-08-24T22:00:00.000Z',
      },
      reviewerId: null, reviewedAt: null, responseNotes: null,
      createdAt: now, updatedAt: now,
    };
    const create = vi.fn();
    const tx = {
      $executeRaw: vi.fn().mockResolvedValue(1),
      staffRequest: {
        findUnique: vi.fn().mockResolvedValue(request),
        update: vi.fn(),
      },
      profile: { findUniqueOrThrow: vi.fn().mockResolvedValue({ id: 'manager-1', fullName: 'Manager' }) },
      venue: { findUnique: vi.fn().mockResolvedValue({ timezone: 'UTC' }) },
      timeEntry: {
        // No punch on the day being corrected, so a new entry would be
        // created — but the overlap check finds an existing closed punch.
        findMany: vi.fn().mockResolvedValue([]),
        findFirst: vi.fn().mockResolvedValue({ id: 'entry-existing' }),
        create,
      },
    };
    const controller = new StaffRequestsController(
      { $transaction: vi.fn((callback) => callback(tx)) } as any,
      { notifyProfile: vi.fn().mockResolvedValue(undefined) } as any,
      { sendToProfile: vi.fn().mockResolvedValue(undefined) } as any,
    );

    await expect(controller.reviewStaffRequest(
      { venueId: 'venue-1', profileId: 'manager-1', role: 'manager' } as any,
      request.id,
      { status: 'approved' } as any,
    )).rejects.toThrow('This correction overlaps another punch on record for this employee.');
    expect(create).not.toHaveBeenCalled();
  });

  it('rejects a manager approving their own time correction', async () => {
    const now = new Date('2026-08-24T12:00:00.000Z');
    const request = {
      id: 'request-self', venueId: 'venue-1', profileId: 'manager-1',
      kind: 'time_correction', status: 'pending', title: 'Missing punch', details: '',
      requestedForDate: null, requestedShiftId: null, requestedRangeStart: null,
      requestedRangeEnd: null, availability: {}, reviewerId: null, reviewedAt: null,
      responseNotes: null, createdAt: now, updatedAt: now,
    };
    const tx = {
      $executeRaw: vi.fn().mockResolvedValue(1),
      staffRequest: { findUnique: vi.fn().mockResolvedValue(request), update: vi.fn() },
    };
    const controller = new StaffRequestsController(
      { $transaction: vi.fn((callback) => callback(tx)) } as any,
      { notifyProfile: vi.fn() } as any,
      { sendToProfile: vi.fn() } as any,
    );

    await expect(controller.reviewStaffRequest(
      { venueId: 'venue-1', profileId: 'manager-1', role: 'manager' } as any,
      request.id,
      { status: 'approved' } as any,
    )).rejects.toBeInstanceOf(ForbiddenException);
  });

  it('refuses a correction when several punches share the day it names', async () => {
    // Regression (E04): the day lookup took whichever punch came back first, so
    // an approval could land on a different punch than the request described.
    const create = vi.fn();
    const tx = {
      $executeRaw: vi.fn().mockResolvedValue(undefined),
      staffRequest: {
        findUnique: vi.fn().mockResolvedValue({
          id: 'req-1',
          venueId: 'venue-1',
          profileId: 'staff-1',
          kind: 'time_correction',
          status: 'pending',
          availability: { clockInAt: new Date('2026-09-02T15:00:00Z').getTime(), clockOutAt: new Date('2026-09-02T20:00:00Z').getTime() },
        }),
        update: vi.fn().mockResolvedValue({}),
      },
      profile: { findUniqueOrThrow: vi.fn().mockResolvedValue({ id: 'manager-1', fullName: 'Manager' }) },
      venue: { findUnique: vi.fn().mockResolvedValue({ timezone: 'UTC' }) },
      timeEntry: {
        findMany: vi.fn().mockResolvedValue([{ id: 'entry-a' }, { id: 'entry-b' }]),
        findFirst: vi.fn().mockResolvedValue(null),
        create,
      },
    };
    const controller = new StaffRequestsController(
      { $transaction: vi.fn((callback: any) => callback(tx)) } as any,
      { notifyProfile: vi.fn().mockResolvedValue(undefined) } as any,
      { sendToProfile: vi.fn().mockResolvedValue(undefined) } as any,
    );

    await expect(controller.reviewStaffRequest(
      { venueId: 'venue-1', profileId: 'manager-1', role: 'manager', allAccess: false } as any,
      'req-1',
      { status: 'approved' } as any,
    )).rejects.toThrow('several punches on that day');
    expect(create).not.toHaveBeenCalled();
  });

  it('rejects approving a drop-shift request when the shift no longer matches (already reassigned)', async () => {
    const now = new Date('2026-08-24T12:00:00.000Z');
    const request = {
      id: 'request-drop', venueId: 'venue-1', profileId: 'profile-1',
      kind: 'drop_shift', status: 'pending', title: 'Drop shift', details: '',
      requestedForDate: null, requestedShiftId: 'shift-1', requestedRangeStart: null,
      requestedRangeEnd: null, availability: null,
      reviewerId: null, reviewedAt: null, responseNotes: null,
      createdAt: now, updatedAt: now,
    };
    // The shift no longer has profile-1 assigned (reassigned or dropped
    // already), so the guarded updateMany's where-clause matches 0 rows.
    const updateMany = vi.fn().mockResolvedValue({ count: 0 });
    const tx = {
      $executeRaw: vi.fn().mockResolvedValue(1),
      staffRequest: { findUnique: vi.fn().mockResolvedValue(request) },
      profile: { findUniqueOrThrow: vi.fn().mockResolvedValue({ id: 'manager-1', fullName: 'Manager' }) },
      scheduleShift: { updateMany },
    };
    const controller = new StaffRequestsController(
      { $transaction: vi.fn((callback: any) => callback(tx)) } as any,
      { notifyProfile: vi.fn().mockResolvedValue(undefined) } as any,
      { sendToProfile: vi.fn().mockResolvedValue(undefined) } as any,
    );

    await expect(controller.reviewStaffRequest(
      { venueId: 'venue-1', profileId: 'manager-1', role: 'manager' } as any,
      request.id,
      { status: 'approved' } as any,
    )).rejects.toThrow('no longer matches the request');
  });

  it('rejects approving an add-shift request when the open shift was already claimed', async () => {
    const now = new Date('2026-08-24T12:00:00.000Z');
    const request = {
      id: 'request-add', venueId: 'venue-1', profileId: 'profile-1',
      kind: 'add_shift', status: 'pending', title: 'Add shift', details: '',
      requestedForDate: null, requestedShiftId: 'shift-2', requestedRangeStart: null,
      requestedRangeEnd: null, availability: null,
      reviewerId: null, reviewedAt: null, responseNotes: null,
      createdAt: now, updatedAt: now,
    };
    // The shift is no longer open (profileId: null no longer matches), so
    // the guarded updateMany's where-clause matches 0 rows.
    const updateMany = vi.fn().mockResolvedValue({ count: 0 });
    const tx = {
      $executeRaw: vi.fn().mockResolvedValue(1),
      staffRequest: { findUnique: vi.fn().mockResolvedValue(request) },
      profile: { findUniqueOrThrow: vi.fn().mockResolvedValue({ id: 'manager-1', fullName: 'Manager' }) },
      scheduleShift: { updateMany },
    };
    const controller = new StaffRequestsController(
      { $transaction: vi.fn((callback: any) => callback(tx)) } as any,
      { notifyProfile: vi.fn().mockResolvedValue(undefined) } as any,
      { sendToProfile: vi.fn().mockResolvedValue(undefined) } as any,
    );

    await expect(controller.reviewStaffRequest(
      { venueId: 'venue-1', profileId: 'manager-1', role: 'manager' } as any,
      request.id,
      { status: 'approved' } as any,
    )).rejects.toThrow('no longer open');
  });
});

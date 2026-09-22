import { describe, expect, it, vi } from 'vitest';
import { clockAlertShiftWindow } from '../../common/clock-alerts';
import { todayInZone } from '../../common/pay-period';
import { ClockAlertNotifierService } from './clock-alert-notifier.service';

const VENUE = { id: 'venue-1', timezone: 'UTC' };
const PROFILE = { id: 'profile-1', fullName: 'Ada Lovelace' };

function shift(nowMs: number, startMinutes: number, endMinutes: number, overnight = false) {
  const window = clockAlertShiftWindow('UTC', nowMs);
  return {
    venueId: VENUE.id,
    weekStart: overnight ? window.yesterdayWeekStart : window.weekStart,
    dayIndex: overnight ? window.yesterday : window.today,
    startMinutes,
    endMinutes,
    status: 'assigned',
    jobTitle: 'Server',
    profileId: PROFILE.id,
    profile: PROFILE,
  };
}

function openEntry(nowMs: number, hoursAgo: number, locationAnomaly: string | null = null) {
  return {
    venueId: VENUE.id,
    isOpen: true,
    clockInAt: new Date(nowMs - hoursAgo * 60 * 60 * 1000),
    profileId: PROFILE.id,
    profile: PROFILE,
    locationAnomaly,
  };
}

function harness(shifts: unknown[], entries: unknown[]) {
  const prisma = {
    venue: { findMany: vi.fn().mockResolvedValue([VENUE]) },
    scheduleShift: { findMany: vi.fn().mockResolvedValue(shifts) },
    timeEntry: { findMany: vi.fn().mockResolvedValue(entries) },
    clockAlertDelivery: {
      create: vi.fn().mockResolvedValue({ id: 'claim-1' }),
      deleteMany: vi.fn().mockResolvedValue({ count: 1 }),
    },
  };
  const notifications = { notifyManagers: vi.fn().mockResolvedValue(undefined) };
  const service = new ClockAlertNotifierService(prisma as never, notifications as never);
  return { prisma, notifications, service };
}

describe('ClockAlertNotifierService', () => {
  it('does not push inside the late-clock grace window', async () => {
    const now = Date.UTC(2026, 8, 22, 17, 10);
    const { notifications, service } = harness([shift(now, 17 * 60, 23 * 60)], []);

    await expect(service.run(now)).resolves.toEqual({ sent: 0 });
    expect(notifications.notifyManagers).not.toHaveBeenCalled();
  });

  it('pushes a late clock-in for an overnight shift that is still open', async () => {
    const now = Date.UTC(2026, 8, 22, 0, 30);
    const { notifications, prisma, service } = harness([shift(now, 22 * 60, 2 * 60, true)], []);

    await expect(service.run(now)).resolves.toEqual({ sent: 1 });
    expect(prisma.scheduleShift.findMany).toHaveBeenCalledWith(expect.objectContaining({
      where: expect.objectContaining({
        OR: clockAlertShiftWindow('UTC', now).where,
      }),
    }));
    expect(notifications.notifyManagers).toHaveBeenCalledWith(expect.objectContaining({
      venueId: VENUE.id,
      kind: 'late_clock_in',
      title: 'Late clock-in',
    }));
    expect(prisma.clockAlertDelivery.create).toHaveBeenCalledWith({
      data: {
        venueId: VENUE.id,
        profileId: PROFILE.id,
        kind: 'late_clock_in',
        localDate: todayInZone('UTC', new Date(now)),
      },
    });
  });

  it('pushes a missed clock-out once per venue-local day', async () => {
    const now = Date.UTC(2026, 8, 22, 18, 0);
    const seen = new Set<string>();
    const { notifications, prisma, service } = harness([], [openEntry(now, 11)]);
    prisma.clockAlertDelivery.create.mockImplementation(async ({ data }: { data: { kind: string; localDate: string } }) => {
      const key = `${data.kind}:${data.localDate}`;
      if (seen.has(key)) {
        const error = new Error('unique');
        (error as { code?: string }).code = 'P2002';
        throw error;
      }
      seen.add(key);
      return { id: 'claim-1' };
    });

    await expect(service.run(now)).resolves.toEqual({ sent: 1 });
    await expect(service.run(now)).resolves.toEqual({ sent: 0 });
    expect(notifications.notifyManagers).toHaveBeenCalledTimes(1);
    expect(notifications.notifyManagers).toHaveBeenCalledWith(expect.objectContaining({
      kind: 'missed_clock_out',
      title: 'Missed clock-out',
    }));
  });

  it('does not push a location anomaly', async () => {
    const now = Date.UTC(2026, 8, 22, 18, 0);
    const { notifications, service } = harness([], [openEntry(now, 1, 'repeat')]);

    await expect(service.run(now)).resolves.toEqual({ sent: 0 });
    expect(notifications.notifyManagers).not.toHaveBeenCalled();
  });

  it('releases the claim when the push fails so the next tick can retry', async () => {
    const now = Date.UTC(2026, 8, 22, 18, 0);
    const { notifications, prisma, service } = harness([shift(now, 17 * 60, 23 * 60)], []);
    notifications.notifyManagers.mockRejectedValue(new Error('expo down'));

    await expect(service.run(now)).resolves.toEqual({ sent: 0 });
    expect(prisma.clockAlertDelivery.deleteMany).toHaveBeenCalledWith({
      where: {
        venueId: VENUE.id,
        profileId: PROFILE.id,
        kind: 'late_clock_in',
        localDate: todayInZone('UTC', new Date(now)),
      },
    });
  });
});

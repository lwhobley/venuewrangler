import { Injectable, Logger } from '@nestjs/common';
import { Cron, CronExpression } from '@nestjs/schedule';
import { buildClockAlerts, clockAlertShiftWindow, type ClockAlert } from '../../common/clock-alerts';
import { todayInZone } from '../../common/pay-period';
import { NotificationsService } from '../../notifications/notifications.service';
import { PrismaService } from '../../prisma/prisma.service';
import { runWithoutTenant } from '../../prisma/tenant-context';

const PUSHABLE_KINDS = new Set<ClockAlert['kind']>(['late_clock_in', 'missed_clock_out']);
const VENUE_BATCH = 100;
const ACTIVE_MEMBERSHIP = [{ membershipStatus: null }, { membershipStatus: 'active' as const }];

function isUniqueViolation(error: unknown): boolean {
  return typeof error === 'object' && error !== null && 'code' in error && (error as { code?: string }).code === 'P2002';
}

function groupBy<T>(items: T[], key: (item: T) => string): Map<string, T[]> {
  const grouped = new Map<string, T[]>();
  for (const item of items) {
    const id = key(item);
    const list = grouped.get(id) ?? [];
    list.push(item);
    grouped.set(id, list);
  }
  return grouped;
}

@Injectable()
export class ClockAlertNotifierService {
  private readonly logger = new Logger(ClockAlertNotifierService.name);

  constructor(
    private readonly prisma: PrismaService,
    private readonly notifications: NotificationsService,
  ) {}

  @Cron(CronExpression.EVERY_10_MINUTES)
  async notifyLateAndMissed(): Promise<{ sent: number }> {
    return runWithoutTenant(() => this.run(Date.now()));
  }

  async run(nowMs: number): Promise<{ sent: number }> {
    const venues = await this.prisma.venue.findMany({
      select: { id: true, timezone: true },
    });
    const byZone = new Map<string, Array<{ id: string; timezone: string | null }>>();
    for (const venue of venues) {
      const key = venue.timezone || 'UTC';
      const group = byZone.get(key) ?? [];
      group.push(venue);
      byZone.set(key, group);
    }

    let sent = 0;
    for (const [zone, group] of byZone) {
      const window = clockAlertShiftWindow(zone, nowMs);
      for (let i = 0; i < group.length; i += VENUE_BATCH) {
        const batch = group.slice(i, i + VENUE_BATCH);
        const venueIds = batch.map((venue) => venue.id);
        const [shifts, entries] = await Promise.all([
          this.prisma.scheduleShift.findMany({
            where: { venueId: { in: venueIds }, OR: window.where },
            include: { profile: { select: { id: true, fullName: true } } },
          }),
          this.prisma.timeEntry.findMany({
            where: {
              venueId: { in: venueIds },
              isOpen: true,
              profile: { OR: ACTIVE_MEMBERSHIP },
            },
            include: { profile: { select: { id: true, fullName: true } } },
          }),
        ]);
        const shiftsByVenue = groupBy(shifts, (shift) => shift.venueId);
        const entriesByVenue = groupBy(entries, (entry) => entry.venueId);
        for (const venue of batch) {
          const alerts = buildClockAlerts({
            timezone: venue.timezone,
            nowMs,
            shifts: shiftsByVenue.get(venue.id) ?? [],
            entries: entriesByVenue.get(venue.id) ?? [],
          });
          const localDate = todayInZone(venue.timezone, new Date(nowMs));
          for (const alert of alerts) {
            if (!PUSHABLE_KINDS.has(alert.kind)) continue;
            if (await this.deliver(venue.id, alert, localDate)) sent += 1;
          }
        }
      }
    }
    if (sent > 0) this.logger.log(`Sent ${sent} clock alerts`);
    return { sent };
  }

  private async deliver(venueId: string, alert: ClockAlert, localDate: string): Promise<boolean> {
    try {
      await this.prisma.clockAlertDelivery.create({
        data: {
          venueId,
          profileId: alert.profileId,
          kind: alert.kind,
          localDate,
        },
      });
    } catch (error) {
      if (isUniqueViolation(error)) return false;
      throw error;
    }

    const title = alert.kind === 'late_clock_in' ? 'Late clock-in' : 'Missed clock-out';
    try {
      await this.notifications.notifyManagers({
        venueId,
        kind: alert.kind,
        title,
        body: `${alert.memberName}: ${alert.detail}`,
      });
      return true;
    } catch (error) {
      this.logger.warn(`Clock alert failed for ${alert.profileId}: ${error instanceof Error ? error.message : String(error)}`);
      try {
        await this.prisma.clockAlertDelivery.deleteMany({
          where: { venueId, profileId: alert.profileId, kind: alert.kind, localDate },
        });
      } catch (revertError) {
        this.logger.error(`Failed to revert clock alert claim for ${alert.profileId}: ${revertError instanceof Error ? revertError.message : String(revertError)}`);
      }
      return false;
    }
  }
}

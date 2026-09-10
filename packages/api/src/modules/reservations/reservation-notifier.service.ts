import { Injectable, Logger } from '@nestjs/common';
import { Cron, CronExpression } from '@nestjs/schedule';
import { EmailService } from '../../email/email.service';
import { PrismaService } from '../../prisma/prisma.service';
import { runWithoutTenant } from '../../prisma/tenant-context';

const REMINDER_WINDOW_MIN_HOURS = 20;
const REMINDER_WINDOW_MAX_HOURS = 28;
const REMINDER_BATCH_LIMIT = 200;

function formatBookingTime(time: Date, timeZone: string | null): string {
  return time.toLocaleString('en-US', {
    timeZone: timeZone ?? 'UTC',
    weekday: 'long',
    month: 'long',
    day: 'numeric',
    hour: 'numeric',
    minute: '2-digit',
  });
}

@Injectable()
export class ReservationNotifierService {
  private readonly logger = new Logger(ReservationNotifierService.name);

  constructor(
    private readonly prisma: PrismaService,
    private readonly email: EmailService,
  ) {}

  /** Send a "your reservation is confirmed" email immediately on booking. */
  async sendConfirmation(reservationId: string): Promise<void> {
    // Atomically claim the confirmation slot. If two concurrent calls race,
    // only the one that sees count === 1 proceeds — the other returns early.
    const claimed = await this.prisma.reservation.updateMany({
      where: { id: reservationId, confirmationSentAt: null, deletedAt: null },
      data: { confirmationSentAt: new Date() },
    });
    if (claimed.count === 0) return; // already sent, deleted, or not found

    const reservation = await this.prisma.reservation.findUnique({
      where: { id: reservationId },
      include: { venue: { select: { name: true, timezone: true } } },
    });
    if (!reservation?.guestEmail) return;
    const venueName = reservation.venue.name;
    const when = formatBookingTime(reservation.reservationTime, reservation.venue.timezone);
    const subject = `${venueName} — Reservation confirmed for ${when}`;
    const guestFirstName = reservation.guestName.split(' ')[0] ?? reservation.guestName;
    const text =
      `Hi ${guestFirstName},\n\n` +
      `We're looking forward to seeing you at ${venueName}. Here are your reservation details:\n\n` +
      `Reservation Details\n` +
      `Detail\tInfo\n` +
      `Venue\t${venueName}\n` +
      `Date & Time\t${when}\n` +
      `Party Size\t${reservation.partySize}\n` +
      (reservation.specialRequests ? `Notes\t${reservation.specialRequests}\n` : '') + '\n' +
      `If your plans change, please reply to this email so we can offer the table to another guest.\n\n` +
      `— The Team at ${venueName}`;
    try {
      await this.email.sendOrThrow({
        to: reservation.guestEmail,
        subject,
        text,
      });
    } catch (err) {
      this.logger.warn(`Reservation confirmation failed for ${reservation.id}: ${(err as Error).message}`);
      try {
        await this.prisma.reservation.update({
          where: { id: reservation.id },
          data: { confirmationSentAt: null },
        });
      } catch (revertErr) {
        this.logger.error(`Failed to revert confirmation claim for ${reservation.id}: ${(revertErr as Error).message}`);
      }
    }
  }

  /**
   * Hourly cron: send "see you tomorrow" reminders for bookings 20–28h out
   * that haven't been reminded yet. The window is intentionally wide so a
   * missed run still catches every reservation exactly once.
   */
  @Cron(CronExpression.EVERY_HOUR)
  async sendUpcomingReminders(): Promise<{ sent: number }> {
    // Explicit, not incidental: this cron intentionally scans reservations
    // across every venue in one batch. Nothing binds a tenant context today
    // outside of AuthGuard's per-request enterTenant(), but that is an
    // implicit assumption a scheduler-triggered method should not rely on —
    // if it ever ran inside a bound tenant context, the Prisma extension
    // would silently narrow this query to one venue and every other venue's
    // reminders would stop sending with no error.
    return runWithoutTenant(() => this.runUpcomingReminders());
  }

  private async runUpcomingReminders(): Promise<{ sent: number }> {
    const now = Date.now();
    const minTime = new Date(now + REMINDER_WINDOW_MIN_HOURS * 60 * 60 * 1000);
    const maxTime = new Date(now + REMINDER_WINDOW_MAX_HOURS * 60 * 60 * 1000);
    const candidates = await this.prisma.reservation.findMany({
      where: {
        deletedAt: null,
        reminderSentAt: null,
        status: { in: ['confirmed', 'requested', 'checked_in'] },
        reservationTime: { gte: minTime, lte: maxTime },
        guestEmail: { not: null },
      },
      include: { venue: { select: { name: true, timezone: true } } },
      take: REMINDER_BATCH_LIMIT,
    });
    let sent = 0;
    for (const reservation of candidates) {
      if (!reservation.guestEmail) continue;

      // Atomically claim the slot before sending the email.
      const claimed = await this.prisma.reservation.updateMany({
        where: { id: reservation.id, reminderSentAt: null, deletedAt: null },
        data: { reminderSentAt: new Date() },
      });
      if (claimed.count === 0) continue; // already claimed or deleted

      const venueName = reservation.venue.name;
      const when = formatBookingTime(reservation.reservationTime, reservation.venue.timezone);
      const subject = `${venueName} — Reminder: ${when}`;
      const guestFirstName = reservation.guestName.split(' ')[0] ?? reservation.guestName;
      const text =
        `Hi ${guestFirstName},\n\n` +
        `This is a quick reminder for your upcoming reservation at ${venueName}. We look forward to seeing you!\n\n` +
        `Reservation Details\n` +
        `Detail\tInfo\n` +
        `Venue\t${venueName}\n` +
        `Date & Time\t${when}\n` +
        `Party Size\t${reservation.partySize}\n\n` +
        `If anything has changed, please reply and let us know.\n\n` +
        `— The Team at ${venueName}`;
      try {
        await this.email.sendOrThrow({ to: reservation.guestEmail, subject, text });
        sent += 1;
      } catch (err) {
        this.logger.warn(`Reservation reminder failed for ${reservation.id}: ${(err as Error).message}`);
        try {
          await this.prisma.reservation.update({
            where: { id: reservation.id },
            data: { reminderSentAt: null },
          });
        } catch (revertErr) {
          this.logger.error(`Failed to revert reminder claim for ${reservation.id}: ${(revertErr as Error).message}`);
        }
      }
    }
    if (sent > 0) this.logger.log(`Sent ${sent} reservation reminders`);
    return { sent };
  }

  /**
   * Best-effort: notify the next matching waitlist entry that a table opened.
   * Called when an assignment is released. Picks the longest-waiting entry
   * with partySize ≤ openSeats and an email on file; marks notifiedAt so we
   * don't double-notify on subsequent releases.
   */
  async notifyNextWaitlist(venueId: string, openSeats: number): Promise<void> {
    if (openSeats <= 0) return;
    const entry = await this.prisma.waitlist.findFirst({
      where: {
        venueId,
        status: 'waiting',
        notifiedAt: null,
        partySize: { lte: openSeats },
        guestEmail: { not: null },
      },
      orderBy: { requestedAt: 'asc' },
      include: { venue: { select: { name: true } } },
    });
    if (!entry?.guestEmail) return;

    // Atomically claim the slot before sending the email.
    const claimed = await this.prisma.waitlist.updateMany({
      where: { id: entry.id, notifiedAt: null, status: 'waiting' },
      data: { notifiedAt: new Date(), readyAt: new Date() },
    });
    if (claimed.count === 0) return; // already claimed or status changed

    const venueName = entry.venue.name;
    try {
      await this.email.sendOrThrow({
        to: entry.guestEmail,
        subject: `${venueName} — Your table is ready`,
        text:
          `Hi ${entry.guestName.split(' ')[0] ?? entry.guestName},\n\n` +
          `Good news — a table for ${entry.partySize} just opened up at ${venueName}. Here are the details:\n\n` +
          `Table Details\n` +
          `Detail\tInfo\n` +
          `Venue\t${venueName}\n` +
          `Party Size\t${entry.partySize}\n\n` +
          `Please check in with the host within 10 minutes to claim your table.\n\n` +
          `— The Team at ${venueName}`,
      });
    } catch (err) {
      this.logger.warn(`Waitlist notify failed for ${entry.id}: ${(err as Error).message}`);
      try {
        await this.prisma.waitlist.update({
          where: { id: entry.id },
          data: { notifiedAt: null, readyAt: null },
        });
      } catch (revertErr) {
        this.logger.error(`Failed to revert waitlist claim for ${entry.id}: ${(revertErr as Error).message}`);
      }
    }
  }
}

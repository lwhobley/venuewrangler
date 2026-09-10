import { BadRequestException, ConflictException, Injectable, Optional } from '@nestjs/common';
import { Prisma, ReservationSource, ReservationStatus } from '@prisma/client';
import { PrismaService } from '../../prisma/prisma.service';
import { withSerializableRetry } from '../../common/tx-retry';
import { ExecutionAutopilotService } from '../operations/execution-autopilot.service';
import { refreshTableStates } from '../floor/table-state';

// A completed, no-show, or cancelled reservation is a closed record. Nothing
// here models the full transition graph (requested/confirmed/checked_in/
// seated all remain freely interchangeable, since real flows skip states —
// e.g. a host seating a confirmed walk-in without a separate check-in step)
// — only that a closed reservation cannot become active again. Without this,
// `saveReservation`'s generic upsert accepted `cancelled -> seated` as a
// plain cast with no validation at all.
const TERMINAL_RESERVATION_STATUSES: ReadonlySet<ReservationStatus> = new Set(['completed', 'no_show', 'cancelled']);

function assertReservationTransitionAllowed(from: ReservationStatus, to: ReservationStatus) {
  if (from === to) return;
  if (TERMINAL_RESERVATION_STATUSES.has(from)) {
    throw new BadRequestException(`A ${from} reservation cannot be changed to ${to}.`);
  }
}

@Injectable()
export class ReservationMutationService {
  constructor(
    private readonly prisma: PrismaService,
    @Optional() private readonly autopilot?: ExecutionAutopilotService,
  ) {}

  async saveReservation(args: {
    venueId: string;
    reservationId?: string;
    guestName: string;
    partySize: number;
    reservationTime: string;
    durationMinutes?: number;
    status?: string;
    notes?: string;
    source?: string;
    tags?: string[];
    specialRequests?: string;
    tableIds?: string[];
    tableNumbers?: string[];
    phone?: string;
    email?: string;
    guestCompany?: string;
    occasion?: string;
    isPrivateEvent?: boolean;
    eventName?: string;
    eventStatus?: string;
    eventSpace?: string;
    setupStyle?: string;
    menuNotes?: string;
    beverageNotes?: string;
    billingNotes?: string;
    contractStatus?: string;
    beoStatus?: string;
    estimatedValueCents?: number;
    depositDueCents?: number;
    guestId?: string | null;
  }) {
    const guestName = args.guestName.trim();
    if (!guestName) throw new BadRequestException('Guest name is required');
    if (!args.reservationTime) throw new BadRequestException('Reservation time is required');

    const reservationTime = new Date(args.reservationTime);
    if (isNaN(reservationTime.getTime())) {
      throw new BadRequestException('Invalid reservation time');
    }

    const guestId = await this.resolveGuestId(args.venueId, {
      guestId: args.guestId,
      email: args.email,
      phone: args.phone,
    });

    const data = {
      venueId: args.venueId,
      guestId,
      guestName,
      partySize: args.partySize,
      reservationTime,
      status: (args.status ?? 'confirmed') as ReservationStatus,
      source: (args.source ?? 'direct') as ReservationSource,
      tags: args.tags ?? [],
      notes: args.notes?.trim() ?? null,
      specialRequests: args.specialRequests?.trim() ?? null,
      guestPhone: args.phone?.trim() ?? null,
      guestEmail: args.email?.trim() ?? null,
      guestCompany: args.guestCompany?.trim() ?? null,
      occasion: args.occasion?.trim() ?? null,
      isPrivateEvent: args.isPrivateEvent ?? null,
      eventName: args.eventName?.trim() ?? null,
      eventStatus: args.eventStatus?.trim() ?? null,
      eventSpace: args.eventSpace?.trim() ?? null,
      setupStyle: args.setupStyle?.trim() ?? null,
      menuNotes: args.menuNotes?.trim() ?? null,
      beverageNotes: args.beverageNotes?.trim() ?? null,
      billingNotes: args.billingNotes?.trim() ?? null,
      contractStatus: args.contractStatus?.trim() ?? null,
      beoStatus: args.beoStatus?.trim() ?? null,
      estimatedValueCents: args.estimatedValueCents ?? null,
      depositDueCents: args.depositDueCents ?? null,
      durationMinutes: args.durationMinutes ?? 90,
    };

    return withSerializableRetry(this.prisma, async (transaction) => {
      // Serialize reservation writes with hold creation for this venue. Without
      // the shared lock a hold could be inserted after the conflict query but
      // before this transaction committed.
      await transaction.$executeRaw`SELECT pg_advisory_xact_lock(hashtext(${`reservation-holds:${args.venueId}`}))`;
      await this.assertNoHoldConflict(transaction, args.venueId, reservationTime, data.durationMinutes);
      if (args.reservationId) {
        const existing = await transaction.reservation.findFirst({
          where: { id: args.reservationId, venueId: args.venueId, deletedAt: null },
        });
        if (!existing) throw new BadRequestException('Reservation not found');
        assertReservationTransitionAllowed(existing.status, data.status);

        const updated = await transaction.reservation.update({
          where: { id: existing.id },
          data,
        });
        if (data.status === 'cancelled') {
          const now = new Date();
          // Capture the tables before releasing: releasing an assignment does
          // not move TableState, so without the refresh below the floor plan
          // keeps showing an occupied table with nothing left to release.
          const heldTables = await transaction.tableAssignment.findMany({
            where: { venueId: args.venueId, reservationId: existing.id, releasedAt: null },
            select: { tableId: true },
          });
          await transaction.tableAssignment.updateMany({
            where: { venueId: args.venueId, reservationId: existing.id, releasedAt: null },
            data: { releasedAt: now, releasedReason: 'cancelled' },
          });
          await refreshTableStates(transaction, args.venueId, heldTables.map((t) => t.tableId));
          const beoTag = existing.tags.find((t) => t.startsWith('beo:'));
          if (beoTag) {
            await transaction.crmBeo.updateMany({
              where: { id: beoTag.slice(4), venueId: args.venueId },
              data: { status: 'cancelled', updatedAt: now },
            });
          }
          await transaction.eventExecutionWorkspace.updateMany({
            where: {
              venueId: args.venueId,
              OR: [
                { sourceType: 'reservation', sourceId: existing.id },
                ...(beoTag ? [{ sourceType: 'beo', sourceId: beoTag.slice(4) }] : []),
              ],
            },
            data: { isArchived: true },
          });
        }
        await this.syncTableAssignments(transaction, updated, args.tableIds ?? args.tableNumbers);
        await this.ensureExecutionWorkspace(updated, transaction);
        return { reservation: updated, previousStatus: existing.status };
      }

      const created = await transaction.reservation.create({ data });
      await this.syncTableAssignments(transaction, created, args.tableIds ?? args.tableNumbers);
      await this.ensureExecutionWorkspace(created, transaction);
      return { reservation: created, previousStatus: null };
    });
  }

  async createHold(args: {
    venueId: string;
    startsAt: string;
    endsAt: string;
    reason: string;
  }) {
    const startsAt = new Date(args.startsAt);
    const endsAt = new Date(args.endsAt);
    if (isNaN(startsAt.getTime()) || isNaN(endsAt.getTime())) {
      throw new BadRequestException('Invalid date');
    }
    if (endsAt <= startsAt) throw new BadRequestException('endsAt must be after startsAt');

    const reason = args.reason.trim();
    if (!reason) throw new BadRequestException('reason is required');

    return this.prisma.$transaction(async (transaction) => {
      await transaction.$executeRaw`SELECT pg_advisory_xact_lock(hashtext(${`reservation-holds:${args.venueId}`}))`;
      const candidates = await transaction.reservation.findMany({
        where: {
          venueId: args.venueId,
          deletedAt: null,
          status: { notIn: ['cancelled', 'no_show'] },
          reservationTime: { lt: endsAt },
        },
        select: { reservationTime: true, durationMinutes: true },
      });
      const overlapsReservation = candidates.some(
        (reservation) =>
          reservation.reservationTime.getTime() + reservation.durationMinutes * 60 * 1000 > startsAt.getTime(),
      );
      if (overlapsReservation) {
        throw new BadRequestException('This hold overlaps an existing reservation. Move or cancel the reservation first.');
      }
      // Regression for VW-08: this only ever checked new holds against
      // reservations, never against each other, so two holds could cover
      // the same window.
      const overlappingHold = await transaction.reservationHold.findFirst({
        where: {
          venueId: args.venueId,
          startsAt: { lt: endsAt },
          endsAt: { gt: startsAt },
        },
        select: { id: true },
      });
      if (overlappingHold) {
        throw new BadRequestException('This hold overlaps another hold already on the calendar.');
      }
      return transaction.reservationHold.create({
        data: { venueId: args.venueId, startsAt, endsAt, reason },
      });
    });
  }

  async deleteHold(args: {
    venueId: string;
    holdId: string;
  }) {
    const existing = await this.prisma.reservationHold.findFirst({
      where: { id: args.holdId, venueId: args.venueId },
    });
    if (!existing) throw new BadRequestException('Hold not found');

    await this.prisma.reservationHold.delete({ where: { id: args.holdId } });
  }

  async removeReservation(args: {
    venueId: string;
    reservationId: string;
  }) {
    const reservation = await this.prisma.reservation.findFirst({
      where: { id: args.reservationId, venueId: args.venueId },
    });
    if (!reservation) throw new BadRequestException('Reservation not found');

    const now = new Date();
    await this.prisma.$transaction(async (tx) => {
      await tx.reservation.update({
        where: { id: reservation.id },
        data: { status: 'cancelled', eventStatus: 'cancelled', deletedAt: now },
      });
      const heldTables = await tx.tableAssignment.findMany({
        where: { venueId: args.venueId, reservationId: reservation.id, releasedAt: null },
        select: { tableId: true },
      });
      await tx.tableAssignment.updateMany({
        where: { venueId: args.venueId, reservationId: reservation.id, releasedAt: null },
        data: { releasedAt: now, releasedReason: 'cancelled' },
      });
      await refreshTableStates(tx, args.venueId, heldTables.map((t) => t.tableId));
      const beoTag = reservation.tags.find((t) => t.startsWith('beo:'));
      if (beoTag) {
        await tx.crmBeo.updateMany({
          where: { id: beoTag.slice(4), venueId: args.venueId },
          data: { status: 'cancelled', updatedAt: now },
        });
      }
      await tx.eventExecutionWorkspace.updateMany({
        where: {
          venueId: args.venueId,
          OR: [
            { sourceType: 'reservation', sourceId: reservation.id },
            ...(beoTag ? [{ sourceType: 'beo', sourceId: beoTag.slice(4) }] : []),
          ],
        },
        data: { isArchived: true },
      });
    });
  }

  private async assertNoHoldConflict(
    transaction: Prisma.TransactionClient,
    venueId: string,
    reservationTime: Date,
    durationMinutes: number,
  ) {
    const endTime = new Date(reservationTime.getTime() + durationMinutes * 60 * 1000);
    const hold = await transaction.reservationHold.findFirst({
      where: {
        venueId,
        startsAt: { lt: endTime },
        endsAt: { gt: reservationTime },
      },
      select: { reason: true },
    });
    if (hold) {
      throw new BadRequestException(`This time conflicts with a hold: ${hold.reason}`);
    }
  }

  private async syncTableAssignments(
    transaction: Prisma.TransactionClient,
    reservation: {
      id: string;
      venueId: string;
      reservationTime: Date;
      durationMinutes: number;
      status: string;
    },
    requestedTableRefs: string[] | undefined,
  ) {
    if (requestedTableRefs === undefined) return;

    const refs = [...new Set(requestedTableRefs.map((value) => value.trim()).filter(Boolean))];
    let tableIds: string[] = [];
    if (refs.length > 0 && !['cancelled', 'no_show', 'completed'].includes(reservation.status)) {
      const plan = await transaction.floorPlan.findFirst({
        where: { venueId: reservation.venueId, isActive: true },
        include: {
          tables: {
            where: { OR: [{ id: { in: refs } }, { label: { in: refs } }] },
            select: { id: true, label: true },
          },
        },
      });
      if (!plan) throw new BadRequestException('Create an active floor plan before assigning tables');

      tableIds = refs.map((ref) => {
        const matches = plan.tables.filter((table) => table.id === ref || table.label === ref);
        if (matches.length !== 1) {
          throw new BadRequestException(`Table ${ref} was not found uniquely on the active floor plan`);
        }
        return matches[0].id;
      });
      tableIds = [...new Set(tableIds)];
    }

    const startsAt = reservation.reservationTime;
    const endsAt = new Date(startsAt.getTime() + reservation.durationMinutes * 60_000);
    if (tableIds.length > 0) {
      const conflict = await transaction.tableAssignment.findFirst({
        where: {
          venueId: reservation.venueId,
          tableId: { in: tableIds },
          releasedAt: null,
          startsAt: { lt: endsAt },
          endsAt: { gt: startsAt },
          NOT: { reservationId: reservation.id },
        },
        select: { tableId: true },
      });
      if (conflict) throw new ConflictException(`Table ${conflict.tableId} is already booked for this time window`);
    }

    await transaction.tableAssignment.updateMany({
      where: { venueId: reservation.venueId, reservationId: reservation.id, releasedAt: null },
      data: { releasedAt: new Date(), releasedReason: 'reservation_updated' },
    });
    for (const tableId of tableIds) {
      await transaction.tableAssignment.create({
        data: {
          venueId: reservation.venueId,
          reservationId: reservation.id,
          tableId,
          holdType: 'reserved',
          startsAt,
          endsAt,
        },
      });
    }
  }

  /**
   * A reservation used to store the guest's name, email and phone as loose text
   * and never set guestId, so the booking existed while the guest's own profile
   * still showed no upcoming reservation — the app could recognise a returning
   * guest at the top of the form and then file the booking under nobody.
   *
   * Resolution order: an explicit guestId (verified against this venue, so a
   * client cannot attach a booking to another tenant's guest), then the same
   * email/phone match the autofill endpoint uses to recognise the guest in the
   * first place. Returns null rather than inventing a guest: creating profiles
   * from every walk-in is a separate product decision.
   */
  private async resolveGuestId(
    venueId: string,
    contact: { guestId?: string | null; email?: string; phone?: string },
  ): Promise<string | null> {
    if (contact.guestId) {
      const claimed = await this.prisma.guest.findFirst({
        where: { id: contact.guestId, venueId, deletedAt: null },
        select: { id: true },
      });
      if (claimed) return claimed.id;
      throw new BadRequestException('That guest does not belong to this venue.');
    }

    const email = contact.email?.trim().toLowerCase() || null;
    const phone = contact.phone?.replace(/[^\d+]/g, '') || null;
    if (!email && !phone) return null;

    const match = await this.prisma.guest.findFirst({
      where: {
        venueId,
        deletedAt: null,
        OR: [
          ...(email ? [{ email }] : []),
          ...(phone ? [{ phone }] : []),
        ],
      },
      select: { id: true },
    });
    return match?.id ?? null;
  }

  private async ensureExecutionWorkspace(reservation: {
    id: string;
    venueId: string;
    status: string;
    isPrivateEvent: boolean | null;
    eventName: string | null;
    guestName: string;
    reservationTime: Date;
    durationMinutes: number;
    setupStyle: string | null;
    eventSpace: string | null;
  }, transaction: Prisma.TransactionClient) {
    if (!this.autopilot || !reservation.isPrivateEvent || ['cancelled', 'no_show'].includes(reservation.status)) return;
    await this.autopilot.ensureWorkspace({
      venueId: reservation.venueId,
      sourceType: 'reservation',
      sourceId: reservation.id,
      title: reservation.eventName || reservation.guestName || 'Private event',
      startsAt: reservation.reservationTime,
      endsAt: new Date(reservation.reservationTime.getTime() + reservation.durationMinutes * 60_000),
      setupStyle: reservation.setupStyle || reservation.eventSpace,
    }, transaction);
  }
}

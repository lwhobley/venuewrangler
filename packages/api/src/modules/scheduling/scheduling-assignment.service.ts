import {
  BadRequestException,
  Injectable,
  Logger,
  NotFoundException,
} from '@nestjs/common';
import { Prisma, ShiftStatus } from '@prisma/client';
import { PrismaService } from '../../prisma/prisma.service';
import { withSerializableRetry } from '../../common/tx-retry';
import { addDays, todayInZone, weekStartFor } from '../../common/pay-period';
import { assignmentDayKeys, occupiedSlots, shiftsOverlap, type ShiftWindow } from '../../common/shift-overlap';

@Injectable()
export class SchedulingAssignmentService {
  private readonly logger = new Logger(SchedulingAssignmentService.name);

  constructor(private readonly prisma: PrismaService) {}

  async createShift(args: {
    venueId: string;
    weekStart: string;
    profileId?: string;
    dayIndex: number;
    startMinutes: number;
    endMinutes: number;
    jobTitle: string;
    station: string;
    notes?: string;
  }) {
    if (args.profileId) {
      await this.assertVenueMember(args.venueId, args.profileId);
    }

    return withSerializableRetry(this.prisma, async (tx) => {
      if (args.profileId) {
        await this.lockAssignmentKeys(tx, this.profileLockKeys(args.venueId, args.profileId, args));
        await this.assertNotUnavailable(tx, args.venueId, args.profileId, args);
        await this.assertNoDoubleBookInWeekTx(
          tx,
          args.venueId,
          args.profileId,
          args.weekStart,
          args.dayIndex,
          args.startMinutes,
          args.endMinutes,
        );
      }

      const created = await tx.scheduleShift.create({
        data: {
          venueId: args.venueId,
          profileId: args.profileId,
          weekStart: args.weekStart,
          dayIndex: args.dayIndex,
          startMinutes: args.startMinutes,
          endMinutes: args.endMinutes,
          jobTitle: args.jobTitle.trim() || 'Staff',
          station: args.station.trim() || 'Floor',
          notes: args.notes?.trim() || null,
          status: args.profileId ? 'scheduled' : 'open',
        },
      });
      await tx.venue.update({
        where: { id: args.venueId },
        data: { scheduleUpdatedAfterPublishAt: new Date() },
      });
      return created;
    });
  }

  async updateShift(args: {
    venueId: string;
    shiftId: string;
    dayIndex: number;
    startMinutes: number;
    endMinutes: number;
    jobTitle: string;
    station: string;
    notes?: string;
  }) {
    const shift = await this.getVenueShift(args.venueId, args.shiftId);
    let currentProfileId = shift.profileId;

    await withSerializableRetry(this.prisma, async (tx) => {
      // Re-read inside the transaction: the shift's assignment may have
      // changed (e.g. a concurrent assignShift/reviewSwap) since the initial
      // read above, and the double-book check below must validate against
      // whoever actually holds the shift right now, not a stale snapshot.
      const current = await tx.scheduleShift.findFirst({
        where: { id: shift.id, venueId: args.venueId },
      });
      if (!current) throw new NotFoundException('Shift not found');
      currentProfileId = current.profileId;

      if (current.profileId) {
        await this.lockAssignmentKeys(tx, [
          ...this.profileLockKeys(args.venueId, current.profileId, current),
          ...this.profileLockKeys(args.venueId, current.profileId, {
            weekStart: current.weekStart,
            dayIndex: args.dayIndex,
            startMinutes: args.startMinutes,
            endMinutes: args.endMinutes,
          }),
        ]);
        await this.assertNotUnavailable(tx, args.venueId, current.profileId, {
          weekStart: current.weekStart,
          dayIndex: args.dayIndex,
          startMinutes: args.startMinutes,
          endMinutes: args.endMinutes,
        });
        await this.assertNoDoubleBookInWeekTx(
          tx,
          args.venueId,
          current.profileId,
          current.weekStart,
          args.dayIndex,
          args.startMinutes,
          args.endMinutes,
          current.id,
        );
      }

      await tx.scheduleShift.update({
        where: { id: current.id },
        data: {
          dayIndex: args.dayIndex,
          startMinutes: args.startMinutes,
          endMinutes: args.endMinutes,
          jobTitle: args.jobTitle.trim() || 'Staff',
          station: args.station.trim() || 'Floor',
          notes: args.notes?.trim() || null,
        },
      });
      await tx.venue.update({
        where: { id: args.venueId },
        data: { scheduleUpdatedAfterPublishAt: new Date() },
      });
    });

    // dayIndex/startMinutes/endMinutes/station intentionally reflect the
    // pre-update values (the controller uses them as the "before" side of
    // the edit-notification email diff); profileId reflects the up-to-date
    // assignee so that email goes to whoever actually holds the shift.
    return { ...shift, profileId: currentProfileId };
  }

  async assignShift(args: {
    venueId: string;
    shiftId: string;
    profileId?: string;
  }) {
    const shift = await this.getVenueShift(args.venueId, args.shiftId);

    if (!args.profileId) {
      // This bare update used to run with no lock and no re-check, so a
      // concurrent claim/assign for this exact shift (both of which DO run
      // under withSerializableRetry + an advisory lock below) could commit
      // a new profileId a moment before this unassign silently overwrote it
      // back to open — the claiming staff member would vanish from the
      // shift with no error surfaced to either caller.
      await withSerializableRetry(this.prisma, async (tx) => {
        const current = await tx.scheduleShift.findFirst({
          where: { id: shift.id, venueId: args.venueId },
        });
        if (!current) throw new NotFoundException('Shift not found');
        if (current.profileId) {
          await this.lockAssignmentKeys(tx, this.profileLockKeys(args.venueId, current.profileId, current));
        }
        await tx.scheduleShift.update({
          where: { id: current.id },
          data: { profileId: null, status: 'open' },
        });
        await tx.venue.update({
          where: { id: args.venueId },
          data: { scheduleUpdatedAfterPublishAt: new Date() },
        });
      });
      return { shift, nextProfileId: null };
    }

    const profileId = args.profileId;
    await this.assertVenueMember(args.venueId, profileId);
    await withSerializableRetry(this.prisma, async (tx) => {
      const current = await tx.scheduleShift.findFirst({
        where: { id: shift.id, venueId: args.venueId },
      });
      if (!current) throw new NotFoundException('Shift not found');

      await this.lockAssignmentKeys(tx, this.profileLockKeys(args.venueId, profileId, current));
      await this.assertNotUnavailable(tx, args.venueId, profileId, current);
      await this.assertNoDoubleBookInWeekTx(
        tx,
        args.venueId,
        profileId,
        current.weekStart,
        current.dayIndex,
        current.startMinutes,
        current.endMinutes,
        current.id,
      );
      await tx.scheduleShift.update({
        where: { id: current.id },
        data: { profileId, status: 'scheduled' },
      });
      await tx.venue.update({
        where: { id: args.venueId },
        data: { scheduleUpdatedAfterPublishAt: new Date() },
      });
    });

    return { shift, nextProfileId: args.profileId };
  }

  async deleteShift(args: {
    venueId: string;
    shiftId: string;
  }) {
    const shift = await this.getVenueShift(args.venueId, args.shiftId);
    await this.prisma.scheduleShift.delete({ where: { id: shift.id } });
    await this.markScheduleEdited(args.venueId);
    return shift;
  }

  async restoreShifts(args: {
    venueId: string;
    weekStart: string;
    shifts: Array<{
      dayIndex: number;
      startMinutes: number;
      endMinutes: number;
      jobTitle: string;
      station: string;
      status: ShiftStatus;
      profileId?: string | null;
      notes?: string | null;
    }>;
  }) {
    const referencedIds = Array.from(
      new Set(args.shifts.map((shift) => shift.profileId).filter((id): id is string => Boolean(id))),
    );
    const restored = await withSerializableRetry(this.prisma, async (tx) => {
      await this.lockBulkSchedule(tx, args.venueId, args.weekStart);
      const members = referencedIds.length
        ? await tx.profile.findMany({
            where: {
              id: { in: referencedIds },
              venueId: args.venueId,
              OR: [{ membershipStatus: null }, { membershipStatus: 'active' }],
            },
            select: { id: true },
          })
        : [];
      const memberIds = new Set(members.map((member) => member.id));
      const prepared = args.shifts.map((shift) => ({
        shift,
        profileId: shift.profileId && memberIds.has(shift.profileId) ? shift.profileId : undefined,
      }));
      await this.lockAssignmentKeys(tx, prepared.flatMap(({ shift, profileId }) => profileId
        ? this.profileLockKeys(args.venueId, profileId, { ...shift, weekStart: args.weekStart })
        : []));
      for (const { shift, profileId } of prepared) {
        if (profileId) {
          await this.assertNotUnavailable(tx, args.venueId, profileId, { ...shift, weekStart: args.weekStart });
          await this.assertNoDoubleBookInWeekTx(
            tx, args.venueId, profileId, args.weekStart, shift.dayIndex, shift.startMinutes, shift.endMinutes,
          );
        }
        await tx.scheduleShift.create({
          data: {
            venueId: args.venueId,
            weekStart: args.weekStart,
            profileId,
            dayIndex: shift.dayIndex,
            startMinutes: shift.startMinutes,
            endMinutes: shift.endMinutes,
            jobTitle: shift.jobTitle,
            station: shift.station,
            status: profileId ? shift.status : 'open',
            notes: shift.notes,
          },
        });
      }
      return prepared.length;
    });
    await this.markScheduleEdited(args.venueId);
    return { restored };
  }

  async copyDayShifts(args: {
    venueId: string;
    weekStart: string;
    fromDay: number;
    toDays: number[];
  }) {
    const added = await withSerializableRetry(this.prisma, async (tx) => {
      await this.lockBulkSchedule(tx, args.venueId, args.weekStart);
      const source = await tx.scheduleShift.findMany({
        where: { venueId: args.venueId, weekStart: args.weekStart, dayIndex: args.fromDay },
      });
      let count = 0;
      for (const day of [...new Set(args.toDays)].filter((value) => value !== args.fromDay)) {
        for (const shift of source) {
          await tx.scheduleShift.create({
            data: {
              venueId: args.venueId,
              weekStart: args.weekStart,
              dayIndex: day,
              startMinutes: shift.startMinutes,
              endMinutes: shift.endMinutes,
              jobTitle: shift.jobTitle,
              station: shift.station,
              status: 'open',
            },
          });
          count += 1;
        }
      }
      return count;
    });
    await this.markScheduleEdited(args.venueId);
    return { added };
  }

  async clearWeek(args: {
    venueId: string;
    weekStart: string;
  }) {
    const weekWhere = { venueId: args.venueId, weekStart: args.weekStart };
    const snapshots = await withSerializableRetry(this.prisma, async (tx) => {
      await this.lockBulkSchedule(tx, args.venueId, args.weekStart);
      const shifts = await tx.scheduleShift.findMany({ where: weekWhere });
      await tx.scheduleShift.deleteMany({ where: weekWhere });
      return shifts.map((shift) => ({
        dayIndex: shift.dayIndex,
        startMinutes: shift.startMinutes,
        endMinutes: shift.endMinutes,
        jobTitle: shift.jobTitle,
        station: shift.station,
        status: shift.status,
        profileId: shift.profileId,
        notes: shift.notes,
      }));
    });
    await this.markScheduleEdited(args.venueId);
    return { removed: snapshots.length, shifts: snapshots };
  }

  async applyTemplate(args: {
    venueId: string;
    weekStart: string;
    replace: boolean;
    slots: Array<{
      dayIndex: number;
      startMinutes: number;
      endMinutes: number;
      jobTitle: string;
      station: string;
      notes?: string | null;
    }>;
  }) {
    await withSerializableRetry(this.prisma, async (tx) => {
      await this.lockBulkSchedule(tx, args.venueId, args.weekStart);
      if (args.replace) {
        await tx.scheduleShift.deleteMany({ where: { venueId: args.venueId, weekStart: args.weekStart } });
      }
      // One insert for up to 1000 slots (@ArrayMaxSize on the DTO) instead of
      // one create() round-trip per slot inside this same locked transaction —
      // no created row is read back, so createMany needs no follow-up query.
      if (args.slots.length > 0) {
        await tx.scheduleShift.createMany({
          data: args.slots.map((slot) => ({
            venueId: args.venueId,
            weekStart: args.weekStart,
            dayIndex: slot.dayIndex,
            startMinutes: slot.startMinutes,
            endMinutes: slot.endMinutes,
            jobTitle: slot.jobTitle,
            station: slot.station,
            notes: slot.notes?.trim() || null,
            status: 'open',
          })),
        });
      }
    });
    await this.markScheduleEdited(args.venueId);
    return { added: args.slots.length };
  }

  async proposeSwap(args: {
    venueId: string;
    requesterProfileId: string;
    requesterShiftId: string;
    targetProfileId: string;
    targetShiftId?: string;
    note?: string;
  }) {
    const requesterShift = await this.getVenueShift(args.venueId, args.requesterShiftId);
    if (requesterShift.profileId !== args.requesterProfileId) {
      throw new BadRequestException('That is not your shift');
    }

    const target = await this.assertVenueMember(args.venueId, args.targetProfileId);
    if (target.id === args.requesterProfileId) {
      throw new BadRequestException('Choose a teammate');
    }

    if (args.targetShiftId) {
      const targetShift = await this.getVenueShift(args.venueId, args.targetShiftId);
      if (targetShift.profileId !== target.id) {
        throw new BadRequestException("That is not the teammate's shift");
      }
    }

    const swap = await this.prisma.shiftSwap.create({
      data: {
        venueId: args.venueId,
        requesterProfileId: args.requesterProfileId,
        requesterShiftId: requesterShift.id,
        targetProfileId: target.id,
        targetShiftId: args.targetShiftId,
        status: 'proposed',
        note: args.note?.trim() || null,
      },
    });

    return { swap, requesterShift, target };
  }

  async respondToSwap(args: {
    venueId: string;
    swapId: string;
    profileId: string;
    accept: boolean;
  }) {
    const swap = await this.prisma.shiftSwap.findFirst({
      where: { id: args.swapId, venueId: args.venueId },
    });
    if (!swap || swap.targetProfileId !== args.profileId) {
      throw new BadRequestException('Not authorized');
    }
    if (swap.status !== 'proposed') {
      throw new BadRequestException('This swap is no longer open');
    }

    const responded = await this.prisma.shiftSwap.updateMany({
      where: { id: swap.id, status: 'proposed' },
      data: { status: args.accept ? 'accepted' : 'declined' },
    });
    if (responded.count === 0) {
      throw new BadRequestException('This swap is no longer open');
    }

    return swap;
  }

  async reviewSwap(args: {
    venueId: string;
    swapId: string;
    approve: boolean;
  }) {
    const swap = await this.prisma.shiftSwap.findFirst({
      where: { id: args.swapId, venueId: args.venueId },
    });
    if (!swap) throw new NotFoundException('Swap not found');
    if (!['accepted', 'proposed'].includes(swap.status)) {
      throw new BadRequestException('Swap is not pending');
    }

    if (args.approve) {
      await withSerializableRetry(this.prisma, async (tx) => {
        await tx.$executeRaw`SELECT 1 FROM "ShiftSwap" WHERE "id" = ${swap.id} FOR UPDATE`;
        const currentSwap = await tx.shiftSwap.findFirst({
          where: { id: swap.id, venueId: args.venueId },
        });
        if (!currentSwap || !['accepted', 'proposed'].includes(currentSwap.status)) {
          throw new BadRequestException('Swap is not pending');
        }
        // A party's profile can be gone (see the schema comment on
        // ShiftSwap.requesterProfileId/targetProfileId) if that account was
        // deleted after this swap was proposed/accepted. There is no one to
        // assign the shift to on that side, so the swap cannot be completed —
        // decline it instead of leaving it stuck as pending forever.
        if (!currentSwap.requesterProfileId || !currentSwap.targetProfileId) {
          await tx.shiftSwap.updateMany({
            where: { id: currentSwap.id, status: { in: ['accepted', 'proposed'] } },
            data: { status: 'declined' },
          });
          throw new BadRequestException('One of the parties in this swap no longer has an account. The swap has been declined.');
        }
        const requesterProfileId = currentSwap.requesterProfileId;
        const targetProfileId = currentSwap.targetProfileId;

        const requesterShift = await tx.scheduleShift.findFirst({
          where: { id: currentSwap.requesterShiftId, venueId: args.venueId },
        });
        const targetShift = currentSwap.targetShiftId
          ? await tx.scheduleShift.findFirst({
              where: { id: currentSwap.targetShiftId, venueId: args.venueId },
            })
          : null;
        if (!requesterShift || (currentSwap.targetShiftId && !targetShift)) {
          throw new NotFoundException('Shift not found');
        }

        await this.assertNotUnavailable(tx, args.venueId, targetProfileId, requesterShift);
        if (targetShift) {
          await this.assertNotUnavailable(tx, args.venueId, requesterProfileId, targetShift);
        }

        await this.lockAssignmentKeys(tx, [
          ...this.profileLockKeys(args.venueId, targetProfileId, requesterShift),
          ...(targetShift ? this.profileLockKeys(args.venueId, requesterProfileId, targetShift) : []),
        ]);
        await this.assertNoDoubleBookInWeekTx(
          tx,
          args.venueId,
          targetProfileId,
          requesterShift.weekStart,
          requesterShift.dayIndex,
          requesterShift.startMinutes,
          requesterShift.endMinutes,
          requesterShift.id,
          targetShift?.id,
        );
        if (targetShift) {
          await this.assertNoDoubleBookInWeekTx(
            tx,
            args.venueId,
            requesterProfileId,
            targetShift.weekStart,
            targetShift.dayIndex,
            targetShift.startMinutes,
            targetShift.endMinutes,
            targetShift.id,
            requesterShift.id,
          );
        }
        await tx.scheduleShift.update({
          where: { id: requesterShift.id },
          data: { profileId: targetProfileId, status: 'scheduled' },
        });
        if (targetShift) {
          await tx.scheduleShift.update({
            where: { id: targetShift.id },
            data: { profileId: requesterProfileId, status: 'scheduled' },
          });
        }
        const reviewed = await tx.shiftSwap.updateMany({
          where: { id: currentSwap.id, status: { in: ['accepted', 'proposed'] } },
          data: { status: 'approved' },
        });
        if (reviewed.count === 0) {
          throw new BadRequestException('Swap is no longer pending');
        }
        await tx.venue.update({
          where: { id: args.venueId },
          data: { scheduleUpdatedAfterPublishAt: new Date() },
        });
      });
    } else {
      await withSerializableRetry(this.prisma, async (tx) => {
        await tx.$executeRaw`SELECT 1 FROM "ShiftSwap" WHERE "id" = ${swap.id} FOR UPDATE`;
        const currentSwap = await tx.shiftSwap.findFirst({
          where: { id: swap.id, venueId: args.venueId },
        });
        if (!currentSwap || !['accepted', 'proposed'].includes(currentSwap.status)) {
          throw new BadRequestException('Swap is not pending');
        }
        await tx.shiftSwap.update({
          where: { id: swap.id },
          data: { status: 'denied' },
        });
      });
    }

    return swap;
  }

  async claimOpenShift(args: {
    venueId: string;
    profileId: string;
    shiftId: string;
  }) {
    const shift = await this.getVenueShift(args.venueId, args.shiftId);
    if (shift.profileId || shift.status !== 'open') {
      throw new BadRequestException('This shift is no longer open');
    }

    await withSerializableRetry(this.prisma, async (tx) => {
      const current = await tx.scheduleShift.findFirst({
        where: { id: shift.id, venueId: args.venueId, status: 'open', profileId: null },
      });
      if (!current) throw new BadRequestException('This shift is no longer open');
      await this.lockAssignmentKeys(tx, this.profileLockKeys(args.venueId, args.profileId, current));
      await this.assertNotUnavailable(tx, args.venueId, args.profileId, current);
      await this.assertNoDoubleBookInWeekTx(tx, args.venueId, args.profileId, current.weekStart, current.dayIndex, current.startMinutes, current.endMinutes, current.id);
      await tx.scheduleShift.update({ where: { id: current.id }, data: { profileId: args.profileId, status: 'covered' } });
    });

    await this.markScheduleEdited(args.venueId);
    return shift;
  }

  async applyOpenAssignments(args: {
    venueId: string;
    assignments: Array<{ shiftId: string; profileId: string }>;
    canAssign: (input: {
      shift: {
        id: string;
        venueId: string;
        profileId: string | null;
        dayIndex: number;
        startMinutes: number;
        endMinutes: number;
        jobTitle: string;
        station: string;
        status: string;
      };
      profileId: string;
    }) => boolean | Promise<boolean>;
    // Called only after a shift is durably assigned. canAssign runs before the
    // transaction, which can still reject the write (double-book, no longer
    // open, newly unavailable), so a caller tracking running totals — weekly
    // hours, a labor budget — must accumulate here rather than in canAssign,
    // or a shift that was skipped still spends against the cap.
    onAssigned?: (input: {
      shift: { dayIndex: number; startMinutes: number; endMinutes: number };
      profileId: string;
    }) => void;
  }) {
    let assigned = 0;
    let skipped = 0;
    const assignedShifts: Array<{
      profileId: string;
      shiftId: string;
      dayIndex: number;
      startMinutes: number;
      endMinutes: number;
      jobTitle: string;
      station: string;
    }> = [];

    for (const assignment of args.assignments) {
      const shift = await this.getVenueShift(args.venueId, assignment.shiftId);
      if (shift.profileId || shift.status !== 'open') {
        skipped += 1;
        continue;
      }

      await this.assertVenueMember(args.venueId, assignment.profileId);
      const allowed = await args.canAssign({ shift, profileId: assignment.profileId });
      if (!allowed) {
        skipped += 1;
        continue;
      }

      try {
        await withSerializableRetry(this.prisma, async (tx) => {
          const current = await tx.scheduleShift.findFirst({
            where: { id: shift.id, venueId: args.venueId },
          });
          if (!current || current.profileId || current.status !== 'open') {
            throw new BadRequestException('Shift is no longer open.');
          }
          await this.assertNotUnavailable(tx, args.venueId, assignment.profileId, current);
          await this.lockAssignmentKeys(tx, this.profileLockKeys(args.venueId, assignment.profileId, current));
          await this.assertNoDoubleBookInWeekTx(
            tx,
            args.venueId,
            assignment.profileId,
            current.weekStart,
            current.dayIndex,
            current.startMinutes,
            current.endMinutes,
            current.id,
          );
          await tx.scheduleShift.update({
            where: { id: current.id },
            data: { profileId: assignment.profileId, status: 'scheduled' },
          });
        });
      } catch (error: any) {
        this.logger.warn(`Auto-assign skipped shift ${shift.id}: ${error?.message ?? String(error)}`);
        skipped += 1;
        continue;
      }

      assigned += 1;
      args.onAssigned?.({ shift, profileId: assignment.profileId });
      assignedShifts.push({
        profileId: assignment.profileId,
        shiftId: shift.id,
        dayIndex: shift.dayIndex,
        startMinutes: shift.startMinutes,
        endMinutes: shift.endMinutes,
        jobTitle: shift.jobTitle,
        station: shift.station,
      });
    }

    if (assigned > 0) {
      await this.markScheduleEdited(args.venueId);
    }

    return { assigned, skipped, assignedShifts };
  }

  async assertVenueMember(venueId: string, profileId: string) {
    const member = await this.prisma.profile.findFirst({
      where: {
        id: profileId,
        venueId,
        OR: [{ membershipStatus: null }, { membershipStatus: 'active' }],
      },
    });
    if (!member) throw new BadRequestException('Staff member is not in this venue');
    return member;
  }

  /** Approved time-off/sick-leave requests are the single source of truth for
   * a concrete schedule week. Legacy positive-availability rows are deliberately
   * not consulted. */
  private async assertNotUnavailable(
    db: Prisma.TransactionClient | PrismaService,
    venueId: string,
    profileId: string,
    shift: ShiftWindow,
  ) {
    // Keep lightweight service unit doubles usable; real Prisma clients always
    // expose both delegates below.
    if (!db.venue?.findUnique || !db.staffRequest?.findMany) return;
    const venue = shift.weekStart
      ? null
      : await db.venue.findUnique({ where: { id: venueId }, select: { timezone: true } });
    const weekStart = shift.weekStart ?? weekStartFor(todayInZone(venue?.timezone ?? null));
    const dates = [...new Set(
      occupiedSlots({ ...shift, weekStart }).map((slot) => addDays(slot.weekStart ?? weekStart, slot.dayIndex)),
    )];
    const requests = await db.staffRequest.findMany({
      where: {
        venueId,
        profileId,
        status: 'approved',
        kind: { in: ['time_off', 'sick_leave'] },
        OR: dates.flatMap((date) => [
          { requestedForDate: date },
          { requestedRangeStart: { lte: date }, requestedRangeEnd: { gte: date } },
        ]),
      },
      select: { title: true },
      take: 1,
    });
    if (requests.length > 0) {
      throw new BadRequestException('This employee has an approved unavailable-day request for this shift.');
    }
  }

  async getVenueShift(venueId: string, shiftId: string) {
    const shift = await this.prisma.scheduleShift.findFirst({ where: { id: shiftId, venueId } });
    if (!shift) throw new NotFoundException('Shift not found');
    return shift;
  }

  async assertNoDoubleBook(
    venueId: string,
    profileId: string,
    dayIndex: number,
    startMinutes: number,
    endMinutes: number,
    ...excludeShiftIds: Array<string | undefined>
  ) {
    await this.assertNoDoubleBookTx(
      this.prisma,
      venueId,
      profileId,
      dayIndex,
      startMinutes,
      endMinutes,
      ...excludeShiftIds,
    );
  }

  async assertNoDoubleBookTx(
    tx: Prisma.TransactionClient | PrismaService,
    venueId: string,
    profileId: string,
    dayIndex: number,
    startMinutes: number,
    endMinutes: number,
    ...excludeShiftIds: Array<string | undefined>
  ) {
    await this.assertNoDoubleBookInWeekTx(
      tx,
      venueId,
      profileId,
      undefined,
      dayIndex,
      startMinutes,
      endMinutes,
      ...excludeShiftIds,
    );
  }

  private async assertNoDoubleBookInWeekTx(
    tx: Prisma.TransactionClient | PrismaService,
    venueId: string,
    profileId: string,
    weekStart: string | null | undefined,
    dayIndex: number,
    startMinutes: number,
    endMinutes: number,
    ...excludeShiftIds: Array<string | undefined>
  ) {
    const excluded = excludeShiftIds.filter((id): id is string => Boolean(id));
    const candidate: ShiftWindow = { weekStart, dayIndex, startMinutes, endMinutes };
    const adjacentWeeks = weekStart
      ? { weekStart: { in: [addDays(weekStart, -7), weekStart, addDays(weekStart, 7)] } }
      : {};
    const others = await tx.scheduleShift.findMany({
      where: {
        venueId,
        profileId,
        ...(excluded.length > 0 ? { id: { notIn: excluded } } : {}),
        ...(weekStart ? adjacentWeeks : {}),
      },
      select: { weekStart: true, dayIndex: true, startMinutes: true, endMinutes: true },
    });
    if (others.some((other) => shiftsOverlap(candidate, other))) {
      throw new BadRequestException('This assignment overlaps another shift.');
    }
  }

  private profileLockKeys(
    venueId: string,
    profileId: string,
    shift: ShiftWindow,
  ): Array<{ venueId: string; profileId: string; weekStart?: string; dayIndex: number }> {
    return assignmentDayKeys(shift).map((key) => ({ venueId, profileId, ...key }));
  }

  async lockAssignmentKeys(
    tx: Prisma.TransactionClient,
    keys: Array<{ venueId: string; profileId: string; weekStart?: string; dayIndex: number }>,
  ) {
    const uniqueKeys = Array.from(
      new Set(keys.map((key) => `schedule:${key.venueId}:${key.profileId}:${key.weekStart ?? 'legacy'}:${key.dayIndex}`)),
    ).sort();
    for (const key of uniqueKeys) {
      await tx.$executeRaw`SELECT pg_advisory_xact_lock(hashtext(${key}))`;
    }
  }

  private async lockBulkSchedule(tx: Prisma.TransactionClient, venueId: string, weekStart?: string) {
    const key = `schedule-bulk:${venueId}:${weekStart ?? 'legacy'}`;
    await tx.$executeRaw`SELECT pg_advisory_xact_lock(hashtext(${key}))`;
  }

  markScheduleEdited(venueId: string) {
    return this.prisma.venue.update({
      where: { id: venueId },
      data: { scheduleUpdatedAfterPublishAt: new Date() },
    });
  }
}

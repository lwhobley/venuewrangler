import {
  BadRequestException,
  Body,
  Controller,
  Delete,
  ForbiddenException,
  Get,
  Logger,
  NotFoundException,
  Param,
  Patch,
  Post,
  Query,
} from '@nestjs/common';
import { Prisma, ShiftStatus } from '@prisma/client';
import { Type, plainToInstance } from 'class-transformer';
import {
  IsArray,
  ArrayMaxSize,
  ArrayMinSize,
  IsBoolean,
  IsIn,
  IsInt,
  IsOptional,
  IsString,
  MaxLength,
  ValidateNested,
  Min,
  Max,
  validateSync,
} from 'class-validator';
import { canManageVenue, isAdminRole } from '../../auth/roles';
import { RequireSubscription } from '../../billing/require-subscription.decorator';
import { dayLabel, minutesToTime } from '../../common/mappers';
import { ACTIVE_MEMBERSHIP } from '../../common/membership';
import {
  addDays,
  isIsoDate,
  todayInZone,
  weekStartFor,
} from '../../common/pay-period';
import { occupiedSlots, previousOvernightFilter, shiftsOverlap } from '../../common/shift-overlap';
import { assertWithinSharedRateLimit } from '../../common/rate-limit';
import { withSerializableRetry } from '../../common/tx-retry';
import { zonedDateBounds } from '../../common/venue-time';
import { buildLaborForecast } from './labor-forecast';
import { EmailService } from '../../email/email.service';
import { NotificationsService } from '../../notifications/notifications.service';
import { PrismaService } from '../../prisma/prisma.service';
import { VenueScope } from '../../venue/venue-scope.decorator';
import type { VenueScopedRequest } from '../../venue/venue-scope.interceptor';
import { SchedulingAssignmentService } from './scheduling-assignment.service';
import { AiSchedulerService } from './ai-scheduler.service';
import {
  newShiftsAssignedTemplate,
  openShiftCoveredTemplate,
  schedulePublishedManagerTemplate,
  schedulePublishedStaffTemplate,
  shiftChangedTemplate,
  shiftSwapActionRequiredTemplate,
  shiftSwapDecidedTemplate,
  shiftSwapProposedTemplate,
} from '../../email/templates/scheduling';

type Scope = VenueScopedRequest['venueScope'];

const SHIFT_STATUSES = ['scheduled', 'open', 'covered'];
const SWAP_STATUSES = ['proposed', 'accepted', 'declined', 'approved', 'denied', 'cancelled'];
const AI_SCHEDULE_RATE_LIMIT_MAX = 20;
const AI_SCHEDULE_RATE_LIMIT_WINDOW_MS = 10 * 60 * 1000;

class BlackoutDto {
  @IsString()
  @MaxLength(32)
  startDate!: string;

  @IsString()
  @IsOptional()
  @MaxLength(32)
  endDate?: string;

  @IsString()
  @MaxLength(500)
  reason!: string;
}

class ScheduleMemoryNoteDto {
  @IsString()
  @MaxLength(200)
  title!: string;

  @IsString()
  @MaxLength(2000)
  detail!: string;

  @IsString()
  @IsOptional()
  @MaxLength(32)
  weekStart?: string;
}

class ShiftDto {
  @IsString()
  @IsOptional()
  @MaxLength(32)
  weekStart?: string;

  @IsInt()
  dayIndex!: number;

  @IsInt()
  @Min(0)
  @Max(1439)
  startMinutes!: number;

  @IsInt()
  @Min(0)
  @Max(2880)
  endMinutes!: number;

  @IsString()
  @MaxLength(100)
  jobTitle!: string;

  @IsString()
  @MaxLength(100)
  station!: string;

  @IsString()
  @IsOptional()
  @MaxLength(64)
  profileId?: string;

  @IsString()
  @IsOptional()
  @MaxLength(2000)
  notes?: string;
}

class AssignShiftDto {
  @IsString()
  @IsOptional()
  @MaxLength(64)
  profileId?: string;
}

class LaborBudgetDto {
  @IsInt()
  @Min(0)
  @IsOptional()
  weeklyLaborBudgetHours?: number;
}

class TemplateDto {
  @IsString()
  @MaxLength(100)
  name!: string;

  @IsString()
  @IsOptional()
  @MaxLength(32)
  weekStart?: string;
}

class TemplateShiftDto {
  @IsInt()
  @Min(0)
  @Max(6)
  dayIndex!: number;

  @IsInt()
  @Min(0)
  @Max(1439)
  startMinutes!: number;

  @IsInt()
  @Min(0)
  @Max(2880)
  endMinutes!: number;

  @IsString()
  @MaxLength(100)
  jobTitle!: string;

  @IsString()
  @MaxLength(100)
  station!: string;

  @IsString()
  @IsOptional()
  @MaxLength(2000)
  notes?: string;
}

class ApplyTemplateDto {
  @IsBoolean()
  replace!: boolean;

  @IsString()
  @IsOptional()
  @MaxLength(32)
  weekStart?: string;
}

class CopyDayDto {
  @IsString()
  @IsOptional()
  @MaxLength(32)
  weekStart?: string;

  @IsInt()
  @Min(0)
  @Max(6)
  fromDay!: number;

  @IsArray()
  @ArrayMinSize(1)
  @ArrayMaxSize(6)
  @IsInt({ each: true })
  @Min(0, { each: true })
  @Max(6, { each: true })
  toDays!: number[];
}

class RestoreShiftDto extends ShiftDto {
  @IsString()
  @IsIn(SHIFT_STATUSES)
  status!: ShiftStatus;
}

class RestoreShiftsDto {
  @IsString()
  @IsOptional()
  @MaxLength(32)
  weekStart?: string;

  @IsArray()
  @ArrayMaxSize(1000)
  @ValidateNested({ each: true })
  @Type(() => RestoreShiftDto)
  shifts!: RestoreShiftDto[];
}

class WeekDto {
  @IsString()
  @IsOptional()
  @MaxLength(32)
  weekStart?: string;
}

class AutoScheduleAssignmentDto {
  @IsString()
  @MaxLength(64)
  shiftId!: string;

  @IsString()
  @MaxLength(64)
  profileId!: string;
}

class ApplyAutoScheduleDto {
  @IsString()
  @IsOptional()
  @MaxLength(32)
  weekStartDate?: string;

  @IsArray()
  @ArrayMaxSize(1000)
  @ValidateNested({ each: true })
  @Type(() => AutoScheduleAssignmentDto)
  assignments!: AutoScheduleAssignmentDto[];
}

class AiProposedShiftDto {
  @IsInt()
  @Min(0)
  @Max(6)
  dayIndex!: number;

  @IsInt()
  @Min(0)
  @Max(1439)
  startMinutes!: number;

  @IsInt()
  @Min(0)
  @Max(2880)
  endMinutes!: number;

  @IsString()
  @MaxLength(100)
  jobTitle!: string;

  @IsString()
  @MaxLength(100)
  station!: string;

  @IsString()
  @IsOptional()
  @MaxLength(64)
  profileId?: string;
}

class CommitAiScheduleDto {
  @IsString()
  @IsOptional()
  @MaxLength(32)
  weekStartDate?: string;

  @IsArray()
  @ArrayMaxSize(1000)
  @ValidateNested({ each: true })
  @Type(() => AiProposedShiftDto)
  shifts!: AiProposedShiftDto[];
}

class ProposeSwapDto {
  @IsString()
  @MaxLength(64)
  myShiftId!: string;

  @IsString()
  @MaxLength(64)
  targetProfileId!: string;

  @IsString()
  @IsOptional()
  @MaxLength(64)
  targetShiftId?: string;

  @IsString()
  @IsOptional()
  @MaxLength(2000)
  note?: string;
}

class RespondSwapDto {
  @IsBoolean()
  accept!: boolean;
}

class ReviewSwapDto {
  @IsBoolean()
  approve!: boolean;
}

// The client always submits both times as raw clock minutes in [0, 1439] (an
// HTML time input has no way to say "this is tomorrow"), so an overnight
// shift and a transposed pair of times are submitted in exactly the same
// shape: end < start. There is no signal in the request that distinguishes
// "22:00 to 02:00, crossing midnight" from "22:00 to 21:00, meant to be
// 21:00 to 22:00". A flat 24h cap accepted both, silently turning the second
// case into a 23-hour shift. 16 hours comfortably covers a legitimate double
// shift while rejecting a transposition.
const MAX_SHIFT_MINUTES = 16 * 60;

function ensureValidShiftWindow(dayIndex: number, startMinutes: number, endMinutes: number) {
  if (!Number.isInteger(dayIndex) || dayIndex < 0 || dayIndex > 6) {
    throw new BadRequestException('dayIndex must be between 0 and 6');
  }
  if (!Number.isInteger(startMinutes) || startMinutes < 0 || startMinutes > 1439) {
    throw new BadRequestException('Invalid start time');
  }
  if (!Number.isInteger(endMinutes) || endMinutes < 0 || endMinutes > 2880) {
    throw new BadRequestException('End time must be after start time');
  }
  const normalized = endMinutes < startMinutes && endMinutes <= 1440 ? endMinutes + 1440 : endMinutes;
  if (normalized <= startMinutes) {
    throw new BadRequestException('End time must be after start time');
  }
  if (normalized - startMinutes > MAX_SHIFT_MINUTES) {
    throw new BadRequestException(`A shift cannot exceed ${MAX_SHIFT_MINUTES / 60} hours. Check the start and end times.`);
  }
  return normalized;
}

/**
 * Publish state for one specific week. It used to be a single venue-wide
 * timestamp, so publishing any week marked every week published and the badge
 * the manager read could disagree with the shifts staff were already working
 * from. `lastShiftEditAt` is the newest ScheduleShift.updatedAt in the week —
 * derived rather than tracked, so it cannot fall out of step with the edits it
 * describes.
 */
/**
 * The shape the schedule-change email needs. weekStart is what makes the date
 * correct for a shift outside the current week; it is optional only because a
 * legacy shift can have none, in which case the current week is the best
 * available guess.
 */
type ScheduleEmailShift = {
  weekStart?: string | null;
  dayIndex: number;
  startMinutes: number;
  endMinutes: number;
  station: string;
};

function schedulePublishState(publication: { publishedAt: Date } | null, lastShiftEditAt: Date | null) {
  const publishedAt = publication?.publishedAt.getTime() ?? null;
  const updatedAfterPublishAt =
    publishedAt && lastShiftEditAt && lastShiftEditAt.getTime() > publishedAt ? lastShiftEditAt.getTime() : null;
  return {
    status: !publishedAt ? 'draft' : updatedAfterPublishAt ? 'edited_after_publish' : 'published',
    publishedAt,
    updatedAfterPublishAt,
  };
}

type ShiftWithProfile = {
  id: string;
  dayIndex: number;
  startMinutes: number;
  endMinutes: number;
  jobTitle: string;
  station: string;
  notes: string | null;
  status: ShiftStatus;
  profileId: string | null;
  profile?: { fullName: string } | null;
};

type TemplateShiftSlot = {
  dayIndex: number;
  startMinutes: number;
  endMinutes: number;
  jobTitle: string;
  station: string;
  notes?: string | null;
};

type AvailabilityWindow = { dayIndex: number; startMinutes: number; endMinutes: number; available: boolean };

function availabilityCovers(
  rows: AvailabilityWindow[] | undefined,
  shift: { dayIndex: number; startMinutes: number; endMinutes: number; weekStart?: string | null },
) {
  // Availability is request-driven: no approved unavailable-day request means
  // the employee can be scheduled. Legacy positive rows are ignored.
  const blocked = occupiedSlots(shift).some((slot) => {
    if (shift.weekStart && slot.weekStart && slot.weekStart !== shift.weekStart) return false;
    return (rows ?? []).some((row) =>
      !row.available &&
      row.dayIndex === slot.dayIndex &&
      row.startMinutes < slot.end &&
      row.endMinutes > slot.start,
    );
  });
  return !blocked;
}

@Controller('v1/scheduling')
export class SchedulingController {
  private readonly logger = new Logger(SchedulingController.name);

  constructor(
    private readonly prisma: PrismaService,
    private readonly notifications: NotificationsService,
    private readonly email: EmailService,
    private readonly assignments: SchedulingAssignmentService,
    private readonly aiScheduler: AiSchedulerService,
  ) {}

  @RequireSubscription()
  @Get('blackouts')
  async listBlackouts(
    @VenueScope() scope: Scope,
    @Query('startDate') startDateParam?: string,
    @Query('endDate') endDateParam?: string,
  ) {
    if (!scope) return [];
    const where: Prisma.BlackoutDateWhereInput = { venueId: scope.venueId };
    if (startDateParam && isIsoDate(startDateParam)) {
      where.endDate = { gte: new Date(startDateParam + 'T00:00:00.000Z') };
    }
    if (endDateParam && isIsoDate(endDateParam)) {
      where.startDate = { lte: new Date(endDateParam + 'T23:59:59.999Z') };
    }
    const rows = await this.prisma.blackoutDate.findMany({
      where,
      orderBy: { startDate: 'asc' },
      take: 500,
    });
    return rows.map((row) => ({
      _id: row.id,
      startDate: row.startDate.toISOString().split('T')[0],
      endDate: row.endDate.toISOString().split('T')[0],
      reason: row.reason,
    }));
  }

  @RequireSubscription()
  @Post('blackouts')
  async addBlackout(@VenueScope() scope: Scope, @Body() body: BlackoutDto) {
    this.requireManager(scope);
    const startDate = body.startDate.trim();
    const endDate = body.endDate?.trim() || startDate;
    if (!isIsoDate(startDate) || !isIsoDate(endDate)) {
      throw new BadRequestException('Dates must be in YYYY-MM-DD format');
    }
    if (endDate < startDate) throw new BadRequestException('End date must be on or after the start date');
    const row = await this.prisma.blackoutDate.create({
      data: {
        venueId: scope!.venueId,
        startDate: new Date(startDate),
        endDate: new Date(endDate),
        reason: body.reason.trim() || 'Blackout',
        createdBy: scope!.profileId,
      },
    });
    return row.id;
  }

  @RequireSubscription()
  @Delete('blackouts/:id')
  async removeBlackout(@VenueScope() scope: Scope, @Param('id') id: string) {
    this.requireManager(scope);
    const row = await this.prisma.blackoutDate.findFirst({ where: { id, venueId: scope!.venueId } });
    if (!row) throw new NotFoundException('Blackout not found');
    await this.prisma.blackoutDate.delete({ where: { id: row.id } });
    return { ok: true };
  }

  @RequireSubscription()
  @Get('manager')
  async getManagerSchedule(@VenueScope() scope: Scope, @Query('weekStart') requestedWeekStart?: string) {
    this.requireManager(scope);
    const selectedWeekStart = await this.resolveAvailabilityWeekStart(scope!.venueId, requestedWeekStart);
    const previousWeekStart = addDays(selectedWeekStart, -7);
    const [venue, publication, shifts, carryInShifts, staff] = await Promise.all([
      this.prisma.venue.findUniqueOrThrow({ where: { id: scope!.venueId } }),
      this.prisma.schedulePublication.findUnique({
        where: { venueId_weekStart: { venueId: scope!.venueId, weekStart: selectedWeekStart } },
      }),
      this.prisma.scheduleShift.findMany({
        where: { venueId: scope!.venueId, weekStart: selectedWeekStart },
        include: { profile: true },
        orderBy: [{ dayIndex: 'asc' }, { startMinutes: 'asc' }],
      }),
      this.prisma.scheduleShift.findMany({
        where: {
          venueId: scope!.venueId,
          weekStart: previousWeekStart,
          dayIndex: 6,
          endMinutes: { gt: 1440 },
        },
        include: { profile: true },
        orderBy: { startMinutes: 'asc' },
      }),
      this.prisma.profile.findMany({
        where: { venueId: scope!.venueId, OR: ACTIVE_MEMBERSHIP },
        orderBy: { fullName: 'asc' },
      }),
    ]);
    const approvedUnavailable = await this.unavailableRequests(scope!.venueId, selectedWeekStart);
    const availability = this.unavailableByProfile(approvedUnavailable, selectedWeekStart);
    const availabilityByProfile = availability;
    const selectedAvailabilityWeekByProfile = new Map<string, string>();
    for (const profileId of availability.keys()) {
      selectedAvailabilityWeekByProfile.set(profileId, selectedWeekStart);
    }
    const weeklyMinutes = new Map<string, number>();
    for (const shift of shifts) {
      if (!shift.profileId) continue;
      weeklyMinutes.set(shift.profileId, (weeklyMinutes.get(shift.profileId) ?? 0) + Math.max(0, shift.endMinutes - shift.startMinutes));
    }
    const totalScheduledMinutes = shifts.reduce((sum, shift) => sum + Math.max(0, shift.endMinutes - shift.startMinutes), 0);
    return {
      shifts: shifts.map((shift) => {
        const rows = shift.profileId ? availabilityByProfile.get(shift.profileId) : undefined;
        return this.mapManagerShift(shift, rows && rows.length > 0 ? !availabilityCovers(rows, shift) : false);
      }),
      carryInShifts: carryInShifts.map((shift) => this.mapManagerShift(shift, false)),
      staff: staff.map((member) => {
        const mins = weeklyMinutes.get(member.id) ?? 0;
        return {
          _id: member.id,
          fullName: member.fullName,
          role: member.role,
          jobTitle: member.jobTitle,
          weeklyHours: Math.round((mins / 60) * 10) / 10,
          overtime: mins > 40 * 60,
          availabilityWeekStart: selectedAvailabilityWeekByProfile.get(member.id) ?? null,
          availability: (availabilityByProfile.get(member.id) ?? []).map((row) => ({
            dayIndex: row.dayIndex,
            startMinutes: row.startMinutes,
            endMinutes: row.endMinutes,
            available: row.available,
          })),
        };
      }),
      laborBudgetHours: venue.weeklyLaborBudgetHours ?? null,
      totalScheduledHours: Math.round((totalScheduledMinutes / 60) * 10) / 10,
      weekStart: selectedWeekStart,
      publishState: schedulePublishState(
        publication,
        shifts.reduce<Date | null>((latest, shift) => (!latest || shift.updatedAt > latest ? shift.updatedAt : latest), null),
      ),
    };
  }

  @RequireSubscription()
  @Get('labor-forecast')
  async getLaborForecast(@VenueScope() scope: Scope, @Query('weekStart') requestedWeekStart?: string) {
    this.requireManager(scope);
    const venue = await this.prisma.venue.findUnique({
      where: { id: scope!.venueId },
      select: { timezone: true, weeklyLaborBudgetHours: true },
    });
    const tz = venue?.timezone ?? null;
    const selectedWeekStart = await this.resolveAvailabilityWeekStart(scope!.venueId, requestedWeekStart);
    const now = new Date(zonedDateBounds(tz, selectedWeekStart).start);
    const nextWeekStart = addDays(selectedWeekStart, 7);
    const weekEnd = new Date(zonedDateBounds(tz, nextWeekStart).start);
    const previousSaturday = previousOvernightFilter(selectedWeekStart, 0);
    const [shifts, reservations, venueEvents, profiles] = await Promise.all([
      this.prisma.scheduleShift.findMany({
        where: {
          venueId: scope!.venueId,
          OR: [
            { weekStart: selectedWeekStart },
            { weekStart: previousSaturday.weekStart, dayIndex: previousSaturday.dayIndex, endMinutes: { gt: 1440 } },
            { weekStart: nextWeekStart, dayIndex: 0 },
          ],
        },
      }),
      this.prisma.reservation.findMany({
        where: {
          venueId: scope!.venueId,
          deletedAt: null,
          reservationTime: { gte: now, lt: weekEnd },
          status: { notIn: ['cancelled', 'no_show'] },
        },
        select: { reservationTime: true, partySize: true, isPrivateEvent: true },
      }),
      this.prisma.venueEvent.findMany({
        where: {
          venueId: scope!.venueId,
          startsAt: { gte: now, lt: weekEnd },
        },
        select: { startsAt: true, expectedGuests: true },
      }),
      this.prisma.profile.findMany({
        where: { venueId: scope!.venueId, OR: ACTIVE_MEMBERSHIP },
        select: { id: true, fullName: true },
      }),
    ]);

    const forecast = buildLaborForecast({
      tz,
      now,
      weekStart: selectedWeekStart,
      shifts: shifts.map((s) => ({ weekStart: s.weekStart, dayIndex: s.dayIndex, startMinutes: s.startMinutes, endMinutes: s.endMinutes, profileId: s.profileId })),
      reservations: reservations.map((r) => ({ ts: r.reservationTime.getTime(), partySize: r.partySize, isPrivateEvent: Boolean(r.isPrivateEvent) })),
      events: venueEvents.map((e) => ({ ts: e.startsAt.getTime(), expectedGuests: e.expectedGuests })),
      nameById: new Map(profiles.map((p) => [p.id, p.fullName])),
    });

    // Surface the venue's weekly labor budget here so callers (e.g. the Reports
    // efficiency card) don't have to fetch the full manager schedule for it.
    return { ...forecast, laborBudgetHours: venue?.weeklyLaborBudgetHours ?? null };
  }

  @RequireSubscription()
  @Get('memory')
  async listScheduleMemory(@VenueScope() scope: Scope, @Query('limit') limitRaw?: string) {
    this.requireManager(scope);
    const limit = Math.min(20, Math.max(1, Number(limitRaw) || 8));
    const notes = await this.prisma.scheduleMemoryNote.findMany({
      where: { venueId: scope!.venueId },
      orderBy: [{ createdAt: 'desc' }],
      take: limit,
    });
    return {
      notes: notes.map((note) => ({
        _id: note.id,
        title: note.title,
        detail: note.detail,
        weekStart: note.weekStart,
        createdAt: note.createdAt.getTime(),
      })),
    };
  }

  @RequireSubscription()
  @Post('memory')
  async addScheduleMemoryNote(@VenueScope() scope: Scope, @Body() body: ScheduleMemoryNoteDto) {
    this.requireManager(scope);
    const title = body.title.trim();
    const detail = body.detail.trim();
    if (!title) throw new BadRequestException('Memory title is required');
    if (!detail) throw new BadRequestException('Memory detail is required');
    const venue = await this.prisma.venue.findUnique({
      where: { id: scope!.venueId },
      select: { timezone: true },
    });
    const weekStart = body.weekStart?.trim() || weekStartFor(todayInZone(venue?.timezone ?? null));
    const note = await this.prisma.scheduleMemoryNote.create({
      data: {
        venueId: scope!.venueId,
        weekStart,
        title,
        detail,
        createdByProfileId: scope!.profileId,
      },
    });
    return {
      _id: note.id,
      title: note.title,
      detail: note.detail,
      weekStart: note.weekStart,
      createdAt: note.createdAt.getTime(),
    };
  }

  @RequireSubscription()
  @Post('shifts')
  async createShift(@VenueScope() scope: Scope, @Body() body: ShiftDto) {
    this.requireManager(scope);
    const endMinutes = ensureValidShiftWindow(body.dayIndex, body.startMinutes, body.endMinutes);
    const weekStart = await this.resolveAvailabilityWeekStart(scope!.venueId, body.weekStart);
    const shift = await this.assignments.createShift({
      venueId: scope!.venueId,
      weekStart,
      profileId: body.profileId,
      dayIndex: body.dayIndex,
      startMinutes: body.startMinutes,
      endMinutes,
      jobTitle: body.jobTitle,
      station: body.station,
      notes: body.notes,
    });
    if (body.profileId) {
      await this.notifications.notifyProfile({
        venueId: scope!.venueId,
        profileId: body.profileId,
        kind: 'shift_assigned',
        title: 'New shift assigned',
        body: `${dayLabel(body.dayIndex)} ${minutesToTime(body.startMinutes)}-${minutesToTime(endMinutes)} - ${body.jobTitle}`,
      });
      void this.sendScheduleUpdateEmail(body.profileId, 'Added', undefined, {
        weekStart: shift.weekStart,
        dayIndex: body.dayIndex,
        startMinutes: body.startMinutes,
        endMinutes,
        station: body.station,
      });
    }
    return shift.id;
  }

  @RequireSubscription()
  @Patch('shifts/:id')
  async updateShift(@VenueScope() scope: Scope, @Param('id') id: string, @Body() body: ShiftDto) {
    this.requireManager(scope);
    const endMinutes = ensureValidShiftWindow(body.dayIndex, body.startMinutes, body.endMinutes);
    const shift = await this.assignments.updateShift({
      venueId: scope!.venueId,
      shiftId: id,
      dayIndex: body.dayIndex,
      startMinutes: body.startMinutes,
      endMinutes,
      jobTitle: body.jobTitle,
      station: body.station,
      notes: body.notes,
    });
    if (shift.profileId) {
      void this.sendScheduleUpdateEmail(shift.profileId, 'Edited', {
        weekStart: shift.weekStart,
        dayIndex: shift.dayIndex,
        startMinutes: shift.startMinutes,
        endMinutes: shift.endMinutes,
        station: shift.station,
      }, {
        weekStart: shift.weekStart,
        dayIndex: body.dayIndex,
        startMinutes: body.startMinutes,
        endMinutes,
        station: body.station,
      });
    }
    return { ok: true };
  }

  @RequireSubscription()
  @Patch('shifts/:id/assign')
  async assignShift(@VenueScope() scope: Scope, @Param('id') id: string, @Body() body: AssignShiftDto) {
    this.requireManager(scope);
    const { shift, nextProfileId } = await this.assignments.assignShift({
      venueId: scope!.venueId,
      shiftId: id,
      profileId: body.profileId,
    });
    if (nextProfileId && shift.profileId !== nextProfileId) {
      void this.sendScheduleUpdateEmail(nextProfileId, 'Added', undefined, {
        weekStart: shift.weekStart,
        dayIndex: shift.dayIndex,
        startMinutes: shift.startMinutes,
        endMinutes: shift.endMinutes,
        station: shift.station,
      });
    }
    if (!nextProfileId && shift.profileId) {
      void this.sendScheduleUpdateEmail(shift.profileId, 'Removed', {
        weekStart: shift.weekStart,
        dayIndex: shift.dayIndex,
        startMinutes: shift.startMinutes,
        endMinutes: shift.endMinutes,
        station: shift.station,
      }, undefined);
    }
    if (nextProfileId && shift.profileId && shift.profileId !== nextProfileId) {
      void this.sendScheduleUpdateEmail(shift.profileId, 'Removed', {
        weekStart: shift.weekStart,
        dayIndex: shift.dayIndex,
        startMinutes: shift.startMinutes,
        endMinutes: shift.endMinutes,
        station: shift.station,
      }, undefined);
    }
    return { ok: true };
  }

  @RequireSubscription()
  @Delete('shifts/:id')
  async deleteShift(@VenueScope() scope: Scope, @Param('id') id: string) {
    this.requireManager(scope);
    const shift = await this.assignments.deleteShift({
      venueId: scope!.venueId,
      shiftId: id,
    });
    if (shift.profileId) {
      void this.sendScheduleUpdateEmail(shift.profileId, 'Removed', {
        weekStart: shift.weekStart,
        dayIndex: shift.dayIndex,
        startMinutes: shift.startMinutes,
        endMinutes: shift.endMinutes,
        station: shift.station,
      }, undefined);
    }
    return {
      dayIndex: shift.dayIndex,
      startMinutes: shift.startMinutes,
      endMinutes: shift.endMinutes,
      jobTitle: shift.jobTitle,
      station: shift.station,
      status: shift.status,
      profileId: shift.profileId,
      notes: shift.notes,
    };
  }

  @RequireSubscription()
  @Get('me')
  async getMySchedule(@VenueScope() scope: Scope) {
    if (!scope) return { mine: [], open: [], roster: [] };
    const venue = await this.prisma.venue.findUnique({ where: { id: scope.venueId }, select: { timezone: true } });
    const weekStart = weekStartFor(todayInZone(venue?.timezone ?? null));
    const previousSaturday = previousOvernightFilter(weekStart, 0);
    // Staff see a week only once it is published. Without this the manager
    // could be looking at a draft while their team was already working from it
    // — the two screens disagreed and neither said so.
    const publishedWeeks = await this.prisma.schedulePublication.findMany({
      where: { venueId: scope.venueId, weekStart: { in: [weekStart, previousSaturday.weekStart] } },
      select: { weekStart: true },
    });
    const publishedWeekStarts = new Set(publishedWeeks.map((row) => row.weekStart));
    if (!publishedWeekStarts.has(weekStart) && !publishedWeekStarts.has(previousSaturday.weekStart)) {
      return { mine: [], open: [], roster: [], publishState: { status: 'draft' as const, weekStart } };
    }
    const shifts = await this.prisma.scheduleShift.findMany({
      where: {
        venueId: scope.venueId,
        OR: [
          ...(publishedWeekStarts.has(weekStart) ? [{ weekStart }] : []),
          ...(publishedWeekStarts.has(previousSaturday.weekStart)
            ? [{ weekStart: previousSaturday.weekStart, dayIndex: previousSaturday.dayIndex, endMinutes: { gt: 1440 } }]
            : []),
        ],
      },
      include: { profile: true },
      orderBy: [{ dayIndex: 'asc' }, { startMinutes: 'asc' }],
    });
    const unavailableByProfile = this.unavailableByProfile(
      await this.unavailableRequests(scope.venueId, weekStart),
      weekStart,
    );
    const occupiesDay = (shift: { weekStart: string | null; dayIndex: number; startMinutes: number; endMinutes: number }, dayIndex: number) =>
      occupiedSlots({ ...shift, weekStart: shift.weekStart ?? weekStart }).some(
        (slot) => (slot.weekStart ?? weekStart) === weekStart && slot.dayIndex === dayIndex,
      );
    const mine = shifts.filter((shift) => shift.profileId === scope.profileId);
    const open = shifts.filter((shift) => shift.status === 'open' && !shift.profileId && (shift.weekStart ?? weekStart) === weekStart);
    const roster = [0, 1, 2, 3, 4, 5, 6].map((dayIndex) => ({
      dayIndex,
      dayLabel: dayLabel(dayIndex),
      coworkers: shifts
        .filter((shift) => occupiesDay(shift, dayIndex) && shift.profileId && shift.profileId !== scope.profileId)
        .map((shift) => ({
          shiftId: shift.id,
          profileId: shift.profileId,
          name: shift.profile?.fullName ?? 'Teammate',
          memberName: shift.profile?.fullName ?? 'Teammate',
          jobTitle: shift.jobTitle,
          station: shift.station,
          dayIndex: shift.dayIndex,
          startMinutes: shift.startMinutes,
          endMinutes: shift.endMinutes,
          startTime: minutesToTime(shift.startMinutes),
          endTime: minutesToTime(shift.endMinutes),
          withMe: mine.some((myShift) => shiftsOverlap(myShift, shift)),
        })),
    }));
    return {
      mine: mine.map((shift) => this.mapEmployeeShift(shift, true, !availabilityCovers(unavailableByProfile.get(scope.profileId), shift))),
      open: open.map((shift) => this.mapEmployeeShift(shift, false, false)),
      roster,
      publishState: { status: 'published' as const, weekStart },
    };
  }

  @RequireSubscription()
  @Post('shifts/:id/claim')
  async claimOpenShift(@VenueScope() scope: Scope, @Param('id') id: string) {
    if (!scope) throw new ForbiddenException('Profile does not belong to a venue');
    const shift = await this.assignments.claimOpenShift({
      venueId: scope.venueId,
      profileId: scope.profileId,
      shiftId: id,
    });
    await this.notifications.notifyManagers({
      venueId: scope.venueId,
      kind: 'shift_assigned',
      title: 'Open shift covered',
      body: `${scope.fullName} picked up ${dayLabel(shift.dayIndex)} ${minutesToTime(shift.startMinutes)}-${minutesToTime(shift.endMinutes)}.`,
    });
    void this.email.sendToVenueManagers(
      scope.venueId,
      openShiftCoveredTemplate({ pickedUpBy: scope.fullName, shiftLabel: this.shiftLabel(shift), jobTitle: shift.jobTitle, station: shift.station }),
    );
    return { ok: true };
  }

  @RequireSubscription()
  @Post('publish')
  async publishSchedule(@VenueScope() scope: Scope, @Body() body: WeekDto) {
    this.requireManager(scope);
    const selectedWeekStart = await this.resolveAvailabilityWeekStart(scope!.venueId, body.weekStart);
    const shifts = await this.prisma.scheduleShift.findMany({ where: { venueId: scope!.venueId, weekStart: selectedWeekStart } });
    const assigned = shifts.filter((shift) => shift.profileId).length;
    const open = shifts.filter((shift) => shift.status === 'open').length;
    const publishedAt = new Date();
    // Per week, so publishing next week no longer implies this one. The
    // venue-level markers are kept in step for anything still reading them.
    await this.prisma.schedulePublication.upsert({
      where: { venueId_weekStart: { venueId: scope!.venueId, weekStart: selectedWeekStart } },
      create: {
        venueId: scope!.venueId,
        weekStart: selectedWeekStart,
        publishedAt,
        publishedById: scope!.profileId,
      },
      update: { publishedAt, publishedById: scope!.profileId },
    });
    await this.prisma.venue.update({
      where: { id: scope!.venueId },
      data: {
        schedulePublishedAt: publishedAt,
        schedulePublishedById: scope!.profileId,
        scheduleUpdatedAfterPublishAt: null,
      },
    });
    await this.notifications.notifyStaff({
      venueId: scope!.venueId,
      kind: 'schedule_published',
      title: 'Schedule posted',
      body: `${assigned} shift${assigned === 1 ? '' : 's'} scheduled${open > 0 ? `, ${open} open to pick up` : ''}.`,
    });
    const venue = await this.prisma.venue.findUnique({
      where: { id: scope!.venueId },
      select: { timezone: true, name: true },
    });
    const tz = venue?.timezone ?? null;
    const sunday = selectedWeekStart;
    const saturday = addDays(sunday, 6);

    const formatDateMD = (dateStr: string) => {
      const [y, m, d] = dateStr.split('-');
      return `${m}/${d}`;
    };

    const formatDateMDY = (dateStr: string) => {
      const [y, m, d] = dateStr.split('-');
      return `${m}/${d}/${y}`;
    };
    const weekLabel = `${formatDateMD(sunday)} - ${formatDateMD(saturday)}`;
    const periodLabel = `${formatDateMDY(sunday)} - ${formatDateMDY(saturday)}`;

    const totalShifts = shifts.length;
    const staffScheduled = new Set(shifts.map((s) => s.profileId).filter(Boolean)).size;
    const openShifts = shifts.filter((s) => s.status === 'open').length;
    const pendingApprovals = await this.prisma.shiftSwap.count({
      where: { venueId: scope!.venueId, status: { in: ['proposed', 'accepted'] } },
    });

    // Email 1: Send to the publishing manager
    void this.email.sendToProfile(
      scope!.profileId,
      schedulePublishedManagerTemplate({ fullName: scope!.fullName, periodLabel, totalShifts, staffScheduled, openShifts, pendingApprovals }),
    );

    // Email 2: Send to all assigned staff members
    const assignedProfiles = await this.prisma.profile.findMany({
      where: {
        venueId: scope!.venueId,
        id: { in: shifts.map((s) => s.profileId).filter(Boolean) as string[] },
      },
    });

    for (const staff of assignedProfiles) {
      const staffShifts = shifts.filter((s) => s.profileId === staff.id);
      const staffShiftRows = staffShifts.map((s) => ({
        day: dayLabel(s.dayIndex),
        date: formatDateMD(addDays(sunday, s.dayIndex)),
        start: minutesToTime(s.startMinutes),
        end: minutesToTime(s.endMinutes),
        area: s.station || 'Floor',
      }));

      void this.email.sendToProfile(
        staff.id,
        schedulePublishedStaffTemplate({ fullName: staff.fullName, periodLabel: `Week of ${weekLabel}`, shifts: staffShiftRows }),
      );
    }
    return { notified: assigned };
  }

  @RequireSubscription()
  @Patch('labor-budget')
  async setLaborBudget(@VenueScope() scope: Scope, @Body() body: LaborBudgetDto) {
    this.requireManager(scope);
    if (body.weeklyLaborBudgetHours !== undefined && body.weeklyLaborBudgetHours < 0) {
      throw new BadRequestException('Weekly labor budget cannot be negative.');
    }
    await this.prisma.venue.update({
      where: { id: scope!.venueId },
      data: { weeklyLaborBudgetHours: body.weeklyLaborBudgetHours ?? null },
    });
    return { ok: true };
  }

  @RequireSubscription()
  @Get('templates')
  async listScheduleTemplates(@VenueScope() scope: Scope) {
    this.requireManager(scope);
    const rows = await this.prisma.scheduleTemplate.findMany({
      where: { venueId: scope!.venueId },
      orderBy: { createdAt: 'desc' },
    });
    return rows.map((row) => ({
      _id: row.id,
      name: row.name,
      shiftCount: Array.isArray(row.shifts) ? row.shifts.length : 0,
      createdAt: row.createdAt.getTime(),
    }));
  }

  @RequireSubscription()
  @Post('templates')
  async saveScheduleTemplate(@VenueScope() scope: Scope, @Body() body: TemplateDto) {
    this.requireManager(scope);
    const name = body.name.trim();
    if (!name) throw new BadRequestException('Enter a template name');
    const weekStart = await this.resolveAvailabilityWeekStart(scope!.venueId, body.weekStart);
    const shifts = await this.prisma.scheduleShift.findMany({ where: { venueId: scope!.venueId, weekStart } });
    if (shifts.length === 0) throw new BadRequestException('Create at least one shift before saving a template.');
    const row = await this.prisma.scheduleTemplate.create({
      data: {
        venueId: scope!.venueId,
        name,
        shifts: shifts.map((shift) => ({
          dayIndex: shift.dayIndex,
          startMinutes: shift.startMinutes,
          endMinutes: shift.endMinutes,
          jobTitle: shift.jobTitle,
          station: shift.station,
          notes: shift.notes,
        })) as Prisma.InputJsonValue,
      },
    });
    return row.id;
  }

  @RequireSubscription()
  @Post('templates/:id/apply')
  async applyScheduleTemplate(@VenueScope() scope: Scope, @Param('id') id: string, @Body() body: ApplyTemplateDto) {
    this.requireManager(scope);
    const template = await this.prisma.scheduleTemplate.findFirst({ where: { id, venueId: scope!.venueId } });
    if (!template) throw new NotFoundException('Template not found');
    const slots = this.parseTemplateSlots(template.shifts);
    if (slots.length === 0) throw new BadRequestException('This template has no shifts to apply.');
    return this.assignments.applyTemplate({
      venueId: scope!.venueId,
      weekStart: await this.resolveAvailabilityWeekStart(scope!.venueId, body.weekStart),
      replace: body.replace,
      slots,
    });
  }

  @RequireSubscription()
  @Delete('templates/:id')
  async deleteScheduleTemplate(@VenueScope() scope: Scope, @Param('id') id: string) {
    this.requireManager(scope);
    const template = await this.prisma.scheduleTemplate.findFirst({ where: { id, venueId: scope!.venueId } });
    if (!template) throw new NotFoundException('Template not found');
    await this.prisma.scheduleTemplate.delete({ where: { id: template.id } });
    return { ok: true };
  }

  @RequireSubscription()
  @Post('copy-day')
  async copyDayShifts(@VenueScope() scope: Scope, @Body() body: CopyDayDto) {
    this.requireManager(scope);
    if (!Number.isInteger(body.fromDay) || body.fromDay < 0 || body.fromDay > 6) {
      throw new BadRequestException('fromDay must be between 0 and 6.');
    }
    if (
      !Array.isArray(body.toDays) ||
      body.toDays.length === 0 ||
      body.toDays.some((day) => !Number.isInteger(day) || day < 0 || day > 6)
    ) {
      throw new BadRequestException('toDays must contain days between 0 and 6.');
    }
    return this.assignments.copyDayShifts({
      venueId: scope!.venueId,
      weekStart: await this.resolveAvailabilityWeekStart(scope!.venueId, body.weekStart),
      fromDay: body.fromDay,
      toDays: [...new Set(body.toDays)],
    });
  }

  @RequireSubscription()
  @Post('clear-week')
  async clearWeek(@VenueScope() scope: Scope, @Body() body: WeekDto) {
    this.requireManager(scope);
    return this.assignments.clearWeek({
      venueId: scope!.venueId,
      weekStart: await this.resolveAvailabilityWeekStart(scope!.venueId, body.weekStart),
    });
  }

  @RequireSubscription()
  @Post('restore-shifts')
  async restoreShifts(@VenueScope() scope: Scope, @Body() body: RestoreShiftsDto) {
    this.requireManager(scope);
    const shifts = body.shifts.map((shift) => ({
      ...shift,
      endMinutes: ensureValidShiftWindow(shift.dayIndex, shift.startMinutes, shift.endMinutes),
    }));
    return this.assignments.restoreShifts({
      venueId: scope!.venueId,
      weekStart: await this.resolveAvailabilityWeekStart(scope!.venueId, body.weekStart),
      shifts,
    });
  }

  @RequireSubscription()
  @Get('auto-schedule/preview')
  async previewAutoSchedule(@VenueScope() scope: Scope, @Query('weekStartDate') weekStartDate?: string) {
    this.requireManager(scope);
    const availabilityWeekStart = await this.resolveAvailabilityWeekStart(scope!.venueId, weekStartDate);
    const previousSaturday = previousOvernightFilter(availabilityWeekStart, 0);
    const [shifts, staff, requests, venue] = await Promise.all([
      this.prisma.scheduleShift.findMany({
        where: {
          venueId: scope!.venueId,
          OR: [
            { weekStart: availabilityWeekStart },
            { weekStart: previousSaturday.weekStart, dayIndex: previousSaturday.dayIndex, endMinutes: { gt: 1440 } },
          ],
        },
        include: { profile: true },
        orderBy: [{ dayIndex: 'asc' }, { startMinutes: 'asc' }],
      }),
      this.prisma.profile.findMany({
        where: { venueId: scope!.venueId, OR: ACTIVE_MEMBERSHIP },
        orderBy: { fullName: 'asc' },
      }),
      this.unavailableRequests(scope!.venueId, availabilityWeekStart),
      this.prisma.venue.findUnique({
        where: { id: scope!.venueId },
        select: { weeklyLaborBudgetHours: true },
      }),
    ]);
    const availabilityByProfile = this.unavailableByProfile(requests, availabilityWeekStart);
    const openShifts = shifts.filter((shift) =>
      shift.status === 'open' && !shift.profileId && (shift.weekStart ?? availabilityWeekStart) === availabilityWeekStart,
    );
    const assignments = new Map<string, number>();
    for (const s of shifts) {
      // ScheduleShift has no cancelled status; removed shifts are deleted.
      // Every persisted assigned shift contributes to the weekly totals.
      if (s.profileId && (s.weekStart ?? availabilityWeekStart) === availabilityWeekStart) {
        const dur = Math.max(0, s.endMinutes - s.startMinutes);
        assignments.set(s.profileId, (assignments.get(s.profileId) ?? 0) + dur);
      }
    }
    let totalScheduledMinutes = Array.from(assignments.values()).reduce((sum, m) => sum + m, 0);
    const maxBudgetMinutes = venue?.weeklyLaborBudgetHours != null ? venue.weeklyLaborBudgetHours * 60 : Infinity;
    const assignedWindows: Array<{ profileId: string; weekStart: string | null; dayIndex: number; startMinutes: number; endMinutes: number }> = [];
    const proposals = openShifts.map((shift) => {
      const shiftDuration = Math.max(0, shift.endMinutes - shift.startMinutes);
      if (totalScheduledMinutes + shiftDuration > maxBudgetMinutes) {
        return {
          shiftId: shift.id,
          dayLabel: dayLabel(shift.dayIndex),
          startTime: minutesToTime(shift.startMinutes),
          endTime: minutesToTime(shift.endMinutes),
          jobTitle: shift.jobTitle,
          station: shift.station,
          profileId: null,
          status: 'unassigned',
          reason: 'exceeds_labor_budget',
        };
      }
      let sawRoleMatch = false;
      let sawAvailable = false;
      let sawFree = false;
      const candidate = staff.find((member) => {
        const assignedMinutes = assignments.get(member.id) ?? 0;
        const roleMatch =
          member.jobTitle.toLowerCase().includes(shift.jobTitle.toLowerCase()) ||
          shift.jobTitle.toLowerCase().includes(member.jobTitle.toLowerCase()) ||
          member.role === 'staff' ||
          member.role === 'server';
        if (!roleMatch) return false;
        sawRoleMatch = true;
        const shiftWindow = { ...shift, weekStart: shift.weekStart ?? availabilityWeekStart };
        const hasAvailability = availabilityCovers(availabilityByProfile.get(member.id), shiftWindow);
        if (!hasAvailability) return false;
        sawAvailable = true;
        const overlapsExisting = shifts.some((other) =>
          other.profileId === member.id &&
          shiftsOverlap(shiftWindow, { ...other, weekStart: other.weekStart ?? availabilityWeekStart }),
        );
        const overlapsProposed = assignedWindows.some((other) =>
          other.profileId === member.id && shiftsOverlap(shiftWindow, other),
        );
        if (overlapsExisting || overlapsProposed) return false;
        sawFree = true;
        return (assignedMinutes + shiftDuration) <= 40 * 60;
      });
      if (candidate) {
        assignments.set(candidate.id, (assignments.get(candidate.id) ?? 0) + shiftDuration);
        totalScheduledMinutes += shiftDuration;
        assignedWindows.push({
          profileId: candidate.id,
          weekStart: shift.weekStart ?? availabilityWeekStart,
          dayIndex: shift.dayIndex,
          startMinutes: shift.startMinutes,
          endMinutes: shift.endMinutes,
        });
      }
      return {
        shiftId: shift.id,
        dayLabel: dayLabel(shift.dayIndex),
        startTime: minutesToTime(shift.startMinutes),
        endTime: minutesToTime(shift.endMinutes),
        jobTitle: shift.jobTitle,
        station: shift.station,
        profileId: candidate ? candidate.id : null,
        reason: candidate ? 'assigned' : !sawRoleMatch ? 'no_role_match' : !sawAvailable ? 'no_availability' : !sawFree ? 'all_double_booked' : 'labor_cap',
      };
    });
    const filled = proposals.filter((proposal) => proposal.profileId).length;
    return {
      weekStart: availabilityWeekStart,
      openCount: openShifts.length,
      filled,
      unfilled: openShifts.length - filled,
      proposals,
    };
  }

  @RequireSubscription()
  @Post('auto-schedule/apply')
  async applyAutoSchedule(@VenueScope() scope: Scope, @Body() body: ApplyAutoScheduleDto) {
    this.requireManager(scope);
    const availabilityWeekStart = await this.resolveAvailabilityWeekStart(scope!.venueId, body.weekStartDate);
    const [requests, existingShifts, venue] = await Promise.all([
      this.unavailableRequests(scope!.venueId, availabilityWeekStart),
      this.prisma.scheduleShift.findMany({
        where: {
          venueId: scope!.venueId,
          weekStart: availabilityWeekStart,
          profileId: { not: null },
        },
        select: { profileId: true, startMinutes: true, endMinutes: true },
      }),
      this.prisma.venue.findUnique({
        where: { id: scope!.venueId },
        select: { weeklyLaborBudgetHours: true },
      }),
    ]);
    const availabilityByProfile = this.unavailableByProfile(requests, availabilityWeekStart);
    const weeklyMinutesByProfile = new Map<string, number>();
    for (const s of existingShifts) {
      if (s.profileId) {
        const dur = Math.max(0, s.endMinutes - s.startMinutes);
        weeklyMinutesByProfile.set(s.profileId, (weeklyMinutesByProfile.get(s.profileId) ?? 0) + dur);
      }
    }
    let totalVenueMinutes = Array.from(weeklyMinutesByProfile.values()).reduce((sum, m) => sum + m, 0);
    const maxBudgetMinutes = venue?.weeklyLaborBudgetHours != null ? venue.weeklyLaborBudgetHours * 60 : Infinity;

    const { assigned, skipped, assignedShifts } = await this.assignments.applyOpenAssignments({
      venueId: scope!.venueId,
      assignments: body.assignments,
      // Read-only: this runs before the write, which can still be rejected.
      // The running totals are advanced in onAssigned so a skipped shift does
      // not spend against the 40h cap or the venue's labor budget.
      canAssign: ({ shift, profileId }) => {
        if (!availabilityCovers(availabilityByProfile.get(profileId), shift)) return false;
        const dur = Math.max(0, shift.endMinutes - shift.startMinutes);
        if ((weeklyMinutesByProfile.get(profileId) ?? 0) + dur > 40 * 60) return false;
        if (totalVenueMinutes + dur > maxBudgetMinutes) return false;
        return true;
      },
      onAssigned: ({ shift, profileId }) => {
        const dur = Math.max(0, shift.endMinutes - shift.startMinutes);
        weeklyMinutesByProfile.set(profileId, (weeklyMinutesByProfile.get(profileId) ?? 0) + dur);
        totalVenueMinutes += dur;
      },
    });
    const assignedByProfile = new Map<string, typeof assignedShifts>();
    for (const assignedShift of assignedShifts) {
      const profileAssignments = assignedByProfile.get(assignedShift.profileId) ?? [];
      profileAssignments.push(assignedShift);
      assignedByProfile.set(assignedShift.profileId, profileAssignments);
    }
    const assignedProfiles = assignedByProfile.size
      ? await this.prisma.profile.findMany({
          where: { id: { in: Array.from(assignedByProfile.keys()) } },
          select: { id: true, email: true },
        })
      : [];
    for (const profile of assignedProfiles) {
      const profileAssignments = assignedByProfile.get(profile.id) ?? [];
      void this.email.send({
        to: profile.email,
        ...newShiftsAssignedTemplate({
          shifts: profileAssignments.map((shift) => ({ label: this.shiftLabel(shift), jobTitle: shift.jobTitle, station: shift.station })),
        }),
      });
    }
    return { assigned, skipped };
  }

  // AI schedule builder: generates NEW shift proposals from demand (covers,
  // private events) and the labor budget, distinct from auto-schedule/*
  // above which only assigns staff to shifts that already exist.
  @RequireSubscription()
  @Get('ai-schedule/preview')
  async previewAiSchedule(@VenueScope() scope: Scope, @Query('weekStartDate') weekStartDate?: string) {
    this.requireManager(scope);
    const venueId = scope!.venueId;
    await assertWithinSharedRateLimit(
      this.prisma,
      `ai-parse:ai-schedule:${venueId}`,
      AI_SCHEDULE_RATE_LIMIT_MAX,
      AI_SCHEDULE_RATE_LIMIT_WINDOW_MS,
      'Too many AI schedule requests. Try again in a few minutes.',
    );
    const availabilityWeekStart = await this.resolveAvailabilityWeekStart(venueId, weekStartDate);
    const venue = await this.prisma.venue.findUnique({ where: { id: venueId }, select: { timezone: true, weeklyLaborBudgetHours: true } });
    const timezone = venue?.timezone ?? null;
    const weekStartDayUtc = new Date(zonedDateBounds(timezone, availabilityWeekStart).start);
    const nextWeekStart = addDays(availabilityWeekStart, 7);
    const weekEndDayUtc = new Date(zonedDateBounds(timezone, nextWeekStart).start);
    const previousSaturday = previousOvernightFilter(availabilityWeekStart, 0);

    const [shifts, staff, unavailableRequests, reservations, venueEvents, memoryNotes] = await Promise.all([
      this.prisma.scheduleShift.findMany({
        where: {
          venueId,
          OR: [
            { weekStart: availabilityWeekStart },
            { weekStart: previousSaturday.weekStart, dayIndex: previousSaturday.dayIndex, endMinutes: { gt: 1440 } },
          ],
        },
      }),
      this.prisma.profile.findMany({
        where: { venueId, OR: ACTIVE_MEMBERSHIP },
        orderBy: { fullName: 'asc' },
      }),
      this.unavailableRequests(venueId, availabilityWeekStart),
      this.prisma.reservation.findMany({
        where: {
          venueId,
          deletedAt: null,
          reservationTime: { gte: weekStartDayUtc, lt: weekEndDayUtc },
          status: { notIn: ['cancelled', 'no_show'] },
        },
        select: { reservationTime: true, partySize: true, isPrivateEvent: true },
      }),
      this.prisma.venueEvent.findMany({
        where: { venueId, startsAt: { gte: weekStartDayUtc, lt: weekEndDayUtc } },
        select: { startsAt: true, expectedGuests: true },
      }),
      this.prisma.scheduleMemoryNote.findMany({
        where: { venueId },
        orderBy: { createdAt: 'desc' },
        take: 8,
      }),
    ]);

    const laborForecast = buildLaborForecast({
      tz: venue?.timezone ?? null,
      now: weekStartDayUtc,
      weekStart: availabilityWeekStart,
      shifts: shifts.map((s) => ({ weekStart: s.weekStart, dayIndex: s.dayIndex, startMinutes: s.startMinutes, endMinutes: s.endMinutes, profileId: s.profileId })),
      reservations: reservations.map((r) => ({ ts: r.reservationTime.getTime(), partySize: r.partySize, isPrivateEvent: Boolean(r.isPrivateEvent) })),
      events: venueEvents.map((e) => ({ ts: e.startsAt.getTime(), expectedGuests: e.expectedGuests })),
      nameById: new Map(staff.map((p) => [p.id, p.fullName])),
    });
    const existingShiftSegments = shifts.flatMap((shift) =>
      occupiedSlots(shift)
        .filter((slot) => slot.weekStart === availabilityWeekStart)
        .map((slot) => ({
          weekStart: slot.weekStart ?? availabilityWeekStart,
          dayIndex: slot.dayIndex,
          startMinutes: slot.start,
          endMinutes: slot.end,
          jobTitle: shift.jobTitle,
          profileId: shift.profileId,
        })),
    );

    const draft = await this.aiScheduler.generateDraft({
      weekStart: availabilityWeekStart,
      laborForecast,
      laborBudgetHours: venue?.weeklyLaborBudgetHours ?? null,
      staff: staff.map((p) => ({ id: p.id, fullName: p.fullName, jobTitle: p.jobTitle, role: p.role })),
      availabilityByProfile: this.unavailableByProfile(unavailableRequests, availabilityWeekStart),
      existingShifts: existingShiftSegments,
      memoryNotes: memoryNotes.map((note) => ({ weekStart: note.weekStart, title: note.title, detail: note.detail })),
    });

    const nameById = new Map(staff.map((p) => [p.id, p.fullName]));
    return {
      weekStart: availabilityWeekStart,
      shifts: draft.shifts.map((shift) => ({
        ...shift,
        dayLabel: dayLabel(shift.dayIndex),
        startTime: minutesToTime(shift.startMinutes),
        endTime: minutesToTime(shift.endMinutes),
        memberName: shift.profileId ? nameById.get(shift.profileId) ?? null : null,
      })),
    };
  }

  @RequireSubscription()
  @Post('ai-schedule/commit')
  async commitAiSchedule(@VenueScope() scope: Scope, @Body() body: CommitAiScheduleDto) {
    this.requireManager(scope);
    const venueId = scope!.venueId;
    // Re-check availability server-side rather than trusting the AI's
    // proposed assignment — mirrors auto-schedule/apply's canAssign guard.
    const availabilityWeekStart = await this.resolveAvailabilityWeekStart(venueId, body.weekStartDate);
    const availabilityByProfile = this.unavailableByProfile(await this.unavailableRequests(venueId, availabilityWeekStart), availabilityWeekStart);

    let created = 0;
    const failed: Array<{ shift: string; error: string }> = [];
    for (const shift of body.shifts) {
      try {
        const endMinutes = ensureValidShiftWindow(shift.dayIndex, shift.startMinutes, shift.endMinutes);
        const profileId = shift.profileId && availabilityCovers(availabilityByProfile.get(shift.profileId), { ...shift, endMinutes, weekStart: availabilityWeekStart })
          ? shift.profileId
          : undefined;
        await this.assignments.createShift({
          venueId,
          weekStart: availabilityWeekStart,
          profileId,
          dayIndex: shift.dayIndex,
          startMinutes: shift.startMinutes,
          endMinutes,
          jobTitle: shift.jobTitle,
          station: shift.station,
          notes: 'Created by AI schedule builder',
        });
        created += 1;
      } catch (error) {
        failed.push({ shift: this.shiftLabel(shift), error: error instanceof Error ? error.message : 'Could not create shift' });
      }
    }
    return { created, failed };
  }

  @RequireSubscription()
  @Post('swaps')
  async proposeShiftSwap(@VenueScope() scope: Scope, @Body() body: ProposeSwapDto) {
    if (!scope) throw new ForbiddenException('Profile does not belong to a venue');
    const { swap, requesterShift, target } = await this.assignments.proposeSwap({
      venueId: scope.venueId,
      requesterProfileId: scope.profileId,
      requesterShiftId: body.myShiftId,
      targetProfileId: body.targetProfileId,
      targetShiftId: body.targetShiftId,
      note: body.note,
    });
    await this.notifications.notifyProfile({
      venueId: scope.venueId,
      profileId: target.id,
      kind: 'swap_proposed',
      title: 'Shift swap proposed',
      body: `${scope.fullName} wants to swap ${this.shiftLabel(requesterShift)}.`,
    });
    void this.email.sendToProfile(
      target.id,
      shiftSwapProposedTemplate({ proposerName: scope.fullName, shiftLabel: this.shiftLabel(requesterShift), note: body.note }),
    );
    return swap.id;
  }

  @RequireSubscription()
  @Patch('swaps/:id/respond')
  async respondToShiftSwap(@VenueScope() scope: Scope, @Param('id') id: string, @Body() body: RespondSwapDto) {
    if (!scope) throw new ForbiddenException('Profile does not belong to a venue');
    const swap = await this.assignments.respondToSwap({
      venueId: scope.venueId,
      swapId: id,
      profileId: scope.profileId,
      accept: body.accept,
    });
    if (body.accept) {
      await this.notifications.notifyManagers({
        venueId: scope.venueId,
        kind: 'swap_proposed',
        title: 'Swap needs approval',
        body: `${scope.fullName} accepted a shift swap. Approve it in the schedule.`,
      });
      void this.sendManagerSwapApprovalEmail(scope.venueId, swap.id);
    }
    return { ok: true };
  }

  @RequireSubscription()
  @Patch('swaps/:id/review')
  async reviewShiftSwap(@VenueScope() scope: Scope, @Param('id') id: string, @Body() body: ReviewSwapDto) {
    this.requireManager(scope);
    const swap = await this.assignments.reviewSwap({
      venueId: scope!.venueId,
      swapId: id,
      approve: body.approve,
    });
    // Either party's profile can be null if that account was deleted after
    // this swap was proposed/accepted (see the schema comment on
    // ShiftSwap.requesterProfileId/targetProfileId) — nothing to notify then.
    if (swap.requesterProfileId) {
      await this.notifications.notifyProfile({
        venueId: scope!.venueId,
        profileId: swap.requesterProfileId,
        kind: 'swap_reviewed',
        title: `Swap ${body.approve ? 'approved' : 'denied'}`,
        body: `Your shift swap was ${body.approve ? 'approved' : 'denied'}.`,
      });
    }
    void this.sendStaffSwapReviewedEmail(scope!.venueId, swap.id, body.approve);
    if (swap.targetProfileId) {
      await this.notifications.notifyProfile({
        venueId: scope!.venueId,
        profileId: swap.targetProfileId,
        kind: 'swap_reviewed',
        title: `Swap ${body.approve ? 'approved' : 'denied'}`,
        body: `A shift swap was ${body.approve ? 'approved' : 'denied'}.`,
      });
    }
    return { ok: true };
  }

  @RequireSubscription()
  @Get('swaps/me')
  async getMyShiftSwaps(@VenueScope() scope: Scope) {
    if (!scope) return [];
    const swaps = await this.prisma.shiftSwap.findMany({
      where: {
        venueId: scope.venueId,
        OR: [{ requesterProfileId: scope.profileId }, { targetProfileId: scope.profileId }],
      },
      orderBy: { createdAt: 'desc' },
      take: 50,
    });
    return this.mapSwaps(scope.venueId, swaps, scope.profileId);
  }

  @RequireSubscription()
  @Get('swaps')
  async listShiftSwaps(@VenueScope() scope: Scope) {
    this.requireManager(scope);
    const swaps = await this.prisma.shiftSwap.findMany({
      where: { venueId: scope!.venueId, status: { in: ['proposed', 'accepted'] } },
      orderBy: { createdAt: 'desc' },
      take: 100,
    });
    return this.mapSwaps(scope!.venueId, swaps, null);
  }

  private requireManager(scope: Scope): asserts scope is NonNullable<Scope> {
    if (!scope || !canManageVenue(scope.role, scope.allAccess)) throw new ForbiddenException('Not authorized');
  }

  private resolveAvailabilityWeekStart(venueId: string, weekStartDate?: string) {
    if (weekStartDate) {
      if (!isIsoDate(weekStartDate)) throw new BadRequestException('weekStartDate must be a YYYY-MM-DD date');
      return Promise.resolve(weekStartFor(weekStartDate));
    }
    return this.prisma.venue.findUnique({ where: { id: venueId }, select: { timezone: true } })
      .then((venue) => weekStartFor(todayInZone(venue?.timezone ?? null)));
  }

  private async unavailableRequests(venueId: string, weekStart: string) {
    const weekEnd = this.dateForWeekDay(weekStart, 6);
    return this.prisma.staffRequest.findMany({
      where: {
        venueId, status: 'approved', kind: { in: ['time_off', 'sick_leave'] },
        OR: [
          { requestedRangeStart: { lte: weekEnd }, requestedRangeEnd: { gte: weekStart } },
          { requestedForDate: { gte: weekStart, lte: weekEnd } },
        ],
      },
      select: { profileId: true, requestedForDate: true, requestedRangeStart: true, requestedRangeEnd: true },
    });
  }

  private unavailableByProfile(requests: Array<{ profileId: string; requestedForDate: string | null; requestedRangeStart: string | null; requestedRangeEnd: string | null }>, weekStart: string) {
    const byProfile = new Map<string, AvailabilityWindow[]>();
    for (const request of requests) {
      const start = request.requestedRangeStart ?? request.requestedForDate;
      const end = request.requestedRangeEnd ?? request.requestedForDate ?? start;
      if (!start || !end) continue;
      for (let dayIndex = 0; dayIndex < 7; dayIndex++) {
        const date = this.dateForWeekDay(weekStart, dayIndex);
        if (date < start || date > end) continue;
        const rows = byProfile.get(request.profileId) ?? [];
        rows.push({ dayIndex, startMinutes: 0, endMinutes: 1440, available: false });
        byProfile.set(request.profileId, rows);
      }
    }
    return byProfile;
  }

  private dateForWeekDay(weekStart: string, dayIndex: number) {
    const date = new Date(`${weekStart}T00:00:00.000Z`);
    date.setUTCDate(date.getUTCDate() + dayIndex);
    return date.toISOString().slice(0, 10);
  }

  private mapManagerShift(shift: ShiftWithProfile, conflict = false) {
    return {
      _id: shift.id,
      dayIndex: shift.dayIndex,
      dayLabel: dayLabel(shift.dayIndex),
      startMinutes: shift.startMinutes,
      endMinutes: shift.endMinutes,
      startTime: minutesToTime(shift.startMinutes),
      endTime: minutesToTime(shift.endMinutes),
      jobTitle: shift.jobTitle,
      station: shift.station,
      notes: shift.notes,
      status: shift.status,
      profileId: shift.profileId,
      memberName: shift.profileId ? shift.profile?.fullName ?? null : null,
      conflict,
    };
  }

  private mapEmployeeShift(shift: ShiftWithProfile, mine: boolean, conflict = false) {
    return {
      _id: shift.id,
      dayIndex: shift.dayIndex,
      dayLabel: dayLabel(shift.dayIndex),
      startMinutes: shift.startMinutes,
      endMinutes: shift.endMinutes,
      startTime: minutesToTime(shift.startMinutes),
      endTime: minutesToTime(shift.endMinutes),
      memberId: shift.profileId,
      memberName: shift.profile?.fullName ?? null,
      jobTitle: shift.jobTitle,
      station: shift.station,
      status: shift.status,
      notes: shift.notes ?? undefined,
      mine,
      conflict,
    };
  }

  private parseTemplateSlots(value: Prisma.JsonValue): TemplateShiftSlot[] {
    if (!Array.isArray(value)) return [];
    return value.map((slot) => {
      const parsed = plainToInstance(TemplateShiftDto, slot);
      const errors = validateSync(parsed, { whitelist: true, forbidNonWhitelisted: true });
      if (errors.length > 0) {
        throw new BadRequestException('Template contains an invalid shift.');
      }
      parsed.endMinutes = ensureValidShiftWindow(parsed.dayIndex, parsed.startMinutes, parsed.endMinutes);
      return parsed as TemplateShiftSlot;
    });
  }

  private shiftLabel(shift: { dayIndex: number; startMinutes: number; endMinutes: number }) {
    return `${dayLabel(shift.dayIndex)} ${minutesToTime(shift.startMinutes)}-${minutesToTime(shift.endMinutes)}`;
  }

  private async mapSwaps(venueId: string, swaps: Array<{ id: string; status: string; note: string | null; requesterProfileId: string | null; targetProfileId: string | null; requesterShiftId: string; targetShiftId: string | null; createdAt: Date }>, meId: string | null) {
    // Labels only ever need the shifts these swaps reference — loading the
    // venue's entire shift history here grew unbounded with venue age.
    const staff = await this.prisma.profile.findMany({ where: { venueId, OR: ACTIVE_MEMBERSHIP } });
    const referencedShiftIds = [...new Set(swaps.flatMap((swap) => [swap.requesterShiftId, swap.targetShiftId].filter((id): id is string => Boolean(id))))];
    const shifts = referencedShiftIds.length > 0
      ? await this.prisma.scheduleShift.findMany({
          where: { venueId, id: { in: referencedShiftIds } },
          select: { id: true, dayIndex: true, startMinutes: true, endMinutes: true },
        })
      : [];
    const nameById = new Map(staff.map((member) => [member.id, member.fullName]));
    const shiftById = new Map(shifts.map((shift) => [shift.id, shift]));
    return swaps
      .filter((swap) => SWAP_STATUSES.includes(swap.status))
      .map((swap) => ({
        _id: swap.id,
        status: swap.status,
        note: swap.note,
        requesterName: (swap.requesterProfileId && nameById.get(swap.requesterProfileId)) ?? (swap.requesterProfileId ? 'Teammate' : 'Former teammate'),
        targetName: (swap.targetProfileId && nameById.get(swap.targetProfileId)) ?? (swap.targetProfileId ? 'Teammate' : 'Former teammate'),
        requesterShift: this.shiftLabel(shiftById.get(swap.requesterShiftId) ?? { dayIndex: 0, startMinutes: 0, endMinutes: 0 }),
        targetShift: swap.targetShiftId && shiftById.get(swap.targetShiftId) ? this.shiftLabel(shiftById.get(swap.targetShiftId)!) : null,
        direction: meId === swap.targetProfileId ? 'incoming' : meId === swap.requesterProfileId ? 'outgoing' : 'other',
        createdAt: swap.createdAt.getTime(),
      }));
  }
  private sendScheduleUpdateEmail(
    profileId: string,
    changeType: 'Added' | 'Edited' | 'Removed',
    before?: ScheduleEmailShift,
    after?: ScheduleEmailShift,
  ) {
    void this.sendScheduleUpdateEmailInBackground(profileId, changeType, before, after).catch((error) => {
      this.logBackgroundFailure('schedule update email', error);
    });
  }

  private async sendScheduleUpdateEmailInBackground(
    profileId: string,
    changeType: 'Added' | 'Edited' | 'Removed',
    before?: ScheduleEmailShift,
    after?: ScheduleEmailShift,
  ) {
    const profile = await this.prisma.profile.findUnique({ where: { id: profileId } });
    if (!profile) return;

    const venue = await this.prisma.venue.findUnique({
      where: { id: profile.venueId! },
      select: { timezone: true },
    });
    const tz = venue?.timezone ?? null;
    // The date has to come from the shift's own week. This used to anchor on
    // the current week's Sunday whatever week the shift was in, so editing a
    // future-week shift emailed the staff member a date in this week — the
    // change was right and the notice about it was wrong.
    const currentSunday = weekStartFor(todayInZone(tz));

    const formatDateMDY = (shift: ScheduleEmailShift) => {
      const dateStr = addDays(shift.weekStart ?? currentSunday, shift.dayIndex);
      const [y, m, d] = dateStr.split('-');
      return `${m}/${d}/${y}`;
    };

    const formatTime = (minutes: number) => minutesToTime(minutes);
    const beforeDate = before ? formatDateMDY(before) : '-';
    const beforeTime = before ? `${formatTime(before.startMinutes)} - ${formatTime(before.endMinutes)}` : '-';
    const beforeArea = before ? (before.station || 'Floor') : '-';
    const afterDate = after ? formatDateMDY(after) : '-';
    const afterTime = after ? `${formatTime(after.startMinutes)} - ${formatTime(after.endMinutes)}` : '-';
    const afterArea = after ? (after.station || 'Floor') : '-';

    void this.email.sendToProfile(
      profileId,
      shiftChangedTemplate({
        fullName: profile.fullName,
        changeType,
        before: { date: beforeDate, time: beforeTime, area: beforeArea },
        after: { date: afterDate, time: afterTime, area: afterArea },
      }),
    );
  }

  private sendManagerSwapApprovalEmail(venueId: string, swapId: string) {
    void this.sendManagerSwapApprovalEmailInBackground(venueId, swapId).catch((error) => {
      this.logBackgroundFailure('manager swap approval email', error);
    });
  }

  private async sendManagerSwapApprovalEmailInBackground(venueId: string, swapId: string) {
    const swap = await this.prisma.shiftSwap.findUnique({ where: { id: swapId } });
    // A party's profile can be null if that account was deleted after this
    // swap was proposed/accepted — nothing useful to email in that case.
    if (!swap || !swap.requesterProfileId || !swap.targetProfileId) return;

    const [requester, target, reqShift, tarShift] = await Promise.all([
      this.prisma.profile.findUnique({ where: { id: swap.requesterProfileId } }),
      this.prisma.profile.findUnique({ where: { id: swap.targetProfileId } }),
      this.prisma.scheduleShift.findUnique({ where: { id: swap.requesterShiftId } }),
      swap.targetShiftId ? this.prisma.scheduleShift.findUnique({ where: { id: swap.targetShiftId } }) : Promise.resolve(null),
    ]);

    if (!requester || !target || !reqShift) return;

    const venue = await this.prisma.venue.findUnique({
      where: { id: venueId },
      select: { timezone: true, name: true },
    });
    const tz = venue?.timezone ?? null;
    const today = todayInZone(tz);
    const sunday = weekStartFor(today);

    const formatDateMDY = (dayIdx: number) => {
      const dateStr = addDays(sunday, dayIdx);
      const [y, m, d] = dateStr.split('-');
      return `${m}/${d}/${y}`;
    };

    const formatTime = (minutes: number) => minutesToTime(minutes);

    const reqDate = formatDateMDY(reqShift.dayIndex);
    const reqTime = `${formatTime(reqShift.startMinutes)} - ${formatTime(reqShift.endMinutes)}`;
    const tarDate = tarShift ? formatDateMDY(tarShift.dayIndex) : '-';
    const tarTime = tarShift ? `${formatTime(tarShift.startMinutes)} - ${formatTime(tarShift.endMinutes)}` : '-';

    // Format submitted timestamp (createdAt)
    const submittedStr = swap.createdAt.toLocaleString('en-US', {
      timeZone: tz || undefined,
      year: 'numeric',
      month: '2-digit',
      day: '2-digit',
      hour: '2-digit',
      minute: '2-digit',
      hour12: true,
    });

    // Send to all managers at the venue
    const managers = await this.prisma.profile.findMany({
      where: {
        venueId,
        role: { in: ['admin', 'owner', 'manager'] },
      },
    });

    for (const manager of managers) {
      void this.email.send({
        to: manager.email,
        ...shiftSwapActionRequiredTemplate({
          managerName: manager.fullName,
          requesterName: requester.fullName,
          targetName: target.fullName,
          requesterDate: reqDate,
          requesterTime: reqTime,
          targetDate: tarDate,
          targetTime: tarTime,
          submittedAt: submittedStr,
        }),
      });
    }
  }

  private sendStaffSwapReviewedEmail(venueId: string, swapId: string, approve: boolean) {
    void this.sendStaffSwapReviewedEmailInBackground(venueId, swapId, approve).catch((error) => {
      this.logBackgroundFailure('staff swap review email', error);
    });
  }

  private async sendStaffSwapReviewedEmailInBackground(venueId: string, swapId: string, approve: boolean) {
    const swap = await this.prisma.shiftSwap.findUnique({ where: { id: swapId } });
    // A party's profile can be null if that account was deleted after this
    // swap was proposed/accepted — nothing useful to email in that case.
    if (!swap || !swap.requesterProfileId || !swap.targetProfileId) return;

    const [requester, target, reqShift, tarShift] = await Promise.all([
      this.prisma.profile.findUnique({ where: { id: swap.requesterProfileId } }),
      this.prisma.profile.findUnique({ where: { id: swap.targetProfileId } }),
      this.prisma.scheduleShift.findUnique({ where: { id: swap.requesterShiftId } }),
      swap.targetShiftId ? this.prisma.scheduleShift.findUnique({ where: { id: swap.targetShiftId } }) : Promise.resolve(null),
    ]);

    if (!requester || !target || !reqShift) return;

    const venue = await this.prisma.venue.findUnique({
      where: { id: venueId },
      select: { timezone: true },
    });
    const tz = venue?.timezone ?? null;
    const today = todayInZone(tz);
    const sunday = weekStartFor(today);

    const formatDateMDY = (dayIdx: number) => {
      const dateStr = addDays(sunday, dayIdx);
      const [y, m, d] = dateStr.split('-');
      return `${m}/${d}/${y}`;
    };

    const formatTime = (minutes: number) => minutesToTime(minutes);

    const reqDate = formatDateMDY(reqShift.dayIndex);
    const reqTime = `${formatTime(reqShift.startMinutes)} - ${formatTime(reqShift.endMinutes)}`;
    const tarDate = tarShift ? formatDateMDY(tarShift.dayIndex) : '-';
    const tarTime = tarShift ? `${formatTime(tarShift.startMinutes)} - ${formatTime(tarShift.endMinutes)}` : '-';

    const statusText = approve ? 'Approved' : 'Denied';

    const sendEmail = (recipient: typeof requester, coworker: typeof target, isRequester: boolean) => {
      void this.email.send({
        to: recipient.email,
        ...shiftSwapDecidedTemplate({
          fullName: recipient.fullName,
          coworkerName: coworker.fullName,
          approved: approve,
          yourShift: { date: isRequester ? reqDate : tarDate, time: isRequester ? reqTime : tarTime },
          coworkerShift: { date: isRequester ? tarDate : reqDate, time: isRequester ? tarTime : reqTime },
        }),
      });
    };

    // Send to both employees
    sendEmail(requester, target, true);
    sendEmail(target, requester, false);
  }

  private logBackgroundFailure(label: string, error: unknown) {
    this.logger.error(
      `${label} failed: ${error instanceof Error ? error.message : String(error)}`,
      error instanceof Error ? error.stack : undefined,
    );
  }
}

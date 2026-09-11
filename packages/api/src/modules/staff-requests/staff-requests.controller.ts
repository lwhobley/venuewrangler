import {
  BadRequestException,
  Body,
  Controller,
  ForbiddenException,
  Get,
  NotFoundException,
  Param,
  Patch,
  Post,
  Query,
} from '@nestjs/common';
import {
  ArrayMaxSize,
  IsArray,
  IsBoolean,
  IsIn,
  IsInt,
  IsNumber,
  IsOptional,
  IsString,
  Matches,
  MaxLength,
  Min,
  ValidateNested,
} from 'class-validator';
import { Type } from 'class-transformer';
import { Prisma, RequestStatus } from '@prisma/client';
import { canManageVenue } from '../../auth/roles';
import { RequireSubscription } from '../../billing/require-subscription.decorator';
import { mapStaffRequest } from '../../common/mappers';
import { zonedDateBounds, zonedIsoDate } from '../../common/venue-time';
import { addDays, weekStartFor } from '../../common/pay-period';
import { occupiedSlots } from '../../common/shift-overlap';
import { EmailService } from '../../email/email.service';
import { NotificationsService } from '../../notifications/notifications.service';
import { PrismaService } from '../../prisma/prisma.service';
import { VenueScope } from '../../venue/venue-scope.decorator';
import type { VenueScopedRequest } from '../../venue/venue-scope.interceptor';
import { staffRequestDecidedTemplate, staffRequestSubmittedTemplate } from '../../email/templates/staff-requests';

type Scope = VenueScopedRequest['venueScope'];

const REQUEST_KINDS = ['add_shift', 'drop_shift', 'time_off', 'shift_swap', 'open_shift', 'sick_leave', 'time_correction', 'other'];
const REVIEW_STATUSES = ['approved', 'denied', 'cancelled'];
const ISO_DATE_RE = /^\d{4}-\d{2}-\d{2}$/;
const HOURS_PER_DAY = 8.0;
const MS_PER_DAY = 24 * 60 * 60 * 1000;

/**
 * Parse a strict YYYY-MM-DD calendar date to noon UTC (noon dodges DST edges),
 * rejecting malformed or impossible values (e.g. 2026-02-31). Returns null when
 * the string is not a valid calendar date. A calendar date's identity (and its
 * weekday) is timezone-independent, so we deliberately do not involve a venue tz.
 */
export function parseIsoCalendarDate(dateStr: string | null | undefined): Date | null {
  if (!dateStr || !ISO_DATE_RE.test(dateStr)) return null;
  const [y, m, d] = dateStr.split('-').map(Number);
  const dt = new Date(Date.UTC(y, m - 1, d, 12));
  if (dt.getUTCFullYear() !== y || dt.getUTCMonth() !== m - 1 || dt.getUTCDate() !== d) {
    return null;
  }
  return dt;
}

/**
 * Whole-day hours for a PTO/sick request. Requires valid, non-reversed
 * YYYY-MM-DD dates and always returns a finite, positive number — a malformed
 * or reversed range throws rather than silently feeding NaN into a balance
 * decrement.
 */
export function calculateRequestHours(startStr?: string | null, endStr?: string | null): number {
  if (!startStr) return HOURS_PER_DAY;
  const start = parseIsoCalendarDate(startStr);
  if (!start) throw new BadRequestException('Request dates must be valid YYYY-MM-DD values.');
  const end = endStr ? parseIsoCalendarDate(endStr) : start;
  if (!end) throw new BadRequestException('Request dates must be valid YYYY-MM-DD values.');
  if (end.getTime() < start.getTime()) {
    throw new BadRequestException('End date must be on or after the start date.');
  }
  const diffDays = Math.round((end.getTime() - start.getTime()) / MS_PER_DAY) + 1;
  const hours = diffDays * HOURS_PER_DAY;
  if (!Number.isFinite(hours) || hours <= 0) {
    throw new BadRequestException('Could not compute request hours from the provided dates.');
  }
  return hours;
}

class AvailabilityBlockDto {
  @IsInt()
  dayIndex!: number;

  @IsInt()
  startMinutes!: number;

  @IsInt()
  endMinutes!: number;

  @IsBoolean()
  available!: boolean;
}

class TimeCorrectionDto {
  @IsOptional()
  @IsString()
  @MaxLength(64)
  timeEntryId?: string | null;

  @IsNumber()
  @Min(0)
  clockInAt!: number;

  @IsOptional()
  @IsNumber()
  @Min(0)
  clockOutAt?: number | null;

  @IsOptional()
  @IsString()
  @MaxLength(500)
  reason?: string;
}

class CreateStaffRequestDto {
  @IsString()
  @IsIn(REQUEST_KINDS)
  kind!: string;

  @IsString()
  @MaxLength(200)
  title!: string;

  @IsString()
  @MaxLength(4000)
  details!: string;

  @IsString()
  @IsOptional()
  @Matches(ISO_DATE_RE, { message: 'requestedForDate must be a YYYY-MM-DD date' })
  requestedForDate?: string;

  @IsString()
  @IsOptional()
  @MaxLength(64)
  requestedShiftId?: string;

  @IsString()
  @IsOptional()
  @Matches(ISO_DATE_RE, { message: 'requestedRangeStart must be a YYYY-MM-DD date' })
  requestedRangeStart?: string;

  @IsString()
  @IsOptional()
  @Matches(ISO_DATE_RE, { message: 'requestedRangeEnd must be a YYYY-MM-DD date' })
  requestedRangeEnd?: string;

  @IsArray()
  @ArrayMaxSize(100)
  @IsOptional()
  @ValidateNested({ each: true })
  @Type(() => AvailabilityBlockDto)
  availability?: AvailabilityBlockDto[];

  @IsOptional()
  @ValidateNested()
  @Type(() => TimeCorrectionDto)
  timeCorrection?: TimeCorrectionDto;
}

class ReviewStaffRequestDto {
  @IsString()
  @IsIn(REVIEW_STATUSES)
  status!: string;

  @IsString()
  @IsOptional()
  @MaxLength(2000)
  responseNotes?: string;
}

@Controller('v1/staff-requests')
export class StaffRequestsController {
  constructor(
    private readonly prisma: PrismaService,
    private readonly notifications: NotificationsService,
    private readonly email: EmailService,
  ) {}

  @RequireSubscription()
  @Get()
  async listStaffRequests(
    @VenueScope() scope: Scope,
    @Query('before') before?: string,
    @Query('limit') limitQuery?: string,
  ) {
    if (!scope) return [];
    const limit = limitQuery ? Math.min(Math.max(1, parseInt(limitQuery, 10) || 50), 500) : 500;
    const requests = await this.prisma.staffRequest.findMany({
      where: {
        venueId: scope.venueId,
        ...(canManageVenue(scope.role, scope.allAccess) ? {} : { profileId: scope.profileId }),
      },
      orderBy: [{ createdAt: 'desc' }, { id: 'desc' }],
      take: limit,
      ...(before ? { cursor: { id: before }, skip: 1 } : {}),
    });
    return requests.map(mapStaffRequest);
  }

  @RequireSubscription()
  @Post()
  async createStaffRequest(@VenueScope() scope: Scope, @Body() body: CreateStaffRequestDto) {
    if (!scope) throw new ForbiddenException('Profile does not belong to a venue');

    // Block time-off requests that overlap a manager-defined blackout window.
    if (body.kind === 'time_off') {
      const reqStart = body.requestedRangeStart || body.requestedForDate;
      const reqEnd = body.requestedRangeEnd || body.requestedForDate || reqStart;
      if (reqStart && reqEnd) {
        const blackouts = await this.prisma.blackoutDate.findMany({
          where: {
            venueId: scope.venueId,
            startDate: { lte: new Date(reqEnd + 'T23:59:59.999Z') },
            endDate: { gte: new Date(reqStart + 'T00:00:00.000Z') },
          },
        });
        const hit = blackouts.find((b) => {
          const bStart = b.startDate.toISOString().split('T')[0];
          const bEnd = b.endDate.toISOString().split('T')[0];
          return reqStart <= bEnd && bStart <= reqEnd;
        });
        if (hit) {
          const bStartStr = hit.startDate.toISOString().split('T')[0];
          const bEndStr = hit.endDate.toISOString().split('T')[0];
          throw new BadRequestException(
            `Time off is blacked out ${bStartStr}${bEndStr !== bStartStr ? ` – ${bEndStr}` : ''} (${hit.reason}). Please choose other dates.`,
          );
        }
      }
    }

    if (body.kind === 'time_correction') {
      if (!body.timeCorrection) {
        throw new BadRequestException('Time correction details are required.');
      }
      const { clockInAt, clockOutAt } = body.timeCorrection;
      if (clockOutAt != null && clockOutAt <= clockInAt) {
        throw new BadRequestException('Clock-out time must be after clock-in time.');
      }
    }
    const requestPayload = body.kind === 'time_correction' ? body.timeCorrection : body.availability;

    const profile = await this.prisma.profile.findUniqueOrThrow({ where: { id: scope.profileId } });
    const request = await this.prisma.staffRequest.create({
      data: {
        venueId: scope.venueId,
        profileId: scope.profileId,
        kind: body.kind,
        status: 'pending',
        title: body.title,
        details: body.details,
        requestedForDate: body.requestedForDate,
        requestedShiftId: body.requestedShiftId,
        requestedRangeStart: body.requestedRangeStart,
        requestedRangeEnd: body.requestedRangeEnd,
        availability: requestPayload
          ? (requestPayload as unknown as Prisma.InputJsonValue)
          : undefined,
      },
    });

    await this.notifications.notifyManagers({
      venueId: scope.venueId,
      kind: 'request_created',
      title: 'New staff request',
      body: `${profile.fullName} submitted ${body.kind.replace('_', ' ')}: ${body.title}`,
    });
    const kindLabel = body.kind.replace('_', ' ').replace(/\b\w/g, (c) => c.toUpperCase());
    const reqStart = body.requestedRangeStart || body.requestedForDate;
    const reqEnd = body.requestedRangeEnd || body.requestedForDate || reqStart;
    const dateRangeStr = reqStart && reqEnd ? (reqStart === reqEnd ? reqStart : `${reqStart} – ${reqEnd}`) : null;

    void this.email.sendToVenueManagers(
      scope.venueId,
      staffRequestSubmittedTemplate({ employeeName: profile.fullName, kindLabel, title: body.title, details: body.details, dateRange: dateRangeStr }),
    );

    return mapStaffRequest(request);
  }

  @RequireSubscription()
  @Patch(':id')
  async reviewStaffRequest(
    @VenueScope() scope: Scope,
    @Param('id') id: string,
    @Body() body: ReviewStaffRequestDto,
  ) {
    if (!scope || !canManageVenue(scope.role, scope.allAccess)) {
      throw new ForbiddenException('Not authorized');
    }

    const result = await this.prisma.$transaction(async (tx) => {
      // Scoped by hand: $executeRaw bypasses the tenant-isolation extension, so
      // without the venueId predicate a manager could take a row lock on another
      // venue's request. Nothing leaks (the scoped findUnique below 404s), but
      // the lock itself should never cross tenants.
      await tx.$executeRaw`SELECT 1 FROM "StaffRequest" WHERE "id" = ${id} AND "venueId" = ${scope.venueId} FOR UPDATE`;
      const request = await tx.staffRequest.findUnique({ where: { id } });
      if (!request) throw new NotFoundException('Request not found');
      if (request.venueId !== scope.venueId) {
        throw new ForbiddenException('Request does not belong to this venue');
      }
      if (request.status !== 'pending') {
        throw new BadRequestException('Only pending requests can be reviewed');
      }
      if (body.status === 'approved' && request.kind === 'time_correction' && request.profileId === scope.profileId) {
        throw new ForbiddenException('A second manager must approve your own time correction.');
      }

      const reviewer = await tx.profile.findUniqueOrThrow({ where: { id: scope.profileId } });

      // Handle approval side-effects
      if (body.status === 'approved') {
        if (request.kind === 'sick_leave') {
          const hours = calculateRequestHours(request.requestedRangeStart || request.requestedForDate, request.requestedRangeEnd || request.requestedForDate);
          // venueId included even though request.profileId is already confirmed
          // scoped above ($executeRaw bypasses the tenant-isolation extension,
          // so this predicate is the only backstop this write has).
          await tx.$executeRaw`
            UPDATE "Profile"
            SET "sickHoursAccrued" = GREATEST(0, "sickHoursAccrued" - ${hours})
            WHERE id = ${request.profileId} AND "venueId" = ${scope.venueId}`;
        } else if (request.kind === 'time_off') {
          const hours = calculateRequestHours(request.requestedRangeStart || request.requestedForDate, request.requestedRangeEnd || request.requestedForDate);
          await tx.$executeRaw`
            UPDATE "Profile"
            SET "ptoHoursAccrued" = GREATEST(0, "ptoHoursAccrued" - ${hours})
            WHERE id = ${request.profileId} AND "venueId" = ${scope.venueId}`;
        }
        
        if ((request.kind === 'time_off' || request.kind === 'sick_leave') && tx.scheduleShift?.findMany) {
          const unavailableStart = request.requestedRangeStart || request.requestedForDate;
          const unavailableEnd = request.requestedRangeEnd || request.requestedForDate || unavailableStart;
          if (unavailableStart && unavailableEnd) {
            // Previously fetched every shift ever assigned to this profile at
            // this venue, unfiltered by date, then filtered in JS — on
            // Prisma's 5s transaction default, while this transaction still
            // holds a FOR UPDATE lock on the StaffRequest row. dayIndex 0-6
            // means a shift's actual date can fall up to 6 days after its
            // weekStart, so widen the lower bound by 6 days to stay correct;
            // this is the exact range the composite
            // [venueId, profileId, weekStart, dayIndex] index was built for.
            const assignedShifts = await tx.scheduleShift.findMany({
              where: {
                venueId: request.venueId,
                profileId: request.profileId,
                weekStart: { gte: addDays(weekStartFor(unavailableStart), -6), lte: unavailableEnd },
              },
              select: { id: true, weekStart: true, dayIndex: true, startMinutes: true, endMinutes: true },
            });
            const affectedIds = assignedShifts
              .filter((shift) => {
                if (!shift.weekStart) return false;
                return occupiedSlots(shift).some((slot) => {
                  if (!slot.weekStart) return false;
                  const date = new Date(`${slot.weekStart}T00:00:00.000Z`);
                  date.setUTCDate(date.getUTCDate() + slot.dayIndex);
                  const iso = date.toISOString().slice(0, 10);
                  return iso >= unavailableStart && iso <= unavailableEnd;
                });
              })
              .map((shift) => shift.id);
            if (affectedIds.length > 0) {
              await tx.scheduleShift.updateMany({
                where: { id: { in: affectedIds } },
                data: { profileId: null, status: 'open' },
              });
            }
          }
        }

        if (request.kind === 'time_correction') {
          const correction = (request.availability as any) || {};
          const venue = await tx.venue.findUnique({
            where: { id: request.venueId },
            select: { timezone: true },
          });
          const correctedClockIn = new Date(correction.clockInAt);
          if (isNaN(correctedClockIn.getTime())) {
            throw new BadRequestException('Invalid correction clock-in time');
          }
          const correctedClockOut = correction.clockOutAt ? new Date(correction.clockOutAt) : null;
          if (correction.clockOutAt && (!correctedClockOut || isNaN(correctedClockOut.getTime()))) {
            throw new BadRequestException('Invalid correction clock-out time');
          }
          // Regression for VW-03: submission validates clockOutAt > clockInAt
          // (see the time_correction branch above, line ~229), but that only
          // covers the employee's initial request. The manager can edit
          // either field again on the approval screen, and this path never
          // re-checked order before writing.
          if (correctedClockOut && correctedClockOut.getTime() <= correctedClockIn.getTime()) {
            throw new BadRequestException('Clock-out time must be after clock-in time.');
          }
          const willBeOpen = !correctedClockOut;

          const applyCorrection = async (targetId: string) => {
            if (willBeOpen) {
              const otherOpen = await tx.timeEntry.findFirst({
                where: {
                  profileId: request.profileId,
                  venueId: request.venueId,
                  isOpen: true,
                  id: { not: targetId },
                },
                select: { id: true },
              });
              if (otherOpen) {
                throw new BadRequestException(
                  'Cannot leave this correction open — staff already has an open clock-in.',
                );
              }
            }
            if (correctedClockOut) {
              // No database exclusion constraint covers closed punches (see
              // the audit's VW-03/VW-04) — this transaction-scoped check is
              // the only thing stopping a correction from overlapping an
              // adjacent closed entry, which would double-count paid hours.
              const overlapping = await tx.timeEntry.findFirst({
                where: {
                  profileId: request.profileId,
                  venueId: request.venueId,
                  id: { not: targetId },
                  clockOutAt: { not: null, gt: correctedClockIn },
                  clockInAt: { lt: correctedClockOut },
                },
                select: { id: true },
              });
              if (overlapping) {
                throw new BadRequestException(
                  'This correction overlaps another punch on record for this employee.',
                );
              }
            }
            await tx.timeEntry.update({
              where: { id: targetId },
              data: {
                clockInAt: correctedClockIn,
                clockOutAt: correctedClockOut,
                isOpen: willBeOpen,
              },
            });
          };

          if (correction.timeEntryId) {
            const target = await tx.timeEntry.findFirst({
              where: { id: correction.timeEntryId, venueId: request.venueId, profileId: request.profileId },
            });
            if (!target) throw new BadRequestException('Time entry not found for this request');
            await applyCorrection(target.id);
          } else {
            const dayIso = zonedIsoDate(venue?.timezone ?? null, correctedClockIn.getTime());
            const { start: dayStartMs, end: dayEndMs } = zonedDateBounds(
              venue?.timezone ?? null,
              dayIso,
            );
            const existing = await tx.timeEntry.findFirst({
              where: {
                profileId: request.profileId,
                venueId: request.venueId,
                clockInAt: { gte: new Date(dayStartMs), lt: new Date(dayEndMs) },
              },
            });
            if (existing) {
              await applyCorrection(existing.id);
            } else {
              if (willBeOpen) {
                const otherOpen = await tx.timeEntry.findFirst({
                  where: {
                    profileId: request.profileId,
                    venueId: request.venueId,
                    isOpen: true,
                  },
                  select: { id: true },
                });
                if (otherOpen) {
                  throw new BadRequestException(
                    'Cannot create an open correction — staff already has an open clock-in.',
                  );
                }
              }
              // Refuse rather than invent. Defaulting to +8h silently
              // manufactured a full shift of paid time from an employee-supplied
              // request, with nothing on the approval screen telling the manager
              // a duration had been fabricated.
              if (!correctedClockOut) {
                throw new BadRequestException(
                  'This correction has no clock-out time. Ask the employee to resubmit with both times before approving.',
                );
              }
              const overlapping = await tx.timeEntry.findFirst({
                where: {
                  profileId: request.profileId,
                  venueId: request.venueId,
                  clockOutAt: { not: null, gt: correctedClockIn },
                  clockInAt: { lt: correctedClockOut },
                },
                select: { id: true },
              });
              if (overlapping) {
                throw new BadRequestException(
                  'This correction overlaps another punch on record for this employee.',
                );
              }
              await tx.timeEntry.create({
                data: {
                  profileId: request.profileId,
                  venueId: request.venueId,
                  clockInAt: correctedClockIn,
                  clockOutAt: correctedClockOut,
                  clockInLat: null,
                  clockInLng: null,
                  clockInAccuracyM: null,
                  clockInMocked: null,
                  clockOutLat: null,
                  clockOutLng: null,
                  clockOutAccuracyM: null,
                  clockOutMocked: null,
                  isOpen: false,
                },
              });
            }
          }
        }
      }

      const updated = await tx.staffRequest.update({
        where: { id: request.id },
        data: {
          status: body.status as RequestStatus,
          reviewerId: scope.profileId,
          reviewedAt: new Date(),
          responseNotes: body.responseNotes,
        },
      });
      return { request, reviewer, updated };
    });
    const { request, reviewer, updated } = result;

    await this.notifications.notifyProfile({
      venueId: scope.venueId,
      profileId: request.profileId,
      kind: 'request_reviewed',
      title: `Request ${body.status}`,
      body:
        body.responseNotes?.trim() ||
        `${reviewer.fullName} marked your ${request.kind.replace('_', ' ')} request ${body.status}.`,
    });
    const kindLabel = request.kind.replace('_', ' ').replace(/\b\w/g, (c) => c.toUpperCase());
    const statusText = body.status.charAt(0).toUpperCase() + body.status.slice(1);
    const noteText = body.responseNotes?.trim();

    void this.email.sendToProfile(
      request.profileId,
      staffRequestDecidedTemplate({
        kindLabel,
        approved: body.status === 'approved',
        title: request.title,
        reviewerName: reviewer.fullName,
        note: noteText,
      }),
    );

    return mapStaffRequest(updated);
  }
}

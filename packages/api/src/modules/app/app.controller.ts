import { BadRequestException, Body, ConflictException, Controller, Delete, ForbiddenException, Get, Header, HttpException, HttpStatus, Logger, NotFoundException, Optional, Param, Patch, Post, Query, Req, UnauthorizedException, UseGuards } from '@nestjs/common';
import { IsBoolean, IsEmail, IsIn, IsNumber, IsOptional, IsString, Max, MaxLength, Min } from 'class-validator';
import { Prisma, ReservationStatus, Role } from '@prisma/client';
import { randomBytes, randomInt } from 'crypto';
import type { Request } from 'express';
import { AuthGuard } from '../../auth/auth.guard';
import { Public } from '../../auth/public.decorator';
import { CurrentUser } from '../../auth/current-user.decorator';
import type { AuthUser } from '../../auth/auth.guard';
import { canManageVenue, isAdminRole, isOwnerOrAdminRole } from '../../auth/roles';
import { RequireSubscription } from '../../billing/require-subscription.decorator';
import { assertCoverageCapacity, COVERED_SUBSCRIPTION_DATA, effectiveSubscriptionStatus, isMultiVenuePlan } from '../../billing/billing-coverage';
import { closeOpenBreaks, parseTimeBreaks, unpaidBreakMs } from '../../common/break-duration';
import { csvCell, csvDocument } from '../../common/csv';
import { getClientIp } from '../../common/http';
import { hashInviteToken } from '../../common/invite-token';
import { assertWithinSharedRateLimit } from '../../common/rate-limit';
import { sanitizeForEmail } from '../../common/sanitize-email-text';
import { buildClockAlerts, clockAlertShiftWindow } from '../../common/clock-alerts';
import { todayInZone, weekStartFor } from '../../common/pay-period';
import { isIanaTimeZone, zonedDateBounds, zonedDayBounds } from '../../common/venue-time';
import { EmailService } from '../../email/email.service';
import { PrismaService } from '../../prisma/prisma.service';
import { runWithoutTenant } from '../../prisma/tenant-context';
import { mapClockEntry, mapProfile, mapShift, mapVenue, toMs } from './app-mappers';
import { ProfileService } from './profile.service';
import { isActiveMembership } from '../../common/membership';
import { syncTeamMemberCount } from '../../common/team-sync';
import { MediaCleanupService } from '../media-cleanup/media-cleanup.service';
import { endBreakForProfile, startBreakForProfile } from '../time-clock/break-transitions';
import { Audited } from '../audit/audited.decorator';

const TRIAL_DURATION_MS = 14 * 24 * 60 * 60 * 1000;

function parseVenueTimeZone(value: string | undefined): string | undefined {
  if (value == null || value.trim() === '') return undefined;
  const timezone = value.trim();
  if (!isIanaTimeZone(timezone)) {
    throw new BadRequestException('timezone must be a valid IANA time zone');
  }
  return timezone;
}
const STAFF_RANGES = ['1-15', '16-30', '31-50'] as const;
const FLAT_PLAN_ID = 'venueflow_monthly';
const FLAT_PLAN_PRICE_CENTS = 9999;
const MULTI_VENUE_PLAN_ID = 'venueflow_multi_venue_5';
const MULTI_VENUE_PRICE_CENTS = 39900;
const MULTI_VENUE_MAX_VENUES = 5;
const PUBLIC_INVITE_RATE_LIMIT_MAX = 20;
const PUBLIC_INVITE_GLOBAL_RATE_LIMIT_MAX = 500;
const PUBLIC_INVITE_RATE_LIMIT_WINDOW_MS = 15 * 60 * 1000;

// Human-typeable invite codes. Excludes look-alike characters (0/O, 1/I/L) so
// codes read aloud or written down don't get mistyped. Format: VW-XXXXXXXX.
const INVITE_CODE_ALPHABET = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
function makeHumanCode(length: number): string {
  let body = '';
  for (let i = 0; i < length; i += 1) {
    body += INVITE_CODE_ALPHABET[randomInt(INVITE_CODE_ALPHABET.length)];
  }
  return `VW-${body}`;
}

function makeInviteCode(): string {
  // 8 chars from a 31-symbol alphabet is ~39.6 bits of entropy — 6 chars
  // (~29.7 bits) was guessable enough that a distributed attacker guessing
  // across the pool of currently-outstanding invites (rather than one code)
  // was a real, if rate-limited, concern. Lookup is unique-indexed exact
  // match, so this only affects newly-generated codes — existing 6-char
  // invites keep working.
  return makeHumanCode(8);
}

function makeVenueCode(): string {
  // Ten characters from a 30-character alphabet provides roughly 49 bits of
  // entropy while remaining practical to read or type.
  return makeHumanCode(10);
}

class BootstrapProfileDto {
  @IsString()
  @IsOptional()
  @MaxLength(120)
  fullName?: string;

  @IsString()
  @IsOptional()
  @MaxLength(100)
  jobTitle?: string;
}

class RegisterVenueDto {
  @IsString()
  @MaxLength(200)
  businessName!: string;

  @IsString()
  @IsOptional()
  @MaxLength(120)
  ownerName?: string;

  @IsString()
  @IsOptional()
  @MaxLength(50)
  phone?: string;

  @IsString()
  @IsOptional()
  @MaxLength(255)
  address?: string;

  @IsString()
  @IsOptional()
  @MaxLength(100)
  venueType?: string;

  @IsString()
  @MaxLength(50)
  staffRange!: string;

  @IsNumber()
  @Min(-90)
  @Max(90)
  @IsOptional()
  latitude?: number;

  @IsNumber()
  @Min(-180)
  @Max(180)
  @IsOptional()
  longitude?: number;

  @IsString()
  @IsOptional()
  @MaxLength(100)
  timezone?: string;
}

class UpdateVenueDto {
  @IsString()
  @IsOptional()
  @MaxLength(200)
  name?: string;

  @IsNumber()
  @Min(-90)
  @Max(90)
  @IsOptional()
  latitude?: number;

  @IsNumber()
  @Min(-180)
  @Max(180)
  @IsOptional()
  longitude?: number;

  @IsNumber()
  @Min(25)
  @IsOptional()
  geofenceRadiusM?: number;

  @IsString()
  @IsOptional()
  @MaxLength(100)
  timezone?: string;
}

class BreakStartDto {
  @IsString()
  @IsIn(['paid', 'unpaid'])
  type!: 'paid' | 'unpaid';
}

class VenueRoleDto {
  @IsString()
  @MaxLength(100)
  name!: string;
}

class CreateInviteDto {
  @IsEmail()
  @IsOptional()
  @MaxLength(255)
  email?: string;

  @IsIn(['manager', 'staff'])
  role!: 'manager' | 'staff';

  @IsString()
  @IsOptional()
  @MaxLength(100)
  jobTitle?: string;
}

class JoinByCodeDto {
  @IsString()
  @MaxLength(64)
  code!: string;
}

class RedeemInviteDto {
  @IsString()
  @MaxLength(128)
  codeOrToken!: string;
}

class SwitchVenueDto {
  @IsString()
  @MaxLength(64)
  venueId!: string;
}

class DeleteAccountDto {
  @IsBoolean()
  @IsOptional()
  deleteOwnedVenues?: boolean;
}

function planForStaffRange(range: string) {
  void range;
  return { planId: FLAT_PLAN_ID, priceCents: FLAT_PLAN_PRICE_CENTS };
}

const ISO_DATE = /^\d{4}-\d{2}-\d{2}$/;

/**
 * Venue-local [start, end) for an export's selected period. Both dates are
 * inclusive calendar days in the venue's own timezone, so a manager in another
 * timezone gets the venue's days rather than their device's. No dates means no
 * range: the export falls back to its recent-rows behaviour rather than
 * silently returning an arbitrary window.
 */
function resolveExportRange(
  timezone: string | null,
  startDate?: string,
  endDate?: string,
): { start: Date; end: Date } | null {
  if (!startDate && !endDate) return null;
  const startIso = startDate ?? endDate!;
  const endIso = endDate ?? startDate!;
  if (!ISO_DATE.test(startIso) || !ISO_DATE.test(endIso)) {
    throw new BadRequestException('startDate and endDate must be YYYY-MM-DD.');
  }
  if (endIso < startIso) {
    throw new BadRequestException('endDate must not be before startDate.');
  }
  return {
    start: new Date(zonedDateBounds(timezone, startIso).start),
    end: new Date(zonedDateBounds(timezone, endIso).end),
  };
}

@Controller('v1/app')
export class AppController {
  private readonly logger = new Logger(AppController.name);

  constructor(
    private readonly prisma: PrismaService,
    private readonly email: EmailService,
    private readonly profiles: ProfileService,
    @Optional() private readonly mediaCleanup?: MediaCleanupService,
  ) {}

  @UseGuards(AuthGuard)
  @Get('me')
  async getMe(@CurrentUser() user: AuthUser, @Req() req: Request) {
    const requestedVenueId = (req.headers['x-venue-id'] as string | undefined) || user.venueId || undefined;
    let profile = await this.getProfile(user, requestedVenueId);
    if (!profile) {
      profile = await this.prisma.profile.findFirst({
        where: {
          userId: user.sub,
          OR: [{ membershipStatus: null }, { membershipStatus: 'active' }],
        },
        include: { venue: true },
        orderBy: { createdAt: 'asc' },
      });
    }
    if (!profile) return null;
    const emailVerified = await this.isEmailVerified(user.sub);
    const venues = await this.profiles.listUserVenues(user.sub);
    const venueReady = emailVerified && isActiveMembership(profile.membershipStatus);
    return {
      profile: mapProfile(profile, emailVerified),
      venue: venueReady && profile.venue ? mapVenue(profile.venue) : null,
      venues,
    };
  }

  @UseGuards(AuthGuard)
  @Post('switch-venue')
  async switchVenue(@CurrentUser() user: AuthUser, @Body() body: SwitchVenueDto) {
    const venueId = body.venueId;
    if (!venueId) throw new BadRequestException('Venue ID is required');
    const profile = await runWithoutTenant(() => this.profiles.requireVenueProfile(user, venueId));
    if (!profile.venue) throw new ForbiddenException('You do not belong to this venue.');
    const emailVerified = await this.isEmailVerified(user.sub);
    const venues = await this.profiles.listUserVenues(user.sub);
    return {
      profile: mapProfile(profile, emailVerified),
      venue: mapVenue(profile.venue),
      venues,
    };
  }

  @UseGuards(AuthGuard)
  @Post('bootstrap-profile')
  async bootstrapProfile(@CurrentUser() user: AuthUser, @Body() body: BootstrapProfileDto) {
    await this.ensureUser(user);
    const emailVerified = await this.isEmailVerified(user.sub);
    const existingProfile = await this.prisma.profile.findFirst({
      where: { userId: user.sub },
      select: { id: true, email: true },
      orderBy: { createdAt: 'asc' },
    });
    const email = user.email ?? existingProfile?.email ?? `${user.sub}@venuewrangler.local`;
    const fullName = body.fullName?.trim() || user.name || email.split('@')[0] || 'Team Member';
    const profile = existingProfile
      ? await this.prisma.profile.update({
          where: { id: existingProfile.id },
          data: {
            email,
            fullName,
            jobTitle: body.jobTitle ?? 'Staff',
          },
          include: { venue: true },
        })
      : await this.prisma.profile
          .create({
            data: {
              userId: user.sub,
              email,
              fullName,
              role: 'staff',
              jobTitle: body.jobTitle ?? 'Staff',
              trialEndsAt: new Date(Date.now() + TRIAL_DURATION_MS),
            },
            include: { venue: true },
          })
          .catch(async (err) => {
            // findFirst-then-create has no transaction or lock around it, so a
            // double-tap or client retry can race here. Profile_userId_venueless_key
            // (a partial unique index on userId WHERE venueId IS NULL) turns the
            // loser's insert into a P2002 instead of a second venueless row —
            // fetch the row the winner just created instead of failing the request.
            if (err instanceof Prisma.PrismaClientKnownRequestError && err.code === 'P2002') {
              const raced = await this.prisma.profile.findFirst({
                where: { userId: user.sub, venueId: null },
                orderBy: { createdAt: 'asc' },
                include: { venue: true },
              });
              if (raced) return raced;
            }
            throw err;
          });

    const venueName = profile.venue?.name ?? 'your venue';
    void this.email.send({
      to: profile.email,
      subject: 'Your Venue Wrangler Account Was Updated',
      text:
        `Hi ${profile.fullName},\n\n` +
        `Your Venue Wrangler account profile was successfully updated. Here are your current profile details:\n\n` +
        `Updated Profile Details\n` +
        `Detail\tInfo\n` +
        `Name\t${profile.fullName}\n` +
        `Role\t${profile.role}\n` +
        `Job Title\t${profile.jobTitle}\n` +
        (profile.venueId ? `Venue\t${venueName}\n` : '') + '\n' +
        `If you have any questions or did not authorize this, please contact support.\n\n` +
        `Questions? support@venuewrangler.com\n\n` +
        `— The Venue Wrangler Team`,
    });

    const venues = await this.profiles.listUserVenues(user.sub);
    return {
      profile: mapProfile(profile, emailVerified),
      venue: profile.venue ? mapVenue(profile.venue) : null,
      venues,
    };
  }

  @UseGuards(AuthGuard)
  @Post('register-venue')
  async registerVenue(@CurrentUser() user: AuthUser, @Body() body: RegisterVenueDto) {
    await this.ensureUser(user);
    const businessName = body.businessName.trim();
    if (!businessName) throw new BadRequestException('Enter your business name');
    if (!STAFF_RANGES.includes(body.staffRange as (typeof STAFF_RANGES)[number])) throw new BadRequestException('Choose a staff size range');

    if (!(await this.isEmailVerified(user.sub))) {
      throw new ForbiddenException('Verify your email before creating a venue.');
    }
    const latitude = Number.isFinite(body.latitude) ? body.latitude! : 0;
    const longitude = Number.isFinite(body.longitude) ? body.longitude! : 0;
    if (latitude === 0 && longitude === 0) {
      throw new BadRequestException('Set the venue coordinates before creating it. Clock-in cannot run at an unconfigured location.');
    }

    const trialStartedAt = new Date();
    const trialEndsAt = new Date(trialStartedAt.getTime() + TRIAL_DURATION_MS);
    const result = await runWithoutTenant(() => this.prisma.$transaction(async (tx) => {
      // Serialize every registration attempt for this account, regardless of
      // business name, then re-check all cross-venue invariants under the lock.
      await tx.$executeRaw`SELECT pg_advisory_xact_lock(hashtext(${`register-venue:${user.sub}`}))`;

      const memberships = await tx.profile.findMany({
        where: {
          userId: user.sub,
          venueId: { not: null },
          OR: [{ membershipStatus: null }, { membershipStatus: 'active' }],
        },
        select: { venueId: true },
      });
      const venueIds = Array.from(new Set(memberships.map((profile) => profile.venueId).filter((id): id is string => Boolean(id))));
      if (venueIds.length >= MULTI_VENUE_MAX_VENUES) {
        throw new ForbiddenException('You have reached the maximum limit of 5 venues for multi-venue management.');
      }

      const duplicateMembership = await tx.profile.findFirst({
        where: {
          userId: user.sub,
          venue: { name: { equals: businessName, mode: 'insensitive' } },
          OR: [{ membershipStatus: null }, { membershipStatus: 'active' }],
        },
        select: { id: true },
      });
      if (duplicateMembership) {
        throw new ConflictException('You already manage a venue with this name.');
      }

      const isAdditionalVenue = venueIds.length > 0;
      let billingSubscriptionId: string | null = null;
      if (isAdditionalVenue) {
        const hasMultiPlan = await tx.subscription.findFirst({
          where: {
            venueId: { in: venueIds },
            billingSubscriptionId: null,
            venue: { profiles: { some: { userId: user.sub, role: { in: ['owner', 'admin'] }, OR: [{ membershipStatus: null }, { membershipStatus: 'active' }] } } },
            status: { in: ['active', 'trialing'] },
            OR: [
              { planId: MULTI_VENUE_PLAN_ID },
              { priceCents: { gte: MULTI_VENUE_PRICE_CENTS } },
              { planId: { contains: 'multi' } },
            ],
          },
        });
        if (!hasMultiPlan || !isMultiVenuePlan(hasMultiPlan) || !['active', 'trialing'].includes(effectiveSubscriptionStatus(hasMultiPlan))) {
          throw new HttpException(
            {
              statusCode: 402,
              message: 'Registering an additional venue requires a Multi-Venue Pro subscription ($399/month for up to 5 venues).',
              code: 'MULTI_VENUE_REQUIRED',
            },
            HttpStatus.PAYMENT_REQUIRED,
          );
        }
        await tx.$executeRaw`SELECT pg_advisory_xact_lock(hashtext(${`billing:${hasMultiPlan.venueId}`}))`;
        // Re-read under the payer lock in case cancellation raced registration.
        const payer = await tx.subscription.findUnique({ where: { id: hasMultiPlan.id } });
        if (!payer || !isMultiVenuePlan(payer) || !['active', 'trialing'].includes(effectiveSubscriptionStatus(payer))) {
          throw new BadRequestException('The paying subscription is no longer active.');
        }
        await assertCoverageCapacity(tx, payer.id);
        billingSubscriptionId = payer.id;
      }

      const plan = isAdditionalVenue
        ? { planId: MULTI_VENUE_PLAN_ID, priceCents: MULTI_VENUE_PRICE_CENTS }
        : planForStaffRange(body.staffRange);
      const existingProfile = await tx.profile.findFirst({
        where: { userId: user.sub },
        orderBy: { createdAt: 'asc' },
      });

      const venueCode = await this.uniqueVenueCode(tx);
      const venue = await tx.venue.create({
        data: {
          name: businessName,
          code: venueCode,
          latitude,
          longitude,
          geofenceRadiusM: 150,
          // Regression for VW-24: timezone is now required at the database
          // layer (see the schema comment). A caller that omits it — the
          // marketing site now sends one, but this is the backstop for any
          // caller that doesn't — gets UTC rather than a constraint
          // violation, matching the fallback every zonedDateBounds()-style
          // helper already used for a null timezone.
          timezone: parseVenueTimeZone(body.timezone) ?? 'UTC',
          phone: body.phone?.trim() || null,
          address: body.address?.trim() || null,
          venueType: body.venueType?.trim() || null,
          staffRange: body.staffRange,
          subscriptionStatus: 'trialing',
          subscriptionPlatform: null,
        },
      });
      await tx.subscription.create({
        data: {
          venueId: venue.id,
          status: 'trialing',
          platform: null,
          planId: plan.planId,
          priceCents: plan.priceCents,
          currency: 'USD',
          trialStartedAt,
          trialEndsAt,
          cancelAtPeriodEnd: false,
          ...(billingSubscriptionId ? { ...COVERED_SUBSCRIPTION_DATA, billingSubscriptionId } : {}),
        },
      });
      const profile = await tx.profile.create({
        data: {
          userId: user.sub,
          email: user.email ?? existingProfile?.email ?? `${user.sub}@venuewrangler.local`,
          fullName: body.ownerName?.trim() || existingProfile?.fullName || user.name || 'Owner',
          role: 'admin',
          jobTitle: 'Owner',
          venueId: venue.id,
          trialEndsAt,
        },
      });
      // Signup creates a venueless profile before any venue exists. Once this
      // venue's profile is created, that older venueless row is a redundant
      // duplicate — left in place it can outrank the real venue profile in
      // fallback profile lookups (see profile.service.ts / auth.guard.ts) and
      // silently disable tenant-scoped queries for this user. Only ever remove
      // the caller's own still-venueless row, never another user's profile.
      if (existingProfile && existingProfile.venueId == null && existingProfile.userId === user.sub) {
        await tx.profile.delete({ where: { id: existingProfile.id } });
      }
      await syncTeamMemberCount(tx, venue.id);
      return { profile, venue };
    }));

    const venues = await this.profiles.listUserVenues(user.sub);
    return { profile: mapProfile(result.profile, true), venue: mapVenue(result.venue), venues };
  }

  @UseGuards(AuthGuard)
  @RequireSubscription()
  @Get('venue/join-code')
  async getVenueJoinCode(@CurrentUser() user: AuthUser) {
    const profile = await this.requireManagerProfile(user);
    return { code: profile.venue!.code };
  }

  @UseGuards(AuthGuard)
  @RequireSubscription()
  @Audited('join_code.rotate', { entityType: 'venue', summary: 'Rotated venue join code' })
  @Post('venue/join-code/rotate')
  async rotateVenueJoinCode(@CurrentUser() user: AuthUser) {
    const profile = await this.requireManagerProfile(user);
    const code = await this.uniqueVenueCode(this.prisma);
    await this.prisma.venue.update({ where: { id: profile.venueId! }, data: { code } });
    return { code };
  }

  @UseGuards(AuthGuard)
  @Patch('venue')
  async updateVenue(@CurrentUser() user: AuthUser, @Body() body: UpdateVenueDto) {
    const profile = await this.requireManagerProfile(user);
    if (!profile.venueId) return { venue: null };
    const nextLat = body.latitude ?? profile.venue?.latitude;
    const nextLng = body.longitude ?? profile.venue?.longitude;
    if (body.latitude !== undefined || body.longitude !== undefined) {
      if (nextLat === 0 && nextLng === 0) {
        throw new BadRequestException('Venue coordinates cannot be 0,0. Use a real location for the time-clock geofence.');
      }
    }
    // timezone can no longer be null (VW-24), so an empty/whitespace value is
    // treated as "no change" rather than "clear it" — there is no unset
    // state to clear it to anymore.
    const nextTimezone = parseVenueTimeZone(body.timezone);
    const venue = await this.prisma.venue.update({
      where: { id: profile.venueId },
      data: {
        ...(body.name?.trim() ? { name: body.name.trim() } : {}),
        ...(body.latitude !== undefined ? { latitude: body.latitude } : {}),
        ...(body.longitude !== undefined ? { longitude: body.longitude } : {}),
        ...(body.geofenceRadiusM !== undefined ? { geofenceRadiusM: Math.max(25, Math.min(2000, body.geofenceRadiusM)) } : {}),
        ...(nextTimezone ? { timezone: nextTimezone } : {}),
      },
    });
    return mapVenue(venue);
  }

  @UseGuards(AuthGuard)
  @RequireSubscription()
  @Get('dashboard')
  async getDashboard(@CurrentUser() user: AuthUser) {
    const profile = await this.requireVenueProfile(user);
    if (!profile?.venue) return null;
    const canManage = canManageVenue(profile.role, profile.allAccess);
    const weekStart = weekStartFor(todayInZone(profile.venue.timezone));
    const shiftWhere = {
      venueId: profile.venueId!,
      weekStart,
      ...(canManage ? {} : { OR: [{ profileId: profile.id }, { status: 'open' as const }] }),
    };
    // Counts come from aggregates over all matching rows; the display list is
    // capped separately so analytics stay correct past the display limit.
    const [shifts, shiftCounts, teamCount, activeEntries, openClockCount] = await Promise.all([
      this.prisma.scheduleShift.findMany({
        where: shiftWhere,
        include: { profile: true },
        orderBy: [{ dayIndex: 'asc' }, { startMinutes: 'asc' }],
        take: 14,
      }),
      this.prisma.scheduleShift.groupBy({ by: ['status'], where: shiftWhere, _count: { _all: true } }),
      canManage ? this.prisma.profile.count({ where: { venueId: profile.venueId! } }) : Promise.resolve(0),
      canManage
        ? this.prisma.timeEntry.findMany({
            where: {
              venueId: profile.venueId!,
              isOpen: true,
              profile: { OR: [{ membershipStatus: null }, { membershipStatus: 'active' }] },
            },
            include: { profile: true, venue: true },
            take: 50,
          })
        : Promise.resolve([]),
      canManage
        ? this.prisma.timeEntry.count({
            where: {
              venueId: profile.venueId!,
              isOpen: true,
              profile: { OR: [{ membershipStatus: null }, { membershipStatus: 'active' }] },
            },
          })
        : Promise.resolve(0),
    ]);
    const countByStatus = (status: string) => shiftCounts.find((c) => c.status === status)?._count._all ?? 0;

    const emailVerified = await this.isEmailVerified(user.sub);
    return {
      profile: mapProfile(profile, emailVerified),
      venue: mapVenue(profile.venue),
      analytics: {
        teamCount,
        scheduledCount: countByStatus('scheduled'),
        openShiftCount: countByStatus('open'),
        coveredShiftCount: countByStatus('covered'),
        openClockCount,
        clockedInCount: openClockCount,
      },
      schedule: shifts.map((shift) => mapShift(shift, canManage ? shift.profile?.fullName ?? null : shift.profileId === profile.id ? 'You' : null)),
      activeClockEntries: activeEntries.map((entry) => mapClockEntry(entry, entry.profile, entry.venue)),
    };
  }

  @UseGuards(AuthGuard)
  @RequireSubscription()
  @Get('manager-insights')
  async getManagerInsights(@CurrentUser() user: AuthUser) {
    const profile = await this.requireVenueProfile(user);
    if (!profile?.venueId || !canManageVenue(profile.role, profile.allAccess)) return null;
    const venueId = profile.venueId;
    const timezone = profile.venue?.timezone ?? null;
    const weekStart = weekStartFor(todayInZone(timezone));
    const now = Date.now();
    const weekAgo = new Date(now - 7 * 24 * 60 * 60 * 1000);
    const nowDate = new Date(now);
    const in24h = new Date(now + 24 * 60 * 60 * 1000);
    // A reservation that is cancelled or a no-show is not "active" for any
    // operational purpose, so both counts exclude them.
    const liveReservation = {
      venueId,
      status: { notIn: [ReservationStatus.cancelled, ReservationStatus.no_show] },
    };
    const [
      completedEntries,
      scheduledShifts,
      openShifts,
      pendingRequests,
      openEntries,
      alertShifts,
      activeReservations,
      upcomingReservations,
    ] = await Promise.all([
      this.prisma.timeEntry.findMany({
        where: { venueId, isOpen: false, clockOutAt: { gte: weekAgo } },
        select: { clockInAt: true, clockOutAt: true },
      }),
      this.prisma.scheduleShift.count({ where: { venueId, weekStart, status: 'scheduled' } }),
      this.prisma.scheduleShift.count({ where: { venueId, weekStart, status: 'open' } }),
      this.prisma.staffRequest.count({ where: { venueId, status: 'pending' } }),
      this.prisma.timeEntry.findMany({
        where: { venueId, isOpen: true },
        select: { isOpen: true, clockInAt: true, profileId: true, profile: { select: { id: true, fullName: true } } },
      }),
      this.prisma.scheduleShift.findMany({
        where: { venueId, OR: clockAlertShiftWindow(timezone, now).where },
        include: { profile: true },
      }),
      this.prisma.reservation.count({ where: { ...liveReservation, reservationTime: { gte: nowDate } } }),
      this.prisma.reservation.count({
        where: { ...liveReservation, reservationTime: { gte: nowDate, lt: in24h } },
      }),
    ]);
    const laborMs = completedEntries.reduce((sum, e) => sum + (e.clockOutAt!.getTime() - e.clockInAt.getTime()), 0);
    const laborHours = Math.round((laborMs / 3600000) * 10) / 10;
    // Same rule the manager clock board renders, so the tile and the board
    // can never disagree.
    const lateOrMissedAlerts = buildClockAlerts({
      timezone,
      nowMs: now,
      shifts: alertShifts,
      entries: openEntries,
    }).length;
    return {
      laborHours,
      scheduledShifts,
      openShifts,
      activeClocks: openEntries.length,
      lateOrMissedAlerts,
      activeReservations,
      upcomingReservations,
      pendingRequests,
      // Retained under its original name: existing clients read `openRequests`,
      // and dropping it here would break them the way the missing fields broke
      // the Reports screen.
      openRequests: pendingRequests,
    };
  }

  @UseGuards(AuthGuard)
  @Audited('time_entries.export', { entityType: 'time_clock', summary: 'Exported time entries CSV' })
  @Get('time-entries/csv')
  @Header('Content-Type', 'text/csv; charset=utf-8')
  @Header('Content-Disposition', 'attachment; filename="time-entries.csv"')
  async exportTimeEntriesCsv(
    @CurrentUser() user: AuthUser,
    @Query('startDate') startDate?: string,
    @Query('endDate') endDate?: string,
  ) {
    const profile = await this.requireManagerProfile(user);
    const venueId = profile.venueId!;
    // The export ignored the period the manager had selected and returned the
    // most recent 1000 punches whatever the screen said, so a chosen range and
    // the file that came back could describe different weeks.
    const venue = await this.prisma.venue.findUnique({ where: { id: venueId }, select: { timezone: true } });
    const timezone = venue?.timezone ?? null;
    const range = resolveExportRange(timezone, startDate, endDate);
    const entries = await this.prisma.timeEntry.findMany({
      where: {
        venueId,
        ...(range ? { clockInAt: { gte: range.start, lt: range.end } } : {}),
      },
      include: { profile: true },
      orderBy: { clockInAt: 'desc' },
      take: 5000,
    });
    const header = 'id,memberId,memberName,clockInAt,clockOutAt,unpaidBreakHours,hoursWorked\n';
    const rows = entries
      .map((e) => {
        // Unpaid breaks were never deducted here, so this export disagreed with
        // payroll — which does deduct them — for the same punches.
        const unpaidMs = parseTimeBreaks(e.breaks)
          .filter((b) => b.type === 'unpaid')
          .reduce((sum, b) => sum + unpaidBreakMs(b.startAt, b.endAt), 0);
        const unpaidHours = Math.round((unpaidMs / 3600000) * 100) / 100;
        const hours = e.clockOutAt
          ? Math.round((Math.max(0, e.clockOutAt.getTime() - e.clockInAt.getTime() - unpaidMs) / 3600000) * 100) / 100
          : '';
        return [
          csvCell(e.id),
          csvCell(e.profileId ?? ''),
          csvCell(e.profile?.fullName ?? e.profileFullName ?? 'Former staff'),
          csvCell(e.clockInAt.toISOString()),
          csvCell(e.clockOutAt?.toISOString() ?? ''),
          csvCell(unpaidHours),
          csvCell(hours),
        ].join(',');
      })
      .join('\r\n');
    // csvDocument supplies the UTF-8 BOM and trailing CRLF; `header`
    // carries its own trailing newline, so emit it as its own row.
    return csvDocument([header.replace(/\r?\n$/, ''), rows]);
  }

  @UseGuards(AuthGuard)
  @RequireSubscription()
  @Get('notifications')
  async getNotifications(@CurrentUser() user: AuthUser, @Query('limit') limitQuery?: string) {
    const profile = await this.requireVenueProfile(user);
    // The list was hard-capped at 20 with no way to reach anything older, so an
    // unread notification past the newest 20 could not be read at all. The cap
    // stays (this is a list, not an archive) but the caller can now ask for
    // more, which is what the Load more control does.
    const requested = Number(limitQuery);
    const limit = Number.isFinite(requested) ? Math.min(Math.max(1, Math.floor(requested)), 200) : 20;
    const rows = await this.prisma.notificationEvent.findMany({
      where: {
        venueId: profile.venueId!,
        OR: [
          { audience: 'staff' },
          ...(canManageVenue(profile.role, profile.allAccess) ? [{ audience: 'managers' }] : []),
          { audience: 'profile', profileId: profile.id },
        ],
      },
      orderBy: { createdAt: 'desc' },
      take: limit,
    });
    const reads = await this.prisma.notificationRead.findMany({
      where: { profileId: profile.id, notificationId: { in: rows.map((row) => row.id) } },
    });
    const readIds = new Set(reads.map((read) => read.notificationId));
    return rows.map((row) => ({
      _id: row.id,
      kind: row.kind,
      title: row.title,
      body: row.body,
      createdAt: row.createdAt.getTime(),
      read: readIds.has(row.id),
    }));
  }

  @UseGuards(AuthGuard)
  @Post('notifications/:id/read')
  async markNotificationRead(@CurrentUser() user: AuthUser, @Param('id') notificationId: string) {
    const profile = await this.getProfile(user);
    if (!profile?.venueId) throw new ForbiddenException('Profile is not initialized');
    const row = await this.prisma.notificationEvent.findFirst({ where: { id: notificationId, venueId: profile.venueId } });
    if (!row) throw new NotFoundException('Notification not found');
    const canRead = row.audience === 'staff' || (row.audience === 'managers' && canManageVenue(profile.role, profile.allAccess)) || (row.audience === 'profile' && row.profileId === profile.id);
    if (!canRead) throw new ForbiddenException('Not authorized');
    await this.prisma.notificationRead.upsert({
      where: { notificationId_profileId: { notificationId, profileId: profile.id } },
      update: { readAt: new Date() },
      create: { notificationId, profileId: profile.id, venueId: profile.venueId },
    });
    return { ok: true };
  }

  @UseGuards(AuthGuard)
  @RequireSubscription()
  @Header('Deprecation', 'true')
  @Get('clock-board')
  async getClockBoard(@CurrentUser() user: AuthUser) {
    const profile = await this.requireVenueProfile(user);
    const entries = await this.prisma.timeEntry.findMany({
      where: {
        venueId: profile.venueId!,
        isOpen: true,
        profile: { OR: [{ membershipStatus: null }, { membershipStatus: 'active' }] },
      },
      include: { profile: true, venue: true },
      orderBy: { clockInAt: 'desc' },
      take: 100,
    });
    const openEntries = entries.map((entry) => mapClockEntry(entry, entry.profile, entry.venue));
    return {
      venue: mapVenue(profile.venue!),
      activeClockEntries: canManageVenue(profile.role, profile.allAccess) ? openEntries : [],
      employeeEntry: openEntries.find((entry) => entry.memberId === profile.id) ?? null,
      managerAlerts: [],
    };
  }

  @UseGuards(AuthGuard)
  @RequireSubscription()
  @Header('Deprecation', 'true')
  @Get('time-clock')
  async getMyTimeClock(@CurrentUser() user: AuthUser) {
    const profile = await this.requireVenueProfile(user);
    const entries = await this.prisma.timeEntry.findMany({
      where: { profileId: profile.id },
      orderBy: { clockInAt: 'desc' },
      take: 100,
    });
    const open = entries.find((entry) => entry.isOpen) ?? null;
    const todayStart = new Date(zonedDayBounds(profile.venue?.timezone ?? null, 0).start);
    const weekAgo = Date.now() - 7 * 24 * 60 * 60 * 1000;
    const punches = entries
      .flatMap((entry) => [
        ...(entry.clockInAt >= todayStart ? [{ type: 'in' as const, at: entry.clockInAt.getTime() }] : []),
        ...(entry.clockOutAt && entry.clockOutAt >= todayStart ? [{ type: 'out' as const, at: entry.clockOutAt.getTime() }] : []),
      ])
      .sort((a, b) => a.at - b.at);
    const regularHours = entries.reduce((sum, entry) => {
      if (!entry.clockOutAt || entry.clockOutAt.getTime() < weekAgo) return sum;
      let durationMs = entry.clockOutAt.getTime() - entry.clockInAt.getTime();
      const breaks = (entry.breaks as any[]) || [];
      for (const b of breaks) {
        if (b.type === 'unpaid' && b.startAt && b.endAt) {
          durationMs -= unpaidBreakMs(b.startAt, b.endAt);
        }
      }
      return sum + Math.max(0, durationMs) / 3600000;
    }, 0);
    const rounded = Math.round(regularHours * 10) / 10;
    return {
      isClockedIn: Boolean(open),
      openSince: toMs(open?.clockInAt),
      regularHours: rounded,
      sickHours: profile.sickHoursAccrued,
      ptoHours: profile.ptoHoursAccrued,
      totalHours: rounded,
      punches,
    };
  }

  @UseGuards(AuthGuard)
  @RequireSubscription()
  @Header('Deprecation', 'true')
  @Post('time-clock/break-start')
  async startBreak(@CurrentUser() user: AuthUser, @Body() body: BreakStartDto) {
    const profile = await this.requireVenueProfile(user);
    const updated = await startBreakForProfile(this.prisma, profile.id, body.type);
    return mapClockEntry(updated, updated.profile, updated.venue);
  }

  @UseGuards(AuthGuard)
  @RequireSubscription()
  @Header('Deprecation', 'true')
  @Post('time-clock/break-end')
  async endBreak(@CurrentUser() user: AuthUser) {
    const profile = await this.requireVenueProfile(user);
    const updated = await endBreakForProfile(this.prisma, profile.id);
    return mapClockEntry(updated, updated.profile, updated.venue);
  }

  @UseGuards(AuthGuard)
  @Get('venue-roles')
  async listVenueRoles(@CurrentUser() user: AuthUser) {
    const profile = await this.requireManagerProfile(user);
    const roles = await this.prisma.venueRole.findMany({
      where: { venueId: profile.venueId! },
      orderBy: { name: 'asc' },
    });
    return roles.map((role) => ({ _id: role.id, id: role.id, name: role.name }));
  }

  @UseGuards(AuthGuard)
  @Post('venue-roles')
  async addVenueRole(@CurrentUser() user: AuthUser, @Body() body: VenueRoleDto) {
    const profile = await this.requireManagerProfile(user);
    const name = body.name.trim();
    if (!name) throw new BadRequestException('Enter a role name');
    const existing = await this.prisma.venueRole.findFirst({
      where: { venueId: profile.venueId!, name: { equals: name, mode: 'insensitive' } },
    });
    if (existing) return { _id: existing.id, id: existing.id, name: existing.name };
    try {
      const role = await this.prisma.venueRole.create({
        data: { venueId: profile.venueId!, name },
      });
      return { _id: role.id, id: role.id, name: role.name };
    } catch (error: any) {
      // Regression for VW-28: the check above and this create race under
      // concurrent requests. A case-insensitive unique index now catches
      // what the check alone could not — surface it the same way a
      // legitimate duplicate would look, rather than a raw 500.
      if (error?.code === 'P2002') {
        const race = await this.prisma.venueRole.findFirst({
          where: { venueId: profile.venueId!, name: { equals: name, mode: 'insensitive' } },
        });
        if (race) return { _id: race.id, id: race.id, name: race.name };
      }
      throw error;
    }
  }

  @UseGuards(AuthGuard)
  @Delete('venue-roles/:id')
  async removeVenueRole(@CurrentUser() user: AuthUser, @Param('id') roleId: string) {
    const profile = await this.requireManagerProfile(user);
    const role = await this.prisma.venueRole.findFirst({ where: { id: roleId, venueId: profile.venueId! } });
    if (!role) throw new NotFoundException('Role not found');
    await this.prisma.venueRole.delete({ where: { id: role.id } });
    return { ok: true };
  }

  @UseGuards(AuthGuard)
  @Audited('invite.create', { entityType: 'invite', summary: 'Created team invite' })
  @Post('invites')
  async createInvite(@CurrentUser() user: AuthUser, @Body() body: CreateInviteDto) {
    const profile = await this.requireManagerProfile(user);
    // Only owner, admin, or allAccess profiles may create manager-level invites.
    const canElevate = profile.role === 'owner' || profile.role === 'admin' || profile.allAccess;
    if (body.role === 'manager' && !canElevate) {
      throw new ForbiddenException('Only owners and administrators can invite managers.');
    }
    const inviteRole = body.role === 'manager' ? 'manager' : 'staff';
    const email = body.email?.trim().toLowerCase() || null;
    if (inviteRole === 'manager' && !email) {
      throw new BadRequestException('Manager invites require an email address.');
    }
    // The plaintext token is only ever needed for the instant it's embedded
    // in the deep-link/response/email below — only its hash is persisted
    // (Invite.tokenHash), so a DB dump/backup leak can't yield a usable
    // signup link. Use this local variable everywhere below, never re-read
    // `invite.token` from the DB.
    const token = randomBytes(18).toString('base64url');
    const tokenHash = hashInviteToken(token);
    const code = await this.uniqueInviteCode();
    const invite = await this.prisma.$transaction(async (tx) => {
      if (email) {
        // Regression for VW-25: nothing stopped a manager from creating
        // multiple simultaneous pending invites for the same email at this
        // venue. A fresh invite supersedes any prior unused one for the
        // same address rather than leaving an ambiguous set of valid links
        // (only one of which the recipient should actually use).
        await tx.invite.deleteMany({
          where: { venueId: profile.venueId!, email, usedBy: null },
        });
      }
      return tx.invite.create({
        data: {
          venueId: profile.venueId!,
          email,
          tokenHash,
          code,
          role: inviteRole,
          jobTitle: body.jobTitle?.trim() || 'Team Member',
          createdBy: profile.id,
          expiresAt: new Date(Date.now() + 7 * 24 * 60 * 60 * 1000),
        },
      });
    });
    // Universal Link, not the venuewrangler:// custom scheme it replaced.
    // Mail clients do not linkify an unknown scheme - Gmail's web client and
    // Outlook render it as plain text - so the "tap this link" instruction
    // below was unfollowable for most recipients, and on a device without the
    // app installed a custom-scheme tap fails silently with no store or web
    // fallback. https resolves for everyone: iOS opens the app directly via
    // the AASA at site/.well-known/apple-app-site-association, and anyone
    // else lands on site/join/index.html, which completes the same signup.
    //
    // The token rides in the query rather than the fragment that
    // site/join/index.html prefers, because a fragment never reaches the
    // native app: there is no window.location off the web, so expo-router's
    // useLocalSearchParams is the only channel and it parses the query only.
    // Referrer-Policy: strict-origin-when-cross-origin in site/_headers keeps
    // the query off any cross-origin Referer, and the token is single-use,
    // stored only as a hash, and expires in 7 days.
    const inviteUrl = `https://venuewrangler.com/join?invite=${encodeURIComponent(token)}`;
    const venueName = sanitizeForEmail(profile.venue?.name ?? 'your Venue Wrangler team');
    if (email) {
      void this.email.send({
        to: email,
        subject: `Invitation: Join the Team at ${venueName} on Venue Wrangler`,
        text:
          `Hi there,\n\n` +
          `You have been invited by ${profile.fullName} to join the team at ${venueName} on Venue Wrangler.\n\n` +
          `To accept your invitation and join the venue:\n\n` +
          `1. Open the Venue Wrangler app on your phone and choose "Join a team"\n` +
          `2. Enter the following invite code when prompted:\n\n` +
          `   ${code}\n\n` +
          `Or just tap this link on your phone:\n` +
          `${inviteUrl}\n\n` +
          `Note: This invitation is valid for 7 days.\n\n` +
          `Questions? support@venuewrangler.com\n\n` +
          `— The Venue Wrangler Team`,
      });
    }
    return {
      token,
      code: invite.code,
      inviteUrl,
      expiresAt: invite.expiresAt.getTime(),
    };
  }

  // Public: lets the join screen show which team a code belongs to before the
  // employee creates an account. Role and job title stay private until the
  // invite is redeemed by an authenticated account.
  @Public()
  @Get('invite/:code')
  async previewInvite(@Req() request: Request, @Param('code') rawCode: string) {
    const code = rawCode?.trim();
    if (!code || code.length < 4 || code.length > 64) {
      throw new BadRequestException('Invalid invite code format.');
    }
    await assertWithinSharedRateLimit(
      this.prisma,
      'public-invite:global',
      PUBLIC_INVITE_GLOBAL_RATE_LIMIT_MAX,
      PUBLIC_INVITE_RATE_LIMIT_WINDOW_MS,
    );
    await assertWithinSharedRateLimit(
      this.prisma,
      `public-invite:${getClientIp(request)}`,
      PUBLIC_INVITE_RATE_LIMIT_MAX,
      PUBLIC_INVITE_RATE_LIMIT_WINDOW_MS,
    );
    const invite = await this.findRedeemableInvite({ codeOrToken: code });
    if (!invite) throw new NotFoundException('That invite code is invalid, used, or expired.');
    const venue = await this.prisma.venue.findUnique({ where: { id: invite.venueId }, select: { name: true } });
    return {
      valid: true,
      venueName: venue?.name ?? 'a Venue Wrangler team',
    };
  }

  // Authenticated: lets a solo user (no venue yet) join a team later by code.
  @UseGuards(AuthGuard)
  @Post('join')
  async joinByCode(@Req() request: Request, @CurrentUser() user: AuthUser, @Body() body: JoinByCodeDto) {
    // Codes are short (6-char, ~30-symbol alphabet); without a per-user rate
    // limit an authenticated attacker could brute-force one and join a
    // stranger's venue.
    await assertWithinSharedRateLimit(this.prisma, `join-code:${user.sub}`, PUBLIC_INVITE_RATE_LIMIT_MAX, PUBLIC_INVITE_RATE_LIMIT_WINDOW_MS);
    await assertWithinSharedRateLimit(this.prisma, `join-code:ip:${getClientIp(request)}`, PUBLIC_INVITE_RATE_LIMIT_MAX, PUBLIC_INVITE_RATE_LIMIT_WINDOW_MS);
    const profile = await this.getProfile(user);
    if (!profile) throw new NotFoundException('Profile not found');
    if (profile.venueId) throw new BadRequestException('You are already part of a team.');
    const verifiedEmail = await this.getVerifiedAccountEmail(user.sub);

    const updated = await this.prisma.$transaction(async (tx) => {
      const invite = await this.findRedeemableInvite({ codeOrToken: body.code }, tx);
      if (!invite) throw new BadRequestException('That invite code is invalid, used, or expired.');
      if (invite.email && invite.email.toLowerCase() !== verifiedEmail.toLowerCase()) {
        throw new ForbiddenException('This invite was sent to a different email address.');
      }
      // Atomic single-use claim — the loser of a race sees count 0.
      const claimed = await tx.invite.updateMany({
        where: { id: invite.id, usedBy: null },
        data: { usedBy: profile.id },
      });
      if (claimed.count === 0) throw new BadRequestException('That invite has already been used.');
      const up = await tx.profile.update({
        where: { id: profile.id },
        data: { venueId: invite.venueId, role: invite.role, jobTitle: invite.jobTitle },
        include: { venue: true },
      });
      await syncTeamMemberCount(tx, invite.venueId);
      return up;
    });

    const emailVerified = await this.isEmailVerified(user.sub);
    return {
      profile: mapProfile(updated, emailVerified),
      venue: updated.venue ? mapVenue(updated.venue) : null,
    };
  }

  @UseGuards(AuthGuard)
  @Post('redeem-invite')
  async redeemInvite(@Req() request: Request, @CurrentUser() user: AuthUser, @Body() body: RedeemInviteDto) {
    // Same brute-force concern as /join — this also accepts the short code.
    await assertWithinSharedRateLimit(this.prisma, `redeem-invite:${user.sub}`, PUBLIC_INVITE_RATE_LIMIT_MAX, PUBLIC_INVITE_RATE_LIMIT_WINDOW_MS);
    await assertWithinSharedRateLimit(this.prisma, `redeem-invite:ip:${getClientIp(request)}`, PUBLIC_INVITE_RATE_LIMIT_MAX, PUBLIC_INVITE_RATE_LIMIT_WINDOW_MS);
    return this.redeemInviteForUser(user.sub, { codeOrToken: body.codeOrToken });
  }

  @UseGuards(AuthGuard)
  @Post('redeem-my-invite')
  async redeemMyInvite(@CurrentUser() user: AuthUser) {
    const email = await this.getVerifiedAccountEmail(user.sub);
    // A caller who already belongs to a venue has nothing to redeem. Bail out
    // before the adoption fallback below, which deletes the caller's profile —
    // without this, re-verifying an email would tear an existing member out of
    // their venue (and could orphan a venue whose sole owner they are, routing
    // around the last-admin guard on account deletion). Mirrors the same check
    // in redeemInviteForUser and joinByCode.
    const current = await this.getProfile({ sub: user.sub });
    if (current?.venueId) {
      return {
        redeemed: false,
        profile: mapProfile(current, true),
        venue: current.venue ? mapVenue(current.venue) : null,
      };
    }
    const matches = await this.prisma.invite.findMany({
      where: {
        email: { equals: email, mode: 'insensitive' },
        usedBy: null,
        expiresAt: { gt: new Date() },
      },
      orderBy: { createdAt: 'desc' },
      take: 2,
    });
    if (matches.length === 0) {
      const unclaimedProfile = await this.prisma.profile.findFirst({
        where: {
          userId: null,
          email: { equals: email, mode: 'insensitive' },
          venueId: { not: null },
        },
        // Deterministic pick when a roster carries more than one match, and the
        // same one AuthService.issueSession would adopt on the signup path.
        orderBy: { createdAt: 'asc' },
        include: { venue: true },
      });

      if (!unclaimedProfile) {
        return { redeemed: false };
      }

      const profile = await this.getProfile(user);
      if (!profile) throw new NotFoundException('Profile not found');

      const updated = await this.prisma.$transaction(async (tx) => {
        // Delete temporary profile created on signup
        await tx.profile.delete({
          where: { id: profile.id },
        });

        // Adopt the unclaimed profile, keeping the role the manager set on the
        // roster. Forcing 'staff' here silently demoted anyone added as a
        // manager: the roster said manager, the account that claimed it was
        // staff, and the person landed in a workspace missing the controls
        // they had been told to expect. Owner and admin are not adoptable this
        // way — those roles are granted deliberately, not by claiming a roster
        // row — so they fall back to manager.
        const rosterRole = unclaimedProfile.role;
        const adoptedRole: Role = rosterRole === 'owner' || rosterRole === 'admin' ? 'manager' : rosterRole;
        return tx.profile.update({
          where: { id: unclaimedProfile.id },
          data: {
            userId: user.sub,
            role: adoptedRole,
          },
          include: { venue: true },
        });
      });

      return {
        redeemed: true,
        profile: mapProfile(updated, true),
        venue: updated.venue ? mapVenue(updated.venue) : null,
      };
    }
    if (matches.length > 1) {
      throw new BadRequestException('Multiple pending invites were found for this email. Use the specific invite link from your manager.');
    }
    return this.redeemInviteForUser(user.sub, { id: matches[0].id });
  }

  // Resolve a redeemable invite either by an already-known row id (the caller
  // already looked it up some other way, e.g. by the redeemer's verified
  // email — no plaintext token involved) or by a user-submitted short code /
  // long token (the token is never stored in plaintext, so it's hashed
  // before the lookup).
  private findRedeemableInvite(
    identifier: { id: string } | { codeOrToken: string },
    tx: Prisma.TransactionClient = this.prisma,
  ) {
    if ('id' in identifier) {
      return tx.invite.findFirst({
        where: { id: identifier.id, usedBy: null, expiresAt: { gt: new Date() } },
      });
    }
    const value = identifier.codeOrToken?.trim();
    if (!value) return Promise.resolve(null);
    return tx.invite.findFirst({
      where: {
        OR: [{ code: { equals: value, mode: 'insensitive' } }, { tokenHash: hashInviteToken(value) }],
        usedBy: null,
        expiresAt: { gt: new Date() },
      },
    });
  }

  private async uniqueInviteCode(): Promise<string> {
    for (let attempt = 0; attempt < 6; attempt += 1) {
      const code = makeInviteCode();
      const clash = await this.prisma.invite.findUnique({ where: { code } });
      if (!clash) return code;
    }
    // Astronomically unlikely; widen with a longer suffix as a last resort.
    return `${makeInviteCode()}${randomBytes(2).toString('hex').toUpperCase()}`;
  }

  @UseGuards(AuthGuard)
  @Audited('account.delete', { entityType: 'account', summary: 'Deleted user account' })
  @Delete('me')
  async deleteMyAccount(@CurrentUser() user: AuthUser, @Body() body: DeleteAccountDto = {}) {
    const deletionRunId = randomBytes(16).toString('hex');
    const deletion = await runWithoutTenant(() => this.prisma.$transaction(async (tx) => {
      const [account, profiles] = await Promise.all([
        tx.user.findUnique({ where: { id: user.sub }, select: { email: true } }),
        tx.profile.findMany({
          where: { userId: user.sub },
          select: { id: true, email: true, fullName: true, role: true, venueId: true, membershipStatus: true },
          orderBy: { createdAt: 'asc' },
        }),
      ]);
      if (!account && profiles.length === 0) return null;

      const venueIds = Array.from(new Set(
        profiles.map((profile) => profile.venueId).filter((id): id is string => Boolean(id)),
      )).sort();
      const venuesToDelete: string[] = [];
      for (const venueId of venueIds) {
        await tx.$executeRaw`SELECT pg_advisory_xact_lock(hashtext(${`venue-admin-count:${venueId}`}))`;
      }
      for (const venueId of venueIds) {
        const profile = profiles.find((candidate) => candidate.venueId === venueId);
        const isActive = profile?.membershipStatus == null || profile.membershipStatus === 'active';
        if (!profile || !isActive || !isOwnerOrAdminRole(profile.role)) continue;
        const ownerAdminCount = await tx.profile.count({
          where: { venueId, role: { in: ['owner', 'admin'] }, OR: [{ membershipStatus: null }, { membershipStatus: 'active' }] },
        });
        if (ownerAdminCount <= 1) {
          if (!body.deleteOwnedVenues) {
            throw new ConflictException('Transfer venue ownership or confirm deletion of the owned venue before deleting this account');
          }
          if (profile.role !== 'owner') {
            throw new ForbiddenException('Only a venue owner can delete the venue; transfer ownership before deleting this account');
          }
          venuesToDelete.push(venueId);
        }
      }

      const mediaJobIds: string[] = [];
      if (venuesToDelete.length > 0) {
        const venueList = Prisma.join(venuesToDelete);
        // Child inserts take a foreign-key KEY SHARE lock on Venue. Holding an
        // UPDATE lock closes the gap between snapshotting object/wage rows and
        // cascading the venue, so no newly committed S3 key can be missed.
        await tx.$queryRaw<Array<{ id: string }>>(Prisma.sql`
          SELECT "id" FROM "Venue" WHERE "id" IN (${venueList}) FOR UPDATE
        `);
        // Keep the transaction set-based. The previous implementation pulled
        // every key through Node in 500-row pages, turning tenant erasure into
        // thousands of network round trips while locks remained open. Postgres
        // now deduplicates and shards the durable outbox in one statement.
        const jobs = await tx.$queryRaw<Array<{ id: string }>>(Prisma.sql`
          WITH media_keys AS (
            SELECT "s3Key" AS "objectKey" FROM "ChatImage" WHERE "venueId" IN (${venueList})
            UNION
            SELECT "s3Key" AS "objectKey" FROM "VenueDocument" WHERE "venueId" IN (${venueList})
            UNION
            SELECT "photoKey" AS "objectKey" FROM "ChecklistCompletion"
              WHERE "venueId" IN (${venueList}) AND "photoKey" IS NOT NULL
          ), numbered AS (
            SELECT "objectKey", ((row_number() OVER (ORDER BY "objectKey") - 1) / 500)::integer AS batch
            FROM media_keys
          ), batches AS (
            SELECT batch, array_agg("objectKey" ORDER BY "objectKey") AS "objectKeys"
            FROM numbered GROUP BY batch
          )
          INSERT INTO "ObjectDeletionJob" ("id", "objectKeys", "status", "attempts", "createdAt", "updatedAt")
          SELECT ${`account-delete-${deletionRunId}-`} || batch::text, "objectKeys", 'pending', 0, NOW(), NOW()
          FROM batches
          RETURNING "id"
        `);
        mediaJobIds.push(...jobs.map(({ id }) => id));

        // Archive wage records BEFORE anything cascades. TimeEntry.venue is
        // onDelete: Cascade, so deleting the Venue would otherwise destroy every
        // employee's clock-in history — not just the departing account's. FLSA
        // requires three-year retention, and those other employees are not the
        // data subject here. RetainedTimeEntry carries no Venue FK so it
        // survives the cascade (see its schema comment).
        // Pseudonymize ONLY the departing account's own rows. Blanket-anonymizing
        // every employee at the venue defeated the point of this table: FLSA
        // §516.2 requires the employee's name, so a retained-but-unattributable
        // row carries the storage and privacy cost of retention with none of its
        // compliance value. Co-workers are not the data subject of this erasure.
        const departingProfileIds = profiles.map((profile) => profile.id);
        await tx.$executeRaw(Prisma.sql`
          INSERT INTO "RetainedTimeEntry" (
            "id", "originVenueId", "originVenueName", "profileFullName", "profileEmail",
            "clockInAt", "clockOutAt", "isOpen", "breaks", "originCreatedAt", "retainedAt"
          )
          SELECT
            ${`retained-${deletionRunId}-`} || t."id", t."venueId", v."name",
            CASE WHEN t."profileId" IS NOT NULL AND t."profileId" IN (${Prisma.join(departingProfileIds)})
                 THEN 'deleted_user_' || t."profileId"
                 ELSE t."profileFullName" END,
            CASE WHEN t."profileId" IS NOT NULL AND t."profileId" IN (${Prisma.join(departingProfileIds)})
                 THEN NULL
                 ELSE p."email" END,
            t."clockInAt", t."clockOutAt", t."isOpen", t."breaks", t."createdAt", NOW()
          FROM "TimeEntry" t
          JOIN "Venue" v ON v."id" = t."venueId"
          LEFT JOIN "Profile" p ON p."id" = t."profileId"
          WHERE t."venueId" IN (${venueList})
        `);

        // Profile.venue uses SetNull because profiles can temporarily be
        // venueless during onboarding. Tenant offboarding is different: remove
        // every venue profile explicitly before the Venue cascade.
        await tx.profile.deleteMany({ where: { venueId: { in: venuesToDelete } } });
        await tx.venue.deleteMany({ where: { id: { in: venuesToDelete } } });
      }

      const profileIds = profiles.map((profile) => profile.id);
      if (profileIds.length) {
        await tx.pushToken.deleteMany({ where: { profileId: { in: profileIds } } });
        await tx.availability.deleteMany({ where: { profileId: { in: profileIds } } });
        // Close any still-running punch with a real clock-out BEFORE the
        // de-identification pass below. Flipping isOpen to false while leaving
        // clockOutAt null produces a row every consumer discards — payroll
        // filters on `clockOutAt: { not: null }`, the clock board only lists
        // isOpen entries, and once profileId is SET NULL no correction request
        // can reach it — so the employee's final partial shift silently became
        // unpayable at exactly the moment they left.
        const openEntries = await tx.timeEntry.findMany({
          where: { profileId: { in: profileIds }, clockOutAt: null },
          select: { id: true, breaks: true },
        });
        const clockOutAt = new Date();
        for (const entry of openEntries) {
          await tx.timeEntry.update({
            where: { id: entry.id },
            data: {
              clockOutAt,
              isOpen: false,
              breaks: closeOpenBreaks(entry.breaks, clockOutAt.getTime()),
            },
          });
        }
        for (const profile of profiles) {
          await tx.timeEntry.updateMany({
            where: { profileId: profile.id },
            data: { profileFullName: `deleted_user_${profile.id}`, isOpen: false },
          });
        }
        await tx.scheduleShift.updateMany({ where: { profileId: { in: profileIds } }, data: { profileId: null, status: 'open' } });
      }
      await tx.session.deleteMany({ where: { userId: user.sub } });
      await tx.authAccount.deleteMany({ where: { userId: user.sub } });
      if (profileIds.length) await tx.profile.deleteMany({ where: { id: { in: profileIds } } });
      await tx.user.deleteMany({ where: { id: user.sub } });
      for (const venueId of venueIds.filter((id) => !venuesToDelete.includes(id))) await syncTeamMemberCount(tx, venueId);

      const primary = profiles[0];
      return {
        email: account?.email ?? primary?.email ?? user.email,
        name: primary?.fullName ?? user.name ?? 'there',
        mediaJobIds,
        deletedVenueCount: venuesToDelete.length,
      };
    }, {
      // Set-based archival/outbox insertion leaves only the final atomic erase
      // in this critical section. Keep a bounded allowance for large cascades
      // without permitting a request to hold locks for minutes.
      timeout: 30_000,
      maxWait: 10_000,
    }));
    if (deletion?.mediaJobIds.length && this.mediaCleanup) {
      const mediaCleanup = this.mediaCleanup;
      const jobIds = deletion.mediaJobIds;
      // Bounded and fire-and-forget: a large tenant can shard into hundreds of
      // jobs, and starting them all concurrently from one API instance would
      // spike DB/S3 connections for the whole process. Anything not finished
      // here is still picked up by the hourly retry sweep in
      // media-cleanup.service.ts, so this is a best-effort head start, not the
      // only path to completion.
      const IMMEDIATE_MEDIA_DELETE_CONCURRENCY = 5;
      void (async () => {
        let next = 0;
        const worker = async () => {
          while (next < jobIds.length) {
            const jobId = jobIds[next++];
            await mediaCleanup.processJob(jobId).catch((error) => {
              this.logger.error(`Initial media purge failed for deletion job ${jobId}`, error instanceof Error ? error.stack : String(error));
            });
          }
        };
        await Promise.all(Array.from({ length: Math.min(IMMEDIATE_MEDIA_DELETE_CONCURRENCY, jobIds.length) }, worker));
      })();
    }
    if (deletion?.email) {
      void this.email.send({
        to: deletion.email,
        subject: 'Your Venue Wrangler Account Has Been Deleted',
        text:
          `Hi ${deletion.name},\n\n` +
          `Your Venue Wrangler account has been successfully deleted.\n\n` +
          (deletion.deletedVenueCount > 0
            ? `${deletion.deletedVenueCount} owned venue${deletion.deletedVenueCount === 1 ? '' : 's'} and associated operational data were also deleted. Media deletion is processed by a durable purge queue.\n\n`
            : `Any legally retained timeclock records have been de-identified and remain available to the venue only for wage and compliance purposes.\n\n`) +
          `Thank you for using Venue Wrangler.\n\n` +
          `Questions? support@venuewrangler.com\n\n` +
          `— The Venue Wrangler Team`,
      });
    }
    return { ok: true };
  }

  private async uniqueVenueCode(db: Pick<Prisma.TransactionClient, 'venue'> | PrismaService): Promise<string> {
    for (let attempt = 0; attempt < 6; attempt += 1) {
      const code = makeVenueCode();
      const clash = await db.venue.findUnique({ where: { code }, select: { id: true } });
      if (!clash) return code;
    }
    return `${makeVenueCode()}${randomBytes(2).toString('hex').toUpperCase()}`;
  }

  private ensureUser(user: AuthUser) {
    return this.profiles.ensureUser(user);
  }

  private getProfile(user: AuthUser, venueId?: string | null) {
    return this.profiles.getProfile(user, venueId);
  }

  private requireVenueProfile(user: AuthUser) {
    return this.profiles.requireVenueProfile(user);
  }

  private requireManagerProfile(user: AuthUser) {
    return this.profiles.requireManagerProfile(user);
  }

  private requireBillingProfile(user: AuthUser) {
    return this.profiles.requireBillingProfile(user);
  }



  private getVerifiedAccountEmail(userId: string) {
    return this.profiles.getVerifiedAccountEmail(userId);
  }

  private isEmailVerified(userId: string) {
    return this.profiles.isEmailVerified(userId);
  }

  private async redeemInviteForUser(userId: string, identifier: { id: string } | { codeOrToken: string }) {
    const email = await this.getVerifiedAccountEmail(userId);
    const profile = await this.getProfile({ sub: userId });
    if (!profile) throw new NotFoundException('Profile not found');
    if (profile.venueId) {
      const emailVerified = await this.isEmailVerified(userId);
      return {
        redeemed: false,
        profile: mapProfile(profile, emailVerified),
        venue: profile.venue ? mapVenue(profile.venue) : null,
      };
    }

    const updated = await this.prisma.$transaction(async (tx) => {
      const invite = await this.findRedeemableInvite(identifier, tx);
      if (!invite) throw new BadRequestException('That invite code is invalid, used, or expired.');
      // Email-specific invites: enforce that the redeeming user's verified email
      // matches the invite's target. Link-based invites (no email on the invite)
      // are open to any authenticated user — the short-lived token is the auth.
      if (invite.email && invite.email.toLowerCase() !== email.toLowerCase()) {
        throw new ForbiddenException('This invite was sent to a different email address.');
      }
      const claimed = await tx.invite.updateMany({
        where: { id: invite.id, usedBy: null },
        data: { usedBy: profile.id },
      });
      if (claimed.count === 0) {
        throw new BadRequestException('That invite has already been used.');
      }
      const up = await tx.profile.update({
        where: { id: profile.id },
        data: {
          email,
          venueId: invite.venueId,
          role: invite.role,
          jobTitle: invite.jobTitle,
        },
        include: { venue: true },
      });
      await syncTeamMemberCount(tx, invite.venueId);
      return up;
    });

    return {
      redeemed: true,
      profile: mapProfile(updated, true),
      venue: updated.venue ? mapVenue(updated.venue) : null,
    };
  }

}

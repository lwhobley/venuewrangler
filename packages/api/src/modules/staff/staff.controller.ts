import {
  Body,
  Controller,
  Delete,
  ForbiddenException,
  Get,
  NotFoundException,
  Param,
  Post,
} from '@nestjs/common';
import { ArrayMaxSize, IsArray, IsDateString, IsEmail, IsIn, IsOptional, IsString, MaxLength } from 'class-validator';
import { Prisma, Role } from '@prisma/client';
import { canManageRole, canManageVenue, isOwnerOrAdminRole } from '../../auth/roles';
import { RequireSubscription } from '../../billing/require-subscription.decorator';
import { mapProfile } from '../../common/mappers';
import { EmailService } from '../../email/email.service';
import { PrismaService } from '../../prisma/prisma.service';
import { VenueScope } from '../../venue/venue-scope.decorator';
import type { VenueScopedRequest } from '../../venue/venue-scope.interceptor';
import { syncTeamMemberCount } from '../../common/team-sync';
import { todayInZone, weekStartFor } from '../../common/pay-period';
import { AuditService } from '../audit/audit.service';

type Scope = VenueScopedRequest['venueScope'];

const ROLES = ['admin', 'owner', 'manager', 'server', 'staff'];
const ELEVATED_ROLES = ['admin', 'owner', 'manager'];

class UpsertStaffDto {
  @IsEmail()
  @MaxLength(255)
  email!: string;

  @IsString()
  @MaxLength(120)
  fullName!: string;

  @IsString()
  @IsIn(ROLES)
  role!: string;

  @IsString()
  @MaxLength(100)
  jobTitle!: string;

  @IsOptional()
  @IsString()
  @MaxLength(50)
  phone?: string;

  @IsOptional()
  @IsString()
  @MaxLength(50)
  altPhone?: string;

  @IsOptional()
  @IsString()
  @MaxLength(255)
  address?: string;

  @IsOptional()
  @IsDateString()
  dateOfBirth?: string;

  @IsOptional()
  @IsArray()
  @ArrayMaxSize(50)
  @IsString({ each: true })
  @MaxLength(100, { each: true })
  certifications?: string[];
}

@Controller('v1/staff')
export class StaffController {
  constructor(
    private readonly prisma: PrismaService,
    private readonly email: EmailService,
    private readonly audit: AuditService,
  ) {}

  @RequireSubscription()
  @Get()
  async listVenueStaff(@VenueScope() scope: Scope) {
    if (!scope || !canManageVenue(scope.role, scope.allAccess)) return [];
    const staff = await this.prisma.profile.findMany({
      where: { venueId: scope.venueId, OR: [{ membershipStatus: null }, { membershipStatus: 'active' }] },
    });
    return staff
      .sort((a, b) => a.fullName.localeCompare(b.fullName))
      .map(mapProfile);
  }

  @RequireSubscription()
  @Post()
  async upsertVenueStaff(@VenueScope() scope: Scope, @Body() body: UpsertStaffDto) {
    if (!scope || !canManageVenue(scope.role, scope.allAccess)) {
      throw new ForbiddenException('Not authorized');
    }

    const existing = await this.prisma.profile.findMany({
      where: { venueId: scope.venueId, OR: [{ membershipStatus: null }, { membershipStatus: 'active' }] },
    });
    const member =
      existing.find((item) => item.email.toLowerCase() === body.email.toLowerCase()) ?? null;

    const viewerIsOwnerOrAdmin =
      scope.role === 'owner' || scope.role === 'admin' || scope.allAccess;
    const roleChanged = !member || member.role !== body.role;
    if (!viewerIsOwnerOrAdmin && roleChanged && ELEVATED_ROLES.includes(body.role)) {
      throw new ForbiddenException('Managers cannot assign admin, owner, or manager roles');
    }

    if (member) {
      const isDemoting = isOwnerOrAdminRole(member.role) && !isOwnerOrAdminRole(body.role);
      const updated = await this.prisma.$transaction(async (tx) => {
        await this.assertCanManageTarget(scope, member, isDemoting, tx);
        const u = await tx.profile.update({
          where: { id: member.id },
          data: {
            email: body.email,
            fullName: body.fullName,
            role: body.role as Role,
            jobTitle: body.jobTitle,
            venueId: scope.venueId,
            phone: body.phone ?? member.phone,
            altPhone: body.altPhone ?? member.altPhone,
            address: body.address ?? member.address,
            dateOfBirth: body.dateOfBirth ? new Date(body.dateOfBirth) : member.dateOfBirth,
            certifications: body.certifications ?? member.certifications,
          },
        });
        if (roleChanged && member.userId) {
          await tx.session.deleteMany({ where: { userId: member.userId } });
        }
        await this.audit.record(
          {
            venueId: scope.venueId,
            actorProfileId: scope.profileId,
            actorName: scope.fullName,
            actorRole: scope.role,
            targetProfileId: u.id,
            targetName: u.fullName,
            targetRole: u.role,
            entityType: 'profile',
            entityId: u.id,
            action: 'staff_updated',
            summary: `${scope.fullName} updated ${u.fullName}${member.role !== u.role ? ` from ${member.role} to ${u.role}` : ''}.`,
            metadata: {
              previousRole: member.role,
              nextRole: u.role,
              previousJobTitle: member.jobTitle,
              nextJobTitle: u.jobTitle,
            },
          },
          tx,
        );
        return u;
      });
      void this.email.send({
        to: updated.email,
        subject: 'Your Venue Wrangler Profile Has Been Updated',
        text:
          `Hi ${updated.fullName},\n\n` +
          `Your team profile at ${scope.venueName} has been updated. Here are your current profile details:\n\n` +
          `Updated Profile Details\n` +
          `Detail\tInfo\n` +
          `Name\t${updated.fullName}\n` +
          `Role\t${updated.role}\n` +
          `Job Title\t${updated.jobTitle}\n\n` +
          `If you did not request these changes or have any questions, please contact your venue administrator.\n\n` +
          `Questions? support@venuewrangler.com\n\n` +
          `— The Venue Wrangler Team`,
      });
      return mapProfile(updated);
    }

    const created = await this.prisma.$transaction(async (tx) => {
      const c = await tx.profile.create({
        data: {
          tokenIdentifier: `${body.email.toLowerCase()}:invited:${Date.now()}`,
          email: body.email.toLowerCase(),
          fullName: body.fullName,
          role: body.role as Role,
          jobTitle: body.jobTitle,
          venueId: scope.venueId,
          phone: body.phone?.trim() || null,
          altPhone: body.altPhone?.trim() || null,
          address: body.address?.trim() || null,
          dateOfBirth: body.dateOfBirth ? new Date(body.dateOfBirth) : null,
          certifications: body.certifications ?? [],
        },
      });
      await syncTeamMemberCount(tx, scope.venueId);
      await this.audit.record(
        {
          venueId: scope.venueId,
          actorProfileId: scope.profileId,
          actorName: scope.fullName,
          actorRole: scope.role,
          targetProfileId: c.id,
          targetName: c.fullName,
          targetRole: c.role,
          entityType: 'profile',
          entityId: c.id,
          action: 'staff_created',
          summary: `${scope.fullName} added ${c.fullName} as ${c.role}.`,
          metadata: { role: c.role, jobTitle: c.jobTitle },
        },
        tx,
      );
      return c;
    });
    void this.email.send({
      to: created.email,
      subject: `Invitation: Join the Team at ${scope.venueName} on Venue Wrangler`,
      text:
        `Hi ${created.fullName},\n\n` +
        `Welcome! You have been added to the team at ${scope.venueName} as a ${created.jobTitle}.\n\n` +
        `To view your schedule, request unavailable days, and request shift swaps, please join the venue using the steps below:\n\n` +
        `1. Create a Venue Wrangler account or sign in using your email: ${created.email}\n` +
        `2. You will be automatically linked to the venue and can access your dashboard right away.\n\n` +
        `We're excited to have you on board!\n\n` +
        `Questions? support@venuewrangler.com\n\n` +
        `— The Venue Wrangler Team`,
    });
    return mapProfile(created);
  }

  @RequireSubscription()
  @Delete(':id')
  async deactivateVenueStaff(@VenueScope() scope: Scope, @Param('id') id: string) {
    if (!scope || !canManageVenue(scope.role, scope.allAccess)) {
      throw new ForbiddenException('Not authorized');
    }

    const staff = await this.prisma.profile.findUnique({ where: { id } });
    if (!staff) throw new NotFoundException('Staff member not found');
    if (staff.venueId !== scope.venueId) {
      throw new ForbiddenException('Staff member does not belong to this venue');
    }

    const venue = await this.prisma.venue.findUnique({ where: { id: scope.venueId }, select: { timezone: true } });
    const currentWeekStart = weekStartFor(todayInZone(venue?.timezone ?? null));

    const updated = await this.prisma.$transaction(async (tx) => {
      await this.assertCanManageTarget(scope, staff, true, tx);
      const u = await tx.profile.update({
        where: { id: staff.id },
        data: { membershipStatus: 'revoked' },
      });
      await tx.timeEntry.updateMany({
        where: { profileId: staff.id, isOpen: true },
        data: {
          isOpen: false,
          clockOutAt: new Date(),
        },
      });
      // A revoked employee is no longer expected to show up. Past/current-week
      // shifts stay assigned (they're worked or in-progress, and payroll comes
      // from TimeEntry/PosLaborPunch, not this row), but anything from the
      // current week onward is opened back up so a manager sees the real gap
      // instead of a published schedule that quietly assumes someone who no
      // longer works here.
      await tx.scheduleShift.updateMany({
        where: { venueId: scope.venueId, profileId: staff.id, weekStart: { gte: currentWeekStart } },
        data: { profileId: null, status: 'open' },
      });
      if (staff.userId) {
        const activeElsewhere = await tx.profile.count({
          where: {
            userId: staff.userId,
            venueId: { not: scope.venueId },
            venue: { isNot: null },
            OR: [{ membershipStatus: null }, { membershipStatus: 'active' }],
          },
        });
        if (activeElsewhere === 0) await tx.session.deleteMany({ where: { userId: staff.userId } });
      }
      await syncTeamMemberCount(tx, scope.venueId);
      await this.audit.record(
        {
          venueId: scope.venueId,
          actorProfileId: scope.profileId,
          actorName: scope.fullName,
          actorRole: scope.role,
          targetProfileId: staff.id,
          targetName: staff.fullName,
          targetRole: staff.role,
          entityType: 'profile',
          entityId: staff.id,
          action: 'staff_deactivated',
          summary: `${scope.fullName} deactivated ${staff.fullName}.`,
        },
        tx,
      );
      return u;
    });
    return mapProfile(updated);
  }

  private async assertCanManageTarget(
    scope: NonNullable<Scope>,
    target: { id: string; role: Role; venueId: string | null },
    demotingOrRemoving = false,
    db: Prisma.TransactionClient | PrismaService = this.prisma,
  ) {
    if (target.id !== scope.profileId && !canManageRole(scope.role, target.role, scope.allAccess)) {
      throw new ForbiddenException('You cannot modify this staff member');
    }
    if (demotingOrRemoving && isOwnerOrAdminRole(target.role)) {
      await db.$executeRaw`SELECT pg_advisory_xact_lock(hashtext(${`venue-admin-count:${scope.venueId}`}))`;
        // Revoked profiles keep their venueId (deactivateVenueStaff only flips
        // membershipStatus), so counting them inflated this guard and let the
        // last ACTIVE owner be removed — leaving the venue with nobody who can
        // manage it and no API path to recover. Matches app.controller.ts's
        // account-deletion guard.
      const ownerAdminCount = await db.profile.count({
        where: {
          venueId: scope.venueId,
          role: { in: ['owner', 'admin'] },
          OR: [{ membershipStatus: null }, { membershipStatus: 'active' }],
        },
      });
      if (ownerAdminCount <= 1) {
        throw new ForbiddenException('You cannot remove the last owner or admin from the venue');
      }
    }
  }
}

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
  Post,
  Query,
  Req,
} from '@nestjs/common';
import { IsOptional, IsString, MaxLength } from 'class-validator';
import { ConfigService } from '@nestjs/config';
import { createHash, randomBytes } from 'crypto';
import type { Request } from 'express';
import { Public } from '../../auth/public.decorator';
import { CurrentUser } from '../../auth/current-user.decorator';
import type { AuthUser } from '../../auth/auth.guard';
import { canManageVenue } from '../../auth/roles';
import { getClientIp } from '../../common/http';
import { hashInviteToken } from '../../common/invite-token';
import { assertWithinSharedRateLimit } from '../../common/rate-limit';
import { publicWebOrigin } from '../../common/public-web-url';
import { sanitizeForEmail } from '../../common/sanitize-email-text';
import { EmailService } from '../../email/email.service';
import { inviteCheckEmailTemplate, joinRequestDecidedTemplate } from '../../email/templates/workforce';
import { PrismaService } from '../../prisma/prisma.service';
import { SkipVenueScope } from '../../venue/skip-venue-scope.decorator';

const INVITE_CHECK_LIMIT_MAX = 10;
const INVITE_CHECK_LIMIT_WINDOW_MS = 5 * 60 * 1000;
const INVITE_EMAIL_LIMIT_MAX = 3;
const INVITE_EMAIL_LIMIT_WINDOW_MS = 15 * 60 * 1000;
const JOIN_REQUEST_LIMIT_MAX = 5;
const JOIN_REQUEST_LIMIT_WINDOW_MS = 15 * 60 * 1000;
const APPROVE_LIMIT_MAX = 60;
const APPROVE_LIMIT_WINDOW_MS = 15 * 60 * 1000;

function normalisedPhone(raw: string): string {
  return raw.replace(/[\s\-().+]/g, '');
}

class InviteCheckDto {
  @IsString()
  @IsOptional()
  @MaxLength(255)
  email?: string;

  @IsString()
  @IsOptional()
  @MaxLength(50)
  phone?: string;
}

class JoinRequestDto {
  @IsString()
  @MaxLength(64)
  venueId!: string;

  @IsString()
  @MaxLength(32)
  code!: string;
}

class ReviewDecisionDto {
  @IsString()
  @IsOptional()
  @MaxLength(500)
  note?: string;
}

// Intentionally class-level, not per-method. A repo-wide audit flagged this
// as "every handler skips tenant isolation" and recommended narrowing it to
// only the public invite-check route — doing that would break every other
// handler here: AuthGuard has already bound a single-venue tenant context
// from the X-Venue-Id header by the time this controller runs (see
// VenueScopeInterceptor's own comment on SKIP_VENUE_SCOPE_KEY), and a manager
// who administers more than one venue needs listManagerJoinRequests/
// getJoinRequestDetail/approve/reject to see and act on requests across ALL
// of their venues, not just whichever one happens to be "active" in the
// header. Every handler below instead does its own explicit venueId
// predicate (see listManagerJoinRequests computing venueIds from the
// caller's own manager profiles, and getJoinRequestDetail's actorProfile
// check) — that manual scoping is the actual isolation boundary here, not
// the Prisma tenant extension. Keep it that way: a new handler added to this
// controller must add its own explicit venueId check, the extension will not
// do it automatically.
@SkipVenueScope()
@Controller('v1/workforce')
export class WorkforceController {
  private readonly logger = new Logger(WorkforceController.name);

  constructor(
    private readonly prisma: PrismaService,
    private readonly email: EmailService,
    private readonly config: ConfigService,
  ) {}

  // ─── Public: invite check ──────────────────────────────────────────────────

  @Public()
  @Post('invite-check')
  async inviteCheck(@Req() req: Request, @Body() body: InviteCheckDto) {
    await assertWithinSharedRateLimit(this.prisma, `invite-check:ip:${getClientIp(req)}`, INVITE_CHECK_LIMIT_MAX, INVITE_CHECK_LIMIT_WINDOW_MS);

    const email = body.email?.trim().toLowerCase();
    const phone = body.phone ? normalisedPhone(body.phone) : undefined;

    if (!email && !phone) {
      throw new BadRequestException('Provide an email address or mobile number.');
    }
    const contactHash = createHash('sha256').update(email ?? phone!).digest('hex');
    await assertWithinSharedRateLimit(
      this.prisma,
      `invite-check:contact:${contactHash}`,
      INVITE_EMAIL_LIMIT_MAX,
      INVITE_EMAIL_LIMIT_WINDOW_MS,
    );

    // Never reveal whether a phone number exists in an invite or roster. The
    // public response is deliberately identical for every valid contact.
    if (!email) {
      return { status: 'ok' as const };
    }

    // The plaintext token is only needed when minting a new invite. Existing
    // links remain valid: rotating their hash here would let anyone who knows
    // an address invalidate that address's emailed link.
    const freshToken = randomBytes(18).toString('base64url');
    const tokenHash = hashInviteToken(freshToken);
    const newExpiresAt = new Date(Date.now() + 7 * 24 * 60 * 60 * 1000);

    const outcome = await this.prisma.$transaction(async (tx) => {
      await tx.$executeRaw`SELECT pg_advisory_xact_lock(hashtext(${`invite-check:${email}`}))`;

      const redeemable = await tx.invite.findFirst({
        where: { email: { equals: email, mode: 'insensitive' }, usedBy: null, expiresAt: { gt: new Date() } },
        include: { venue: { select: { name: true } } },
        orderBy: { createdAt: 'desc' },
      });

      if (redeemable) {
        return { venueName: redeemable.venue.name, jobTitle: redeemable.jobTitle, emailSent: false } as const;
      }

      const unclaimedProfile = await tx.profile.findFirst({
        where: { userId: null, venueId: { not: null }, email: { equals: email, mode: 'insensitive' } },
        include: { venue: { select: { name: true } } },
        orderBy: { createdAt: 'desc' },
      });
      if (!unclaimedProfile || !unclaimedProfile.venue) {
        return null;
      }

      // Regression for VW-25: the `redeemable` check above only excludes
      // an UNEXPIRED prior invite. An old expired-but-still-unused invite
      // for this exact (venue, email) pair would otherwise collide with the
      // new one-pending-invite-per-venue-per-email database constraint.
      await tx.invite.deleteMany({
        where: { venueId: unclaimedProfile.venueId!, email, usedBy: null },
      });

      const created = await tx.invite.create({
        data: {
          venueId: unclaimedProfile.venueId!,
          email,
          tokenHash,
          role: unclaimedProfile.role,
          jobTitle: unclaimedProfile.jobTitle,
          createdBy: unclaimedProfile.id,
          expiresAt: newExpiresAt,
        },
        include: { venue: { select: { name: true } } },
      });
      return { venueName: created.venue.name, jobTitle: created.jobTitle, emailSent: true } as const;
    });

    if (!outcome) return { status: 'ok' as const };

    const appUrl = publicWebOrigin(this.config);
    // A URL fragment (not a query string) so the token never reaches
    // server/CDN access logs — fragments aren't sent in the HTTP request at
    // all. site/join/index.html reads from the fragment first.
    const signupUrl = `${appUrl}/join#invite=${encodeURIComponent(freshToken)}`;
    const venueName = sanitizeForEmail(outcome.venueName);
    // Fire-and-forget so delivery timing and provider failures cannot turn the
    // otherwise uniform public response into an account-enumeration signal.
    void this.email
      .sendOrThrow({
        to: email,
        ...inviteCheckEmailTemplate({
          venueName,
          jobTitle: outcome.jobTitle,
          signupUrl,
          expiresAt: newExpiresAt.toLocaleDateString('en-US'),
          isNewInvite: outcome.emailSent,
        }),
      })
      .catch((err: unknown) => {
        this.logger.error(`Invite-check email failed for a venue invite: ${err instanceof Error ? err.message : String(err)}`);
      });
    return { status: 'ok' as const };
  }

  // ─── Public: venue search ──────────────────────────────────────────────────

  @Get('venues/search')
  async searchVenues(@Req() req: Request, @Query('q') q: unknown) {
    await assertWithinSharedRateLimit(this.prisma, `venue-search:ip:${getClientIp(req)}`, INVITE_CHECK_LIMIT_MAX, INVITE_CHECK_LIMIT_WINDOW_MS);

    if (q !== undefined && typeof q !== 'string') {
      throw new BadRequestException('Search query must be a string.');
    }
    const term = (q ?? '').trim();
    if (term.length > 120) {
      throw new BadRequestException('Search query must be 120 characters or fewer.');
    }
    if (!term) {
      return { venues: [] };
    }

    const venues = await this.prisma.venue.findMany({
      where: { code: { equals: term, mode: 'insensitive' } },
      select: { id: true, name: true },
      take: 1,
    });
    return { venues: venues.map((venue) => ({ id: venue.id, name: venue.name, address: null })) };
  }

  // ─── Authenticated: user's own join requests ───────────────────────────────

  @Get('join-requests')
  async listMyJoinRequests(@CurrentUser() user: AuthUser) {
    const requests = await this.prisma.workplaceJoinRequest.findMany({
      where: { userId: user.sub },
      include: { venue: { select: { id: true, name: true, address: true } } },
      orderBy: { createdAt: 'desc' },
    });
    return {
      requests: requests.map((r) => ({
        id: r.id,
        venueId: r.venueId,
        venueName: r.venue.name,
        venueAddress: r.venue.address,
        status: r.status,
        decidedAt: r.decidedAt?.getTime() ?? null,
        decisionNote: r.decisionNote ?? null,
        createdAt: r.createdAt.getTime(),
      })),
    };
  }

  @Post('join-request')
  async submitJoinRequest(@Req() req: Request, @CurrentUser() user: AuthUser, @Body() body: JoinRequestDto) {
    await assertWithinSharedRateLimit(this.prisma, `join-request:user:${user.sub}`, JOIN_REQUEST_LIMIT_MAX, JOIN_REQUEST_LIMIT_WINDOW_MS);
    await assertWithinSharedRateLimit(this.prisma, `join-request:ip:${getClientIp(req)}`, JOIN_REQUEST_LIMIT_MAX, JOIN_REQUEST_LIMIT_WINDOW_MS);

    // Every other membership-granting path (registerVenue, joinByCode, invite
    // redemption) requires a verified email first. Without this, someone could
    // register an address they don't control, never verify it, and be approved
    // into a venue — and the approving manager sees only the raw email, with
    // nothing indicating it was never proven.
    const account = await this.prisma.user.findUnique({
      where: { id: user.sub },
      select: { emailVerifiedAt: true },
    });
    if (!account?.emailVerifiedAt) {
      throw new ForbiddenException('Verify your email address before requesting to join a workplace.');
    }

    const venue = await this.prisma.venue.findUnique({
      where: { id: body.venueId },
      select: { id: true, name: true, code: true },
    });
    if (!venue) throw new NotFoundException('Workplace not found.');

    // Require the correct venue code to prevent enumeration-based join spam.
    if (!venue.code || venue.code.toLowerCase() !== body.code.trim().toLowerCase()) {
      throw new BadRequestException('Incorrect venue code.');
    }

    let requestId: string;
    try {
      const rows = await this.prisma.$queryRaw<[{ requestId: string }]>`
        SELECT request_join_workplace(${user.sub}, ${body.venueId}) AS "requestId"
      `;
      requestId = rows[0]?.requestId;
      if (!requestId) throw new Error('join_request_id_missing');
    } catch (err: any) {
      const msg: string = err?.message ?? '';
      if (msg.includes('already_member')) {
        throw new BadRequestException('You are already a member of this workplace.');
      }
      if (msg.includes('duplicate_pending_request')) {
        throw new BadRequestException('You already have a pending request to join this workplace.');
      }
      throw err;
    }

    return {
      requestId,
      status: 'pending',
      venueName: venue.name,
    };
  }

  @Delete('join-request/:id')
  async cancelJoinRequest(@CurrentUser() user: AuthUser, @Param('id') id: string) {
    try {
      await this.prisma.$queryRaw`SELECT cancel_join_request(${id}, ${user.sub})`;
    } catch (err: any) {
      const msg: string = err?.message ?? '';
      if (msg.includes('request_not_found')) throw new NotFoundException('Join request not found.');
      if (msg.includes('not_authorized')) throw new ForbiddenException('Not your join request.');
      if (msg.includes('request_not_pending')) throw new BadRequestException('Request is no longer pending.');
      throw err;
    }
    return { ok: true };
  }

  // ─── Manager: review join requests ────────────────────────────────────────

  @Get('manager/join-requests')
  async listManagerJoinRequests(@CurrentUser() user: AuthUser) {
    // Find all venues where this user can manage staff — role-based manager,
    // or a support/all-access profile that canManageVenue also recognizes.
    // Filtering in JS (rather than a role list baked into the query) keeps
    // this in sync with canManageVenue instead of drifting from it.
    const myProfiles = await this.prisma.profile.findMany({
      where: {
        userId: user.sub,
        venueId: { not: null },
        OR: [{ membershipStatus: null }, { membershipStatus: 'active' }],
      },
      select: { venueId: true, role: true, allAccess: true },
    });
    const venueIds = myProfiles
      .filter((p) => canManageVenue(p.role, p.allAccess))
      .map((p) => p.venueId)
      .filter(Boolean) as string[];
    if (!venueIds.length) return { requests: [] };

    const requests = await this.prisma.workplaceJoinRequest.findMany({
      where: { venueId: { in: venueIds }, status: 'pending' },
      include: {
        venue: { select: { id: true, name: true } },
        user: {
          select: {
            id: true,
            email: true,
            profiles: {
              select: { fullName: true },
              orderBy: { createdAt: 'asc' },
              take: 1,
            },
          },
        },
      },
      orderBy: { createdAt: 'asc' },
    });

    return {
      requests: requests.map((r) => ({
        id: r.id,
        venueId: r.venueId,
        venueName: r.venue.name,
        userId: r.userId,
        userName: r.user.profiles?.[0]?.fullName ?? null,
        userEmail: r.user.email ?? null,
        status: r.status,
        createdAt: r.createdAt.getTime(),
      })),
    };
  }

  @Post('manager/join-request/:id/approve')
  async approveJoinRequest(
    @Req() req: Request,
    @CurrentUser() user: AuthUser,
    @Param('id') id: string,
  ) {
    await assertWithinSharedRateLimit(this.prisma, `approve:user:${user.sub}`, APPROVE_LIMIT_MAX, APPROVE_LIMIT_WINDOW_MS);
    await assertWithinSharedRateLimit(this.prisma, `approve:ip:${getClientIp(req)}`, APPROVE_LIMIT_MAX, APPROVE_LIMIT_WINDOW_MS);

    try {
      await this.prisma.$queryRaw`SELECT approve_join_request(${id}, ${user.sub})`;
    } catch (err: any) {
      const msg: string = err?.message ?? '';
      if (msg.includes('request_not_found')) throw new NotFoundException('Join request not found.');
      if (msg.includes('request_not_pending')) throw new BadRequestException('Request is no longer pending.');
      if (msg.includes('not_authorized')) throw new ForbiddenException('You are not authorized to approve requests for this workplace.');
      if (msg.includes('email_not_verified')) {
        throw new BadRequestException('This person has not verified their email address yet, so they cannot be added to the workplace.');
      }
      if (msg.includes('already_member')) throw new BadRequestException('This person already belongs to a workplace.');
      throw err;
    }
    void this.emailJoinRequestDecision(id, 'approved');
    return { ok: true };
  }

  @Post('manager/join-request/:id/reject')
  async rejectJoinRequest(
    @Req() req: Request,
    @CurrentUser() user: AuthUser,
    @Param('id') id: string,
    @Body() body: ReviewDecisionDto,
  ) {
    await assertWithinSharedRateLimit(this.prisma, `approve:user:${user.sub}`, APPROVE_LIMIT_MAX, APPROVE_LIMIT_WINDOW_MS);
    await assertWithinSharedRateLimit(this.prisma, `approve:ip:${getClientIp(req)}`, APPROVE_LIMIT_MAX, APPROVE_LIMIT_WINDOW_MS);

    const note = body.note?.trim() ?? null;
    try {
      await this.prisma.$queryRaw`SELECT reject_join_request(${id}, ${user.sub}, ${note})`;
    } catch (err: any) {
      const msg: string = err?.message ?? '';
      if (msg.includes('request_not_found')) throw new NotFoundException('Join request not found.');
      if (msg.includes('request_not_pending')) throw new BadRequestException('Request is no longer pending.');
      if (msg.includes('not_authorized')) throw new ForbiddenException('You are not authorized to reject requests for this workplace.');
      throw err;
    }
    void this.emailJoinRequestDecision(id, 'rejected', note);
    return { ok: true };
  }

  // ─── Manager: join request detail ─────────────────────────────────────────

  @Get('manager/join-request/:id')
  async getJoinRequestDetail(@CurrentUser() user: AuthUser, @Param('id') id: string) {
    const request = await this.prisma.workplaceJoinRequest.findUnique({
      where: { id },
      include: {
        venue: { select: { id: true, name: true } },
        user: {
          select: {
            id: true,
            email: true,
            profiles: {
              select: { fullName: true },
              orderBy: { createdAt: 'asc' },
              take: 1,
            },
          },
        },
        events: { orderBy: { createdAt: 'asc' } },
      },
    });
    if (!request) throw new NotFoundException('Join request not found.');

    // Verify actor can manage this venue (role-based manager, or all-access).
    const actorProfile = await this.prisma.profile.findFirst({
      where: {
        userId: user.sub,
        venueId: request.venueId,
        OR: [{ membershipStatus: null }, { membershipStatus: 'active' }],
      },
    });
    if (!actorProfile || !canManageVenue(actorProfile.role, actorProfile.allAccess)) {
      // 404, not 403: a 403 here would tell a caller "this request id exists,
      // just not at a venue you manage" — a cross-tenant existence oracle.
      // Same shape a manager gets for an id that doesn't exist at all.
      throw new NotFoundException('Join request not found.');
    }

    return {
      id: request.id,
      venueId: request.venueId,
      venueName: request.venue.name,
      userId: request.userId,
      userName: request.user.profiles?.[0]?.fullName ?? null,
      userEmail: request.user.email ?? null,
      status: request.status,
      decidedAt: request.decidedAt?.getTime() ?? null,
      decisionNote: request.decisionNote ?? null,
      createdAt: request.createdAt.getTime(),
      events: request.events.map((e) => ({
        id: e.id,
        eventType: e.eventType,
        actorId: e.actorId ?? null,
        payload: e.payload,
        createdAt: e.createdAt.getTime(),
      })),
    };
  }

  private emailJoinRequestDecision(id: string, decision: 'approved' | 'rejected', note?: string | null) {
    void this.emailJoinRequestDecisionInBackground(id, decision, note).catch((error) => {
      this.logger.error(
        `Join-request decision email failed: ${error instanceof Error ? error.message : String(error)}`,
        error instanceof Error ? error.stack : undefined,
      );
    });
  }

  private async emailJoinRequestDecisionInBackground(id: string, decision: 'approved' | 'rejected', note?: string | null) {
    const request = await this.prisma.workplaceJoinRequest.findUnique({
      where: { id },
      include: {
        venue: { select: { name: true } },
        user: {
          select: {
            email: true,
            profiles: {
              select: { fullName: true },
              orderBy: { createdAt: 'asc' },
              take: 1,
            },
          },
        },
      },
    });
    if (!request) return;
    const to = request.user.email;
    if (!to) return;
    const name = request.user.profiles?.[0]?.fullName ?? 'there';
    void this.email.send({
      to,
      ...joinRequestDecidedTemplate({ fullName: name, venueName: request.venue.name, approved: decision === 'approved', note }),
    });
  }

}

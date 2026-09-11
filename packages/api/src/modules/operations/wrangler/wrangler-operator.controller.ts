import { Body, Controller, ForbiddenException, Post } from '@nestjs/common';
import { IsObject, IsOptional, IsString, MaxLength, MinLength } from 'class-validator';
import { canManageVenue } from '../../../auth/roles';
import { RequireSubscription } from '../../../billing/require-subscription.decorator';
import { VenueScope } from '../../../venue/venue-scope.decorator';
import type { VenueScopedRequest } from '../../../venue/venue-scope.interceptor';
import { PrismaService } from '../../../prisma/prisma.service';
import { assertWithinSharedRateLimit } from '../../../common/rate-limit';
import { WranglerOperatorService } from './wrangler-operator.service';

type Scope = VenueScopedRequest['venueScope'];
const OPERATOR_RATE_LIMIT_MAX = 20;
const OPERATOR_RATE_LIMIT_WINDOW_MS = 60_000;

class WranglerOperatorPlanDto {
  @IsString()
  @MinLength(2)
  @MaxLength(1000)
  command!: string;
}

class WranglerOperatorExecuteDto {
  @IsObject()
  plan!: Record<string, unknown>;

  // Optional today so older clients keep working unchanged. When the client
  // generates one per user action and resends the same value on a retried
  // execute() call, write tools that support idempotency (currently
  // UPDATE_BAR_STOCK) can dedupe the retry instead of double-applying it.
  @IsOptional()
  @IsString()
  @MaxLength(200)
  requestId?: string;
}

@Controller('v1/operations/wrangler/operator')
export class WranglerOperatorController {
  constructor(
    private readonly prisma: PrismaService,
    private readonly operator: WranglerOperatorService,
  ) {}

  @RequireSubscription('active')
  @Post('plan')
  async plan(@VenueScope() scope: Scope, @Body() body: WranglerOperatorPlanDto) {
    if (!scope) throw new ForbiddenException('No active venue profile found');
    if (!canManageVenue(scope.role, scope.allAccess)) {
      throw new ForbiddenException('Manager access required for Wrangler operator actions');
    }
    await assertWithinSharedRateLimit(
      this.prisma,
      `wrangler-operator:${scope.venueId}:${scope.profileId}`,
      OPERATOR_RATE_LIMIT_MAX,
      OPERATOR_RATE_LIMIT_WINDOW_MS,
    );
    const venue = await this.prisma.venue.findUnique({ where: { id: scope.venueId }, select: { timezone: true } });
    if (!venue) return null;
    return this.operator.plan({
      venueId: scope.venueId,
      timezone: venue.timezone,
      command: body.command,
      actor: { profileId: scope.profileId, fullName: scope.fullName, role: scope.role, allAccess: scope.allAccess },
    });
  }

  @RequireSubscription('active')
  @Post('execute')
  async execute(@VenueScope() scope: Scope, @Body() body: WranglerOperatorExecuteDto) {
    if (!scope) throw new ForbiddenException('No active venue profile found');
    if (!canManageVenue(scope.role, scope.allAccess)) {
      throw new ForbiddenException('Manager access required for Wrangler operator actions');
    }
    // Same bucket as /plan: execute accepts a client-supplied plan and performs
    // the actual writes, so it must not be throttled more loosely than the
    // cheaper planning call that normally precedes it.
    await assertWithinSharedRateLimit(
      this.prisma,
      `wrangler-operator:${scope.venueId}:${scope.profileId}`,
      OPERATOR_RATE_LIMIT_MAX,
      OPERATOR_RATE_LIMIT_WINDOW_MS,
    );
    const venue = await this.prisma.venue.findUnique({ where: { id: scope.venueId }, select: { timezone: true } });
    if (!venue) return null;
    const plan = body.plan as any;
    return this.operator.execute({
      venueId: scope.venueId,
      timezone: venue.timezone,
      actor: { profileId: scope.profileId, fullName: scope.fullName, role: scope.role, allAccess: scope.allAccess },
      plan,
      requestId: body.requestId,
    });
  }
}

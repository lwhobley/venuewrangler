import { Body, ConflictException, Controller, ForbiddenException, Post } from '@nestjs/common';
import { IsIn, IsString, MaxLength } from 'class-validator';
import { PrismaService } from '../prisma/prisma.service';
import { VenueScope } from '../venue/venue-scope.decorator';
import type { VenueScopedRequest } from '../venue/venue-scope.interceptor';

type Scope = VenueScopedRequest['venueScope'];

const PUSH_PLATFORMS = ['ios', 'android', 'web'] as const;

class RegisterPushTokenDto {
  @IsString()
  @MaxLength(500)
  token!: string;

  @IsIn(PUSH_PLATFORMS)
  platform!: (typeof PUSH_PLATFORMS)[number];
}

@Controller('v1/push')
export class PushController {
  constructor(private readonly prisma: PrismaService) {}

  @Post('token')
  async registerPushToken(@VenueScope() scope: Scope, @Body() body: RegisterPushTokenDto) {
    if (!scope) throw new ForbiddenException('No venue profile found');

    const { token, platform } = body;
    const data = {
      platform,
      venueId: scope.venueId,
      profileId: scope.profileId,
      enabled: true,
      lastSeenAt: new Date(),
    };

    const pushToken = await this.prisma.$transaction(async (tx) => {
      // Serialize registration by (venue, token) so the same pair cannot be
      // rebound to a different profile during a concurrent request. A token
      // may legitimately hold separate rows across venues (a staff member's
      // device registered at more than one workplace) — that is not a
      // conflict, only a second profile claiming the same token *within the
      // same venue* is.
      await tx.$executeRaw`SELECT pg_advisory_xact_lock(hashtext(${`push-token:${scope.venueId}:${token}`}))`;
      const existing = await tx.pushToken.findUnique({ where: { venueId_token: { venueId: scope.venueId, token } } });
      if (existing && existing.profileId !== scope.profileId) {
        throw new ConflictException('This device token is already registered to another profile at this venue.');
      }
      return tx.pushToken.upsert({
        where: { venueId_token: { venueId: scope.venueId, token } },
        create: { ...data, token },
        update: data,
      });
    });

    return { id: pushToken.id, ok: true };
  }
}

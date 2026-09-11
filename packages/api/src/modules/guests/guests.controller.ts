import {
  BadRequestException,
  Body,
  Controller,
  Delete,
  ForbiddenException,
  Get,
  Headers,
  NotFoundException,
  Param,
  Post,
  Query,
  Req,
  UnauthorizedException,
} from '@nestjs/common';
import { ArrayMaxSize, IsArray, IsBoolean, IsOptional, IsString, MaxLength, ValidateNested } from 'class-validator';
import { Type } from 'class-transformer';
import type { Request } from 'express';
import { createHash } from 'crypto';
import { canManageVenue } from '../../auth/roles';
import { Public } from '../../auth/public.decorator';
import { RequireSubscription } from '../../billing/require-subscription.decorator';
import { getClientIp } from '../../common/http';
import { assertWithinSharedRateLimit } from '../../common/rate-limit';
import { generateWebhookSecret, secretsMatch } from '../../common/webhook-auth';
import { PrismaService } from '../../prisma/prisma.service';
import { VenueScope } from '../../venue/venue-scope.decorator';
import type { VenueScopedRequest } from '../../venue/venue-scope.interceptor';
import { Audited } from '../audit/audited.decorator';

type Scope = VenueScopedRequest['venueScope'];
const LEADS_WEBHOOK_RATE_LIMIT_MAX = 120;
const LEADS_WEBHOOK_RATE_LIMIT_WINDOW_MS = 60_000;
const LEADS_WEBHOOK_TIMESTAMP_TOLERANCE_MS = 5 * 60_000;
const LEADS_WEBHOOK_EVENT_TTL_MS = 24 * 60 * 60_000;

export function validateLeadWebhookReplayHeaders(
  eventId: string | undefined,
  timestamp: string | undefined,
  now = Date.now(),
): string {
  const normalizedEventId = eventId?.trim();
  if (!normalizedEventId || normalizedEventId.length > 200 || !/^[A-Za-z0-9._:-]+$/.test(normalizedEventId)) {
    throw new BadRequestException('A valid x-webhook-id header is required.');
  }
  const timestampSeconds = Number(timestamp);
  if (!Number.isFinite(timestampSeconds)) {
    throw new BadRequestException('A valid x-webhook-timestamp header is required.');
  }
  const timestampMs = timestampSeconds * 1000;
  if (Math.abs(now - timestampMs) > LEADS_WEBHOOK_TIMESTAMP_TOLERANCE_MS) {
    throw new UnauthorizedException('Webhook timestamp is outside the allowed window.');
  }
  return normalizedEventId;
}

/**
 * Applied to a lead that shares a name with an existing guest but carries no
 * matching email or phone. The importer creates a separate record and leaves
 * the merge decision to a human.
 */
export const POSSIBLE_DUPLICATE_TAG = 'possible-duplicate';

class UpsertGuestDto {
  @IsString()
  @IsOptional()
  @MaxLength(64)
  guestId?: string;

  @IsString()
  @MaxLength(200)
  fullName!: string;

  @IsString()
  @IsOptional()
  @MaxLength(50)
  phone?: string;

  @IsString()
  @IsOptional()
  @MaxLength(255)
  email?: string;

  @IsString()
  @IsOptional()
  @MaxLength(50)
  lifecycleStage?: string;

  @IsString()
  @IsOptional()
  @MaxLength(100)
  source?: string;

  @IsString()
  @IsOptional()
  @MaxLength(32)
  birthday?: string;

  @IsString()
  @IsOptional()
  @MaxLength(200)
  company?: string;

  @IsBoolean()
  @IsOptional()
  marketingOptIn?: boolean;

  @IsString()
  @IsOptional()
  @MaxLength(50)
  favoriteTable?: string;

  @IsString()
  @IsOptional()
  @MaxLength(200)
  preferredServer?: string;

  @IsString()
  @IsOptional()
  @MaxLength(1000)
  dietaryNotes?: string;

  @IsArray()
  @ArrayMaxSize(50)
  @IsString({ each: true })
  @MaxLength(50, { each: true })
  @IsOptional()
  tags?: string[];

  @IsString()
  @IsOptional()
  @MaxLength(2000)
  notes?: string;
}

class LeadDto {
  @IsString()
  @MaxLength(200)
  fullName!: string;

  @IsString()
  @IsOptional()
  @MaxLength(50)
  phone?: string;

  @IsString()
  @IsOptional()
  @MaxLength(255)
  email?: string;

  @IsString()
  @IsOptional()
  @MaxLength(100)
  source?: string;

  @IsArray()
  @ArrayMaxSize(50)
  @IsString({ each: true })
  @MaxLength(50, { each: true })
  @IsOptional()
  tags?: string[];
}

class IngestLeadsDto {
  @IsArray()
  // Matches ingestLeadsForVenue's existing `.slice(0, 100)` — reject an
  // oversized batch outright instead of silently discarding the tail.
  @ArrayMaxSize(100)
  @ValidateNested({ each: true })
  @Type(() => LeadDto)
  leads!: LeadDto[];
}

class GuestListQueryDto {
  @IsString()
  @IsOptional()
  @MaxLength(200)
  q?: string;

  @Type(() => Number)
  @IsOptional()
  page?: number;

  @Type(() => Number)
  @IsOptional()
  limit?: number;
}

function cleanText(value: string | undefined): string | undefined {
  const trimmed = value?.trim();
  return trimmed || undefined;
}

function cleanTags(tags: string[]): string[] {
  return Array.from(new Set(tags.map((t) => t.trim()).filter(Boolean))).slice(0, 12);
}

function mergeTags(existing: string[], incoming: string[]): string[] {
  return cleanTags([...existing, ...incoming]);
}

@Controller('v1/guests')
export class GuestsController {
  constructor(private readonly prisma: PrismaService) {}

  private requireManager(scope: Scope): asserts scope is NonNullable<Scope> {
    if (!scope || !canManageVenue(scope.role, scope.allAccess)) throw new ForbiddenException('Not authorized');
  }

  @RequireSubscription('active')
  @Get()
  async listGuests(@VenueScope() scope: Scope, @Query() query: GuestListQueryDto) {
    this.requireManager(scope);
    const page = Math.max(0, Math.floor(query.page ?? 0));
    const limit = Math.min(Math.max(1, Math.floor(query.limit ?? 100)), 200);
    const where: Record<string, unknown> = {
      venueId: scope.venueId,
      deletedAt: null,
    };
    if (query.q?.trim()) {
      const term = query.q.trim().toLowerCase();
      where['OR'] = [
        { nameLower: { contains: term } },
        { email: { contains: term, mode: 'insensitive' } },
        { phone: { contains: term } },
      ];
    }
    const [guests, totalCount] = await this.prisma.$transaction([
      this.prisma.guest.findMany({
        where: where as any,
        orderBy: { updatedAt: 'desc' },
        skip: page * limit,
        take: limit,
      }),
      this.prisma.guest.count({ where: where as any }),
    ]);

    const guestIds = guests.map((g) => g.id);
    const now = Date.now();
    // Batched aggregates (groupBy/findMany over the whole page) instead of one
    // query per guest — segmentation, VIP scoring, and lifetime-spend totals
    // on this screen all read these fields, so they must be populated even at
    // 200 guests per page.
    const [checkAgg, reservationCounts, upcomingReservations] = guestIds.length
      ? await Promise.all([
          this.prisma.posCheck.groupBy({
            by: ['guestId'],
            where: { venueId: scope.venueId, guestId: { in: guestIds } },
            _count: { _all: true },
            _sum: { totalCents: true },
            _max: { closedAt: true },
          }),
          this.prisma.reservation.groupBy({
            by: ['guestId'],
            where: { venueId: scope.venueId, guestId: { in: guestIds }, deletedAt: null, status: { not: 'cancelled' } },
            _count: { _all: true },
          }),
          this.prisma.reservation.findMany({
            where: {
              venueId: scope.venueId,
              guestId: { in: guestIds },
              deletedAt: null,
              reservationTime: { gte: new Date(now) },
              status: { notIn: ['cancelled', 'no_show', 'completed'] },
            },
            select: { guestId: true, reservationTime: true },
            orderBy: { reservationTime: 'asc' },
          }),
        ])
      : [[], [], []];
    const checkByGuest = new Map(checkAgg.filter((a) => a.guestId).map((a) => [a.guestId as string, a]));
    const reservationCountByGuest = new Map(reservationCounts.filter((a) => a.guestId).map((a) => [a.guestId as string, a._count._all]));
    const upcomingByGuest = new Map<string, number>();
    for (const r of upcomingReservations) {
      if (r.guestId && !upcomingByGuest.has(r.guestId)) upcomingByGuest.set(r.guestId, r.reservationTime.getTime());
    }

    return {
      guests: guests.map((g) => {
        const agg = checkByGuest.get(g.id);
        const visitCount = agg?._count._all ?? 0;
        const totalSpendCents = agg?._sum.totalCents ?? 0;
        const lastVisitAt = agg?._max.closedAt ? agg._max.closedAt.getTime() : null;
        return {
          _id: g.id,
          venueId: g.venueId,
          fullName: g.fullName,
          phone: g.phone ?? null,
          email: g.email ?? null,
          lifecycleStage: g.lifecycleStage ?? 'lead',
          source: g.source ?? null,
          birthday: g.birthday ?? null,
          company: g.company ?? null,
          marketingOptIn: g.marketingOptIn ?? false,
          favoriteTable: g.favoriteTable ?? null,
          preferredServer: g.preferredServer ?? null,
          dietaryNotes: g.dietaryNotes ?? null,
          tags: g.tags,
          notes: g.notes ?? null,
          createdAt: g.createdAt.getTime(),
          updatedAt: g.updatedAt.getTime(),
          reservationCount: reservationCountByGuest.get(g.id) ?? 0,
          visitCount,
          lastVisitAt,
          upcomingReservationAt: upcomingByGuest.get(g.id) ?? null,
          totalSpendCents,
          averageSpendCents: visitCount > 0 ? Math.round(totalSpendCents / visitCount) : 0,
          daysSinceLastVisit: lastVisitAt != null ? Math.floor((now - lastVisitAt) / 86_400_000) : null,
        };
      }),
      totalCount,
      page,
      limit,
    };
  }

  @RequireSubscription('active')
  @Get(':id')
  async getGuestProfile(@VenueScope() scope: Scope, @Param('id') id: string) {
    this.requireManager(scope);
    const guest = await this.prisma.guest.findFirst({ where: { id, venueId: scope.venueId, deletedAt: null } });
    if (!guest) throw new NotFoundException('Guest not found');

    const [reservations, checks] = await Promise.all([
      this.prisma.reservation.findMany({
        where: { venueId: scope.venueId, guestId: guest.id, deletedAt: null },
        orderBy: { reservationTime: 'desc' },
        take: 50,
      }),
      this.prisma.posCheck.findMany({
        where: { venueId: scope.venueId, guestId: guest.id },
        orderBy: { openedAt: 'desc' },
        take: 50,
      }),
    ]);

    return {
      guest: {
        _id: guest.id,
        venueId: guest.venueId,
        fullName: guest.fullName,
        phone: guest.phone ?? null,
        email: guest.email ?? null,
        lifecycleStage: guest.lifecycleStage ?? 'lead',
        source: guest.source ?? null,
        birthday: guest.birthday ?? null,
        company: guest.company ?? null,
        marketingOptIn: guest.marketingOptIn ?? false,
        favoriteTable: guest.favoriteTable ?? null,
        preferredServer: guest.preferredServer ?? null,
        dietaryNotes: guest.dietaryNotes ?? null,
        tags: guest.tags,
        notes: guest.notes ?? null,
        createdAt: guest.createdAt.getTime(),
        updatedAt: guest.updatedAt.getTime(),
      },
      reservations: reservations.map((r) => ({
        _id: r.id,
        partySize: r.partySize,
        reservationTime: r.reservationTime.getTime(),
        status: r.status,
        tags: r.tags,
        notes: r.notes ?? null,
        isPrivateEvent: r.isPrivateEvent ?? false,
        eventName: r.eventName ?? null,
        eventStatus: r.eventStatus ?? null,
        eventSpace: r.eventSpace ?? null,
        setupStyle: r.setupStyle ?? null,
        menuNotes: r.menuNotes ?? null,
        beverageNotes: r.beverageNotes ?? null,
        billingNotes: r.billingNotes ?? null,
        estimatedValueCents: r.estimatedValueCents ?? null,
        depositDueCents: r.depositDueCents ?? null,
      })),
      checks: checks.map((c) => ({
        _id: c.id,
        provider: c.provider,
        openedAt: c.openedAt.getTime(),
        closedAt: c.closedAt ? c.closedAt.getTime() : null,
        totalCents: c.totalCents,
        tipCents: c.tipCents,
        status: c.status,
        revenueCenter: c.revenueCenter ?? null,
        tenderType: c.tenderType ?? null,
        guestCount: c.guestCount ?? null,
        menuItems: c.menuItems
          ? (c.menuItems as any[]).map((item) => ({
              name: item.name,
              category: item.category ?? null,
              quantity: item.quantity,
              priceCents: item.priceCents,
            }))
          : [],
      })),
    };
  }

  @RequireSubscription('active')
  @Post()
  async upsertGuest(@VenueScope() scope: Scope, @Body() body: UpsertGuestDto) {
    this.requireManager(scope);
    const fullName = body.fullName.trim();
    if (!fullName) throw new BadRequestException('Guest name is required');
    const now = new Date();
    const data = {
      venueId: scope.venueId,
      fullName,
      nameLower: fullName.toLowerCase(),
      phone: cleanText(body.phone) ?? null,
      email: cleanText(body.email)?.toLowerCase() ?? null,
      lifecycleStage: body.lifecycleStage ?? null,
      source: cleanText(body.source) ?? null,
      birthday: cleanText(body.birthday) ?? null,
      company: cleanText(body.company) ?? null,
      marketingOptIn: body.marketingOptIn ?? false,
      favoriteTable: cleanText(body.favoriteTable) ?? null,
      preferredServer: cleanText(body.preferredServer) ?? null,
      dietaryNotes: cleanText(body.dietaryNotes) ?? null,
      tags: cleanTags(body.tags ?? []),
      notes: cleanText(body.notes) ?? null,
      updatedAt: now,
    };

    if (body.guestId) {
      const existing = await this.prisma.guest.findFirst({
        where: { id: body.guestId, venueId: scope.venueId, deletedAt: null },
      });
      if (!existing) throw new BadRequestException('Guest not found');
      const updated = await this.prisma.guest.update({ where: { id: existing.id }, data });
      return { id: updated.id };
    }

    const created = await this.prisma.guest.create({ data: { ...data, createdAt: now } });
    return { id: created.id };
  }

  @RequireSubscription('active')
  @Delete(':id')
  async removeGuest(@VenueScope() scope: Scope, @Param('id') id: string) {
    this.requireManager(scope);
    const guest = await this.prisma.guest.findFirst({ where: { id, venueId: scope.venueId, deletedAt: null } });
    if (!guest) throw new BadRequestException('Guest not found');
    await this.prisma.$transaction(async (tx) => {
      await tx.guest.update({
        where: { id: guest.id },
        data: { deletedAt: new Date() },
      });
      // Regression for VW-06: Reservation and Waitlist denormalize guest
      // contact details for display without a live Guest row. Deleting the
      // guest previously severed the link (Guest -> SetNull) but left this
      // PII sitting on every historical booking. guestName is kept — an
      // operational booking record with no name at all is unusable.
      await tx.reservation.updateMany({
        where: { guestId: guest.id, venueId: scope.venueId },
        data: { guestPhone: null, guestEmail: null, guestCompany: null },
      });
      await tx.waitlist.updateMany({
        where: { guestId: guest.id, venueId: scope.venueId },
        data: { guestPhone: null, guestEmail: null },
      });
    });
    return { ok: true };
  }

  @RequireSubscription('active')
  @Post('ingest-leads')
  async ingestLeads(@VenueScope() scope: Scope, @Body() body: IngestLeadsDto) {
    this.requireManager(scope);
    return this.ingestLeadsForVenue(scope.venueId, body.leads);
  }

  // External lead sources (web forms, ad platforms) POST here, authenticated by
  // the venue's rotatable leadsWebhookSecret rather than a user session.
  @Public()
  @Post('leads-webhook/:venueId')
  async leadsWebhook(
    @Req() request: Request,
    @Param('venueId') venueId: string,
    @Headers('x-webhook-secret') secret: string | undefined,
    @Headers('x-webhook-id') eventId: string | undefined,
    @Headers('x-webhook-timestamp') timestamp: string | undefined,
    @Body() body: IngestLeadsDto,
  ) {
    // Verify the webhook secret before touching the rate limiter so an
    // unauthenticated spray of random venueIds can't churn RateLimitBucket rows.
    const venue = await this.prisma.venue.findUnique({ where: { id: venueId }, select: { leadsWebhookSecret: true } });
    if (!venue?.leadsWebhookSecret || !secretsMatch(secret, venue.leadsWebhookSecret)) {
      throw new UnauthorizedException('Invalid webhook secret');
    }
    const validatedEventId = validateLeadWebhookReplayHeaders(eventId, timestamp);
    const eventHash = createHash('sha256').update(validatedEventId).digest('hex');
    const replayKey = `leads-webhook-event:${venueId}:${eventHash}`;
    await assertWithinSharedRateLimit(
      this.prisma,
      replayKey,
      1,
      LEADS_WEBHOOK_EVENT_TTL_MS,
      'Duplicate webhook event.',
    );
    try {
      await assertWithinSharedRateLimit(this.prisma, `leads-webhook:${venueId}:${getClientIp(request)}`, LEADS_WEBHOOK_RATE_LIMIT_MAX, LEADS_WEBHOOK_RATE_LIMIT_WINDOW_MS, 'Too many webhook requests.');
      return await this.ingestLeadsForVenue(venueId, body.leads);
    } catch (error) {
      // The event claim blocks concurrent/replayed delivery. Release only our
      // claim if processing fails so the provider may safely retry the same
      // event id; the lead mutation itself is transactional.
      await this.prisma.rateLimitBucket.deleteMany({ where: { key: replayKey } }).catch(() => undefined);
      throw error;
    }
  }

  private async ingestLeadsForVenue(venueId: string, rawLeads: LeadDto[]) {
    const leads = rawLeads.slice(0, 100);
    let created = 0;
    let updated = 0;
    let skipped = 0;
    const guestIds: string[] = [];
    const seen = new Set<string>();

    // Normalize + dedupe first so we can batch the existence lookups instead of
    // issuing up to three queries per lead (the original N+1).
    const normalized = leads
      .map((lead) => {
        const fullName = lead.fullName.trim();
        if (!fullName) return null;
        const phone = cleanText(lead.phone) ?? null;
        const email = cleanText(lead.email)?.toLowerCase() ?? null;
        return {
          fullName,
          nameLower: fullName.toLowerCase(),
          phone,
          email,
          tags: cleanTags([...(lead.tags ?? []), 'lead']),
          source: cleanText(lead.source) ?? null,
          key: email ?? phone ?? fullName.toLowerCase(),
        };
      })
      .filter((l): l is NonNullable<typeof l> => l !== null);
    skipped += leads.length - normalized.length;

    const emails = [...new Set(normalized.map((l) => l.email).filter((e): e is string => !!e))];
    const phones = [...new Set(normalized.map((l) => l.phone).filter((p): p is string => !!p))];
    const names = [...new Set(normalized.map((l) => l.nameLower))];
    const existingGuests = await this.prisma.guest.findMany({
      where: {
        venueId,
        deletedAt: null,
        OR: [
          ...(emails.length ? [{ email: { in: emails } }] : []),
          ...(phones.length ? [{ phone: { in: phones } }] : []),
          { nameLower: { in: names } },
        ],
      },
    });
    const byEmail = new Map(existingGuests.filter((g) => g.email).map((g) => [g.email!.toLowerCase(), g]));
    const byPhone = new Map(existingGuests.filter((g) => g.phone).map((g) => [g.phone!, g]));
    const byName = new Map(existingGuests.map((g) => [g.nameLower ?? g.fullName.toLowerCase(), g]));

    await this.prisma.$transaction(async (tx) => {
      for (const lead of normalized) {
        const { fullName, phone, email, tags: incomingTags, source } = lead;
        if (seen.has(lead.key)) { skipped++; continue; }
        seen.add(lead.key);

        // Merge only on an identifier that actually identifies a person.
        // Matching on a shared name grafted one guest's contact details and
        // history onto another's: two different "John Smith"s collapsed into
        // one record, and a stranger's email was written onto an existing
        // guest that happened to have none. This runs from a public webhook,
        // where common names and sparse contact details are the norm.
        const existing =
          (email ? byEmail.get(email) : null) ??
          (phone ? byPhone.get(phone) : null) ??
          null;
        const nameOnlyMatch = !existing && byName.has(lead.nameLower);

        if (existing) {
          await tx.guest.update({
            where: { id: existing.id },
            data: {
              fullName,
              nameLower: fullName.toLowerCase(),
              // Never overwrite a contact value we already hold: a lead matched
              // on phone alone must not replace the stored email, and vice versa.
              phone: existing.phone ?? phone ?? null,
              email: existing.email ?? email ?? null,
              lifecycleStage: existing.lifecycleStage ?? 'lead',
              source: source ?? existing.source,
              tags: mergeTags(existing.tags, incomingTags),
            },
          });
          guestIds.push(existing.id);
          updated++;
        } else {
          const newGuest = await tx.guest.create({
            data: {
              venueId,
              fullName,
              nameLower: fullName.toLowerCase(),
              phone: phone ?? null,
              email: email ?? null,
              lifecycleStage: 'lead',
              source,
              marketingOptIn: false,
              // Flag rather than merge, so a human resolves genuine duplicates
              // on the guests screen instead of the importer guessing.
              tags: nameOnlyMatch ? mergeTags(incomingTags, [POSSIBLE_DUPLICATE_TAG]) : incomingTags,
            },
          });
          if (newGuest.email) byEmail.set(newGuest.email.toLowerCase(), newGuest);
          if (newGuest.phone) byPhone.set(newGuest.phone, newGuest);
          byName.set(newGuest.nameLower ?? newGuest.fullName.toLowerCase(), newGuest);
          guestIds.push(newGuest.id);
          created++;
        }
      }
    });

    return { created, updated, skipped, guestIds };
  }

  @RequireSubscription('active')
  @Audited('webhook_secret.rotate_leads', { entityType: 'venue', summary: 'Rotated leads webhook secret' })
  @Post('rotate-webhook-secret')
  async rotateLeadsWebhookSecret(@VenueScope() scope: Scope) {
    this.requireManager(scope);
    const { secret, hashedSecret } = generateWebhookSecret();
    await this.prisma.venue.update({
      where: { id: scope.venueId },
      data: { leadsWebhookSecret: hashedSecret },
    });
    return { webhookSecret: secret };
  }
}

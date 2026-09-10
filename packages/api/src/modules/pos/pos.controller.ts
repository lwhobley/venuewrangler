import { BadRequestException, Body, Controller, ForbiddenException, Get, Headers, NotFoundException, Param, Post, Query, Req, UnauthorizedException } from '@nestjs/common';
import { ArrayMaxSize, IsArray, IsIn, IsInt, IsNumber, IsOptional, IsString, MaxLength, Min, ValidateNested } from 'class-validator';
import { Type } from 'class-transformer';
import { Prisma, PosProvider, PosCheckStatus } from '@prisma/client';
import type { Request } from 'express';
import { canManageVenue, isAdminRole } from '../../auth/roles';
import { Public } from '../../auth/public.decorator';
import { getClientIp } from '../../common/http';
import { assertWithinSharedRateLimit } from '../../common/rate-limit';
import { zonedDayBounds, zonedIsoDate } from '../../common/venue-time';
import { generateWebhookSecret, secretsMatch } from '../../common/webhook-auth';
import { PrismaService } from '../../prisma/prisma.service';
import { RequireSubscription } from '../../billing/require-subscription.decorator';
import { VenueScope } from '../../venue/venue-scope.decorator';
import type { VenueScopedRequest } from '../../venue/venue-scope.interceptor';
import { Audited } from '../audit/audited.decorator';

type Scope = VenueScopedRequest['venueScope'];

const num = (v: unknown) => (v == null ? 0 : Number(v));
const MAX_INGEST_ROWS = 1000;
const INGEST_CHUNK_SIZE = 100;
const INGEST_RATE_LIMIT_MAX = 120;
const INGEST_RATE_LIMIT_WINDOW_MS = 60_000;
// Source of truth for which POS providers can register a webhook connection.
// Must stay in sync with the PosProvider enum in prisma/schema.prisma.
const POS_PROVIDERS = [
  'toast',
  'square',
  'clover',
  'shopify_pos',
  'lightspeed_restaurant',
  'spoton',
  'generic',
] as const;
const POS_CHECK_STATUSES = ['open', 'paid', 'void'] as const;

class SalesWindowQueryDto {
  @IsOptional()
  @Type(() => Number)
  @IsNumber()
  @Min(1)
  windowDays?: number;

  @IsOptional()
  @Type(() => Number)
  @IsNumber()
  startTs?: number;

  @IsOptional()
  @Type(() => Number)
  @IsNumber()
  endTs?: number;
}

class TopItemsQueryDto extends SalesWindowQueryDto {
  @IsOptional()
  @Type(() => Number)
  @IsNumber()
  @Min(1)
  limit?: number;
}

class UpsertPosConnectionDto {
  @IsIn([...POS_PROVIDERS])
  provider!: string;

  @IsOptional()
  @IsString()
  @MaxLength(255)
  externalLocationId?: string;

  @IsIn(['connected', 'paused', 'error'])
  status!: string;
}

class IngestMenuItemDto {
  @IsString()
  @MaxLength(200)
  name!: string;

  @IsString()
  @IsOptional()
  @MaxLength(100)
  category?: string;

  @IsNumber()
  quantity!: number;

  @IsInt()
  priceCents!: number;
}

class IngestCheckDto {
  @IsString()
  @MaxLength(128)
  externalCheckId!: string;

  @IsNumber()
  openedAt!: number;

  @IsNumber()
  @IsOptional()
  closedAt?: number;

  @IsIn(POS_CHECK_STATUSES)
  @IsOptional()
  status?: string;

  @IsInt() subtotalCents!: number;
  @IsInt() totalCents!: number;
  @IsInt() tipCents!: number;

  @IsInt() @IsOptional() taxCents?: number;
  @IsInt() @IsOptional() discountCents?: number;
  @IsInt() @IsOptional() compCents?: number;
  @IsInt() @IsOptional() promoCents?: number;
  @IsInt() @IsOptional() guestCount?: number;

  @IsString() @IsOptional() @MaxLength(100) tableLabel?: string;
  @IsString() @IsOptional() @MaxLength(200) serverName?: string;
  @IsString() @IsOptional() @MaxLength(200) guestName?: string;
  @IsString() @IsOptional() @MaxLength(100) revenueCenter?: string;
  @IsString() @IsOptional() @MaxLength(100) tenderType?: string;

  @IsArray()
  @IsOptional()
  @ArrayMaxSize(500)
  @ValidateNested({ each: true })
  @Type(() => IngestMenuItemDto)
  menuItems?: IngestMenuItemDto[];
}

class IngestLaborPunchDto {
  @IsString() @MaxLength(128) externalEmployeeId!: string;
  @IsString() @MaxLength(200) employeeName!: string;
  @IsString() @IsOptional() @MaxLength(100) jobTitle?: string;

  @IsNumber() clockInAt!: number;
  @IsNumber() @IsOptional() clockOutAt?: number;

  @IsInt() @IsOptional() regularMinutes?: number;
  @IsInt() @IsOptional() overtimeMinutes?: number;
  @IsInt() @IsOptional() declaredTipsCents?: number;
  @IsInt() @IsOptional() tipsCents?: number;
  @IsInt() @IsOptional() regularPayCents?: number;
  @IsInt() @IsOptional() overtimePayCents?: number;
  @IsInt() @IsOptional() totalPayCents?: number;

  @IsString() @MaxLength(32) businessDate!: string;
}

class PosIngestDto {
  @IsIn(POS_PROVIDERS)
  provider!: string;

  @IsArray()
  @IsOptional()
  @ArrayMaxSize(MAX_INGEST_ROWS)
  @ValidateNested({ each: true })
  @Type(() => IngestCheckDto)
  checks?: IngestCheckDto[];

  @IsArray()
  @IsOptional()
  @ArrayMaxSize(MAX_INGEST_ROWS)
  @ValidateNested({ each: true })
  @Type(() => IngestLaborPunchDto)
  laborPunches?: IngestLaborPunchDto[];
}

@Controller('v1/pos')
export class PosController {
  constructor(private readonly prisma: PrismaService) {}

  // External POS providers POST normalized sales/labor here. Authenticated by a
  // per-connection webhook secret (issued by upsertPosConnection), not a user
  // session. Idempotent: re-delivered rows upsert on their unique keys instead
  // of double-counting.
  @Public()
  @Post('ingest/:venueId')
  async ingest(
    @Req() request: Request,
    @Param('venueId') venueId: string,
    @Headers('x-webhook-secret') secret: string | undefined,
    @Body() body: PosIngestDto,
  ) {
    const provider = body.provider as PosProvider;
    // Verify the per-connection secret before touching the rate limiter so an
    // unauthenticated spray of random venueIds can't churn RateLimitBucket rows.
    const connection = await this.prisma.posConnection.findFirst({ where: { venueId, provider } });
    if (!connection?.webhookSecret || !secretsMatch(secret, connection.webhookSecret)) {
      throw new UnauthorizedException('Invalid webhook secret');
    }
    // Pausing a connection has to stop the data, not just relabel the
    // integration screen. The credential stays valid (pause is reversible and
    // must not force a secret rotation), so the pause is enforced here: a
    // provider that keeps sending gets a clear refusal rather than silently
    // updating a venue that believes the feed is off.
    if (connection.status === 'paused') {
      throw new ForbiddenException('This POS connection is paused. Resume it in Venue Wrangler to accept updates.');
    }
    await assertWithinSharedRateLimit(this.prisma, `pos-ingest:${venueId}:${getClientIp(request)}`, INGEST_RATE_LIMIT_MAX, INGEST_RATE_LIMIT_WINDOW_MS, 'Too many webhook requests.');

    // class-validator's @IsNumber() accepts NaN/Infinity, which would surface
    // as a 500 from Prisma via `new Date(NaN)`. Reject non-finite timestamps
    // up front with a 400 the provider can act on.
    for (const check of body.checks ?? []) {
      if (!Number.isFinite(check.openedAt) || (check.closedAt != null && !Number.isFinite(check.closedAt))) {
        throw new BadRequestException(`Invalid timestamp on check ${check.externalCheckId}`);
      }
    }
    for (const punch of body.laborPunches ?? []) {
      if (!Number.isFinite(punch.clockInAt) || (punch.clockOutAt != null && !Number.isFinite(punch.clockOutAt))) {
        throw new BadRequestException(`Invalid timestamp on labor punch ${punch.externalEmployeeId}`);
      }
    }

    // A paid/void check is a closed financial record, not a mutable draft.
    // The previous fix checked closed status with a separate findMany before
    // building the upserts, which left a TOCTOU window (a concurrent
    // delivery could close the check between the check and the write) and
    // blocked every field equally — including a tip adjustment a POS
    // commonly sends after the guest signs, which is a legitimate post-close
    // update, not a rewrite attempt. Each check is now a single atomic
    // INSERT ... ON CONFLICT DO UPDATE: the core sale amounts (subtotal,
    // tax, discount, comp, promo) and the itemization (menuItems) are locked
    // once the existing row's status is paid/void, via a CASE against the
    // row being upserted — checked and written in one statement, so there is
    // no window between them. Tip, total (which a tip adjustment necessarily
    // changes), status itself (a paid check being voided is a real
    // correction), and non-financial metadata all remain freely correctable
    // after close.
    const checkOperations = (body.checks ?? []).map((check) => {
      const menuItemsJson = check.menuItems ? JSON.stringify(check.menuItems) : null;
      return this.prisma.$executeRaw(Prisma.sql`
        INSERT INTO "PosCheck" (
          "id", "venueId", "provider", "externalCheckId", "tableLabel", "serverName", "guestName",
          "openedAt", "closedAt", "subtotalCents", "taxCents", "tipCents", "totalCents",
          "discountCents", "compCents", "promoCents", "guestCount", "revenueCenter", "tenderType",
          "menuItems", "status", "updatedAt"
        ) VALUES (
          gen_random_uuid()::text, ${venueId}, ${provider}::"PosProvider", ${check.externalCheckId},
          ${check.tableLabel ?? null}, ${check.serverName ?? null}, ${check.guestName ?? null},
          ${new Date(check.openedAt)}, ${check.closedAt ? new Date(check.closedAt) : null},
          ${check.subtotalCents}, ${check.taxCents ?? null}, ${check.tipCents}, ${check.totalCents},
          ${check.discountCents ?? null}, ${check.compCents ?? null}, ${check.promoCents ?? null},
          ${check.guestCount ?? null}, ${check.revenueCenter ?? null}, ${check.tenderType ?? null},
          ${menuItemsJson}::jsonb, ${(check.status ?? 'open') as PosCheckStatus}::"PosCheckStatus", NOW()
        )
        ON CONFLICT ("venueId", "provider", "externalCheckId") DO UPDATE SET
          "tableLabel" = EXCLUDED."tableLabel",
          "serverName" = EXCLUDED."serverName",
          "guestName" = EXCLUDED."guestName",
          "openedAt" = EXCLUDED."openedAt",
          "closedAt" = EXCLUDED."closedAt",
          "subtotalCents" = CASE WHEN "PosCheck"."status" IN ('paid', 'void') THEN "PosCheck"."subtotalCents" ELSE EXCLUDED."subtotalCents" END,
          "taxCents" = CASE WHEN "PosCheck"."status" IN ('paid', 'void') THEN "PosCheck"."taxCents" ELSE EXCLUDED."taxCents" END,
          "discountCents" = CASE WHEN "PosCheck"."status" IN ('paid', 'void') THEN "PosCheck"."discountCents" ELSE EXCLUDED."discountCents" END,
          "compCents" = CASE WHEN "PosCheck"."status" IN ('paid', 'void') THEN "PosCheck"."compCents" ELSE EXCLUDED."compCents" END,
          "promoCents" = CASE WHEN "PosCheck"."status" IN ('paid', 'void') THEN "PosCheck"."promoCents" ELSE EXCLUDED."promoCents" END,
          "tipCents" = EXCLUDED."tipCents",
          "totalCents" = EXCLUDED."totalCents",
          "guestCount" = EXCLUDED."guestCount",
          "revenueCenter" = EXCLUDED."revenueCenter",
          "tenderType" = EXCLUDED."tenderType",
          "menuItems" = CASE WHEN "PosCheck"."status" IN ('paid', 'void') THEN "PosCheck"."menuItems" ELSE EXCLUDED."menuItems" END,
          -- paid<->void is a real correction (a disputed charge, a voided-in-
          -- error check reinstated). Closed -> 'open' is not: it would reopen
          -- a settled check, and the CASE guards above key off status = 'paid'
          -- or 'void' to decide whether a field is locked — so a late/stale
          -- 'open' delivery reopening it would silently unlock every guarded
          -- field for whatever delivery comes next. Once closed, stay closed.
          "status" = CASE
            WHEN "PosCheck"."status" IN ('paid', 'void') AND EXCLUDED."status" = 'open' THEN "PosCheck"."status"
            ELSE EXCLUDED."status"
          END,
          "updatedAt" = NOW()
      `);
    });

    // Batch into chunked transactions (not one single transaction for the
    // whole payload) so a large delivery (up to MAX_INGEST_ROWS checks +
    // MAX_INGEST_ROWS labor punches) can't hold one transaction's locks for
    // an extended period.
    const operations = [
      ...checkOperations,
      ...(body.laborPunches ?? []).map((punch) => {
        const data = {
          employeeName: punch.employeeName,
          jobTitle: punch.jobTitle ?? null,
          clockInAt: new Date(punch.clockInAt),
          clockOutAt: punch.clockOutAt ? new Date(punch.clockOutAt) : null,
          regularMinutes: punch.regularMinutes ?? null,
          overtimeMinutes: punch.overtimeMinutes ?? null,
          declaredTipsCents: punch.declaredTipsCents ?? null,
          tipsCents: punch.tipsCents ?? null,
          regularPayCents: punch.regularPayCents ?? null,
          overtimePayCents: punch.overtimePayCents ?? null,
          totalPayCents: punch.totalPayCents ?? null,
        };
        return this.prisma.posLaborPunch.upsert({
          where: {
            venueId_provider_externalEmployeeId_businessDate: {
              venueId,
              provider,
              externalEmployeeId: punch.externalEmployeeId,
              businessDate: punch.businessDate,
            },
          },
          create: { venueId, provider, externalEmployeeId: punch.externalEmployeeId, businessDate: punch.businessDate, ...data },
          update: data,
        });
      }),
    ];
    for (let i = 0; i < operations.length; i += INGEST_CHUNK_SIZE) {
      await this.prisma.$transaction(operations.slice(i, i + INGEST_CHUNK_SIZE));
    }

    const checksUpserted = checkOperations.length;
    const laborUpserted = (body.laborPunches ?? []).length;

    await this.prisma.posConnection.update({ where: { id: connection.id }, data: { lastSyncAt: new Date() } });
    return { ok: true, checksUpserted, laborUpserted };
  }

  private requireManager(scope: Scope): asserts scope is NonNullable<Scope> {
    if (!scope || !canManageVenue(scope.role, scope.allAccess)) throw new ForbiddenException('Not authorized');
  }

  // The venue's IANA timezone (null -> UTC). Daily buckets and "today" are
  // computed in the venue's business day, not the server's.
  private async venueTimezone(venueId: string): Promise<string | null> {
    const venue = await this.prisma.venue.findUnique({ where: { id: venueId }, select: { timezone: true } });
    return venue?.timezone ?? null;
  }

  // Resolve the [start, end) window for a sales query, defaulting to the last
  // `windowDays` venue-local days (inclusive of today).
  private resolveWindow(query: SalesWindowQueryDto, tz: string | null) {
    const windowDays = Math.min(Math.max(1, Math.round(query.windowDays ?? 7)), 90);
    const start = query.startTs ?? zonedDayBounds(tz, -windowDays + 1).start;
    const end = query.endTs !== undefined ? query.endTs + 1 : zonedDayBounds(tz, 0).end;
    return { start: new Date(start), end: new Date(end) };
  }

  @RequireSubscription('active')
  @Get('overview')
  async getPosOverview(@VenueScope() scope: Scope) {
    this.requireManager(scope);
    const venueId = scope.venueId;
    const tz = await this.venueTimezone(venueId);
    const dayStartDate = new Date(zonedDayBounds(tz, 0).start);

    const [connections, recentChecks, todayTotals, openChecks] = await Promise.all([
      this.prisma.posConnection.findMany({ where: { venueId }, take: 10 }),
      this.prisma.posCheck.findMany({ where: { venueId }, orderBy: { openedAt: 'desc' }, take: 50 }),
      this.prisma.posCheck.aggregate({
        where: { venueId, openedAt: { gte: dayStartDate }, status: { not: 'void' } },
        _sum: { totalCents: true, tipCents: true },
      }),
      this.prisma.posCheck.count({ where: { venueId, status: 'open' } }),
    ]);

    const lastSyncAt = connections.reduce<number | null>((latest, conn) => {
      if (!conn.lastSyncAt) return latest;
      const ts = conn.lastSyncAt.getTime();
      return latest == null ? ts : Math.max(latest, ts);
    }, null);

    return {
      connections: connections.map((c) => this.mapConnection(c)),
      recentChecks: recentChecks.map((c) => this.mapCheck(c)),
      todaySalesCents: num(todayTotals._sum.totalCents),
      todayTipsCents: num(todayTotals._sum.tipCents),
      openChecks,
      lastSyncAt,
    };
  }

  @RequireSubscription('active')
  @Get('sales/summary')
  async getSalesSummaryDashboard(@VenueScope() scope: Scope, @Query() query: SalesWindowQueryDto) {
    this.requireManager(scope);
    const venueId = scope.venueId;
    const tz = await this.venueTimezone(venueId);
    const sqlTz = tz ?? 'UTC';
    const { start, end } = this.resolveWindow(query, tz);

    // Aggregate in SQL so totals are correct regardless of volume (no row cap).
    const [totalsRows, byDayRows, byTender, byRevenueCenter] = await Promise.all([
      this.prisma.$queryRaw<
        Array<{
          salesCents: bigint; taxCents: bigint; tipCents: bigint; discountCents: bigint;
          compCents: bigint; promoCents: bigint; checkCount: number; coverCount: bigint;
          avgCheckTimeMins: number | string | null;
        }>
      >`
        SELECT
          COALESCE(SUM("totalCents"), 0)::bigint AS "salesCents",
          COALESCE(SUM("taxCents"), 0)::bigint AS "taxCents",
          COALESCE(SUM("tipCents"), 0)::bigint AS "tipCents",
          COALESCE(SUM("discountCents"), 0)::bigint AS "discountCents",
          COALESCE(SUM("compCents"), 0)::bigint AS "compCents",
          COALESCE(SUM("promoCents"), 0)::bigint AS "promoCents",
          COUNT(*)::int AS "checkCount",
          COALESCE(SUM(COALESCE("guestCount", 1)), 0)::bigint AS "coverCount",
          AVG(EXTRACT(EPOCH FROM ("closedAt" - "openedAt")) / 60.0)
            FILTER (WHERE "closedAt" IS NOT NULL) AS "avgCheckTimeMins"
        FROM "PosCheck"
        WHERE "venueId" = ${venueId}
          AND "openedAt" >= ${start} AND "openedAt" < ${end}
          AND "status"::text <> 'void'
      `,
      this.prisma.$queryRaw<
        Array<{ date: string; salesCents: bigint; checkCount: number; coverCount: bigint }>
      >`
        -- Columns are timestamp-without-tz storing UTC; render in venue tz so
        -- daily buckets follow the venue's business day.
        SELECT to_char(("openedAt" AT TIME ZONE 'UTC') AT TIME ZONE ${sqlTz}, 'YYYY-MM-DD') AS date,
          COALESCE(SUM("totalCents"), 0)::bigint AS "salesCents",
          COUNT(*)::int AS "checkCount",
          COALESCE(SUM(COALESCE("guestCount", 1)), 0)::bigint AS "coverCount"
        FROM "PosCheck"
        WHERE "venueId" = ${venueId}
          AND "openedAt" >= ${start} AND "openedAt" < ${end}
          AND "status"::text <> 'void'
        GROUP BY 1 ORDER BY 1
      `,
      this.prisma.posCheck.groupBy({
        by: ['tenderType'],
        where: { venueId, openedAt: { gte: start, lt: end }, status: { not: 'void' } },
        _sum: { totalCents: true },
        _count: { _all: true },
      }),
      this.prisma.posCheck.groupBy({
        by: ['revenueCenter'],
        where: { venueId, openedAt: { gte: start, lt: end }, status: { not: 'void' } },
        _sum: { totalCents: true, guestCount: true },
        _count: { _all: true },
      }),
    ]);

    const totals = totalsRows[0];
    const checkCount = num(totals?.checkCount);
    const salesCents = num(totals?.salesCents);

    return {
      summary: {
        salesCents,
        taxCents: num(totals?.taxCents),
        tipCents: num(totals?.tipCents),
        discountCents: num(totals?.discountCents),
        compCents: num(totals?.compCents),
        promoCents: num(totals?.promoCents),
        checkCount,
        coverCount: num(totals?.coverCount),
        avgCheckCents: checkCount ? Math.round(salesCents / checkCount) : 0,
        avgCheckTimeMins: totals?.avgCheckTimeMins != null ? Math.round(num(totals.avgCheckTimeMins)) : null,
      },
      byDay: byDayRows.map((r) => ({
        date: r.date,
        salesCents: num(r.salesCents),
        checkCount: num(r.checkCount),
        coverCount: num(r.coverCount),
      })),
      byTender: byTender
        .map((r) => ({
          tenderType: r.tenderType?.trim() || 'Unknown',
          salesCents: num(r._sum.totalCents),
          checkCount: r._count._all,
        }))
        .sort((a, b) => b.salesCents - a.salesCents),
      byRevenueCenter: byRevenueCenter
        .map((r) => ({
          revenueCenter: r.revenueCenter?.trim() || 'Default',
          salesCents: num(r._sum.totalCents),
          checkCount: r._count._all,
          coverCount: num(r._sum.guestCount),
        }))
        .sort((a, b) => b.salesCents - a.salesCents),
    };
  }

  @RequireSubscription('active')
  @Get('sales/by-server')
  async getSalesByServer(@VenueScope() scope: Scope, @Query() query: SalesWindowQueryDto) {
    this.requireManager(scope);
    const { start, end } = this.resolveWindow(query, await this.venueTimezone(scope.venueId));

    const rows = await this.prisma.posCheck.groupBy({
      by: ['serverName'],
      where: { venueId: scope.venueId, openedAt: { gte: start, lt: end }, status: { not: 'void' } },
      _sum: { totalCents: true, tipCents: true, discountCents: true, compCents: true, guestCount: true },
      _count: { _all: true },
    });

    return rows
      .map((r) => {
        const salesCents = num(r._sum.totalCents);
        const checkCount = r._count._all;
        return {
          serverName: r.serverName?.trim() || 'Unknown',
          salesCents,
          tipCents: num(r._sum.tipCents),
          discountCents: num(r._sum.discountCents),
          compCents: num(r._sum.compCents),
          checkCount,
          coverCount: num(r._sum.guestCount),
          avgCheckCents: checkCount ? Math.round(salesCents / checkCount) : 0,
        };
      })
      .sort((a, b) => b.salesCents - a.salesCents);
  }

  @RequireSubscription('active')
  @Get('sales/top-items')
  async getTopMenuItems(@VenueScope() scope: Scope, @Query() query: TopItemsQueryDto) {
    this.requireManager(scope);
    const { start, end } = this.resolveWindow(query, await this.venueTimezone(scope.venueId));
    const cap = Math.min(Math.max(1, Math.round(query.limit ?? 20)), 50);

    // Unnest the menuItems JSON array and aggregate in SQL (no row cap).
    const rows = await this.prisma.$queryRaw<
      Array<{ name: string; category: string | null; quantity: number | string; salesCents: bigint }>
    >`
      SELECT item->>'name' AS name,
        MAX(item->>'category') AS category,
        COALESCE(SUM((item->>'quantity')::numeric), 0)::float8 AS quantity,
        COALESCE(SUM((item->>'priceCents')::numeric * (item->>'quantity')::numeric), 0)::bigint AS "salesCents"
      FROM "PosCheck" c, jsonb_array_elements(c."menuItems") AS item
      WHERE c."venueId" = ${scope.venueId}
        AND c."openedAt" >= ${start} AND c."openedAt" < ${end}
        AND c."status"::text <> 'void'
        AND c."menuItems" IS NOT NULL
        AND jsonb_typeof(c."menuItems") = 'array'
        AND item->>'name' IS NOT NULL
      GROUP BY item->>'name'
      ORDER BY "salesCents" DESC
      LIMIT ${cap}
    `;

    return rows.map((r) => ({
      name: r.name,
      category: r.category ?? null,
      quantity: num(r.quantity),
      salesCents: num(r.salesCents),
    }));
  }

  @RequireSubscription('active')
  @Get('labor')
  async getLaborSummary(@VenueScope() scope: Scope, @Query() query: SalesWindowQueryDto) {
    this.requireManager(scope);
    const tz = await this.venueTimezone(scope.venueId);
    const windowDays = Math.min(Math.max(1, Math.round(query.windowDays ?? 7)), 90);
    const startDate = zonedIsoDate(tz, query.startTs ?? zonedDayBounds(tz, -windowDays + 1).start);
    const endDate = zonedIsoDate(tz, query.endTs ?? Date.now());

    const rows = await this.prisma.posLaborPunch.groupBy({
      by: ['externalEmployeeId', 'employeeName', 'jobTitle'],
      where: { venueId: scope.venueId, businessDate: { gte: startDate, lte: endDate } },
      _sum: {
        regularMinutes: true,
        overtimeMinutes: true,
        totalPayCents: true,
        tipsCents: true,
        declaredTipsCents: true,
      },
    });

    let totalRegularMins = 0, totalOvertimeMins = 0, totalPayCents = 0, totalTipsCents = 0;
    const byEmployee = rows
      .map((r) => {
        const regularMins = num(r._sum.regularMinutes);
        const overtimeMins = num(r._sum.overtimeMinutes);
        const payCents = num(r._sum.totalPayCents);
        const tipsCents = num(r._sum.tipsCents) + num(r._sum.declaredTipsCents);
        totalRegularMins += regularMins;
        totalOvertimeMins += overtimeMins;
        totalPayCents += payCents;
        totalTipsCents += tipsCents;
        return { employeeName: r.employeeName, jobTitle: r.jobTitle ?? null, regularMins, overtimeMins, payCents, tipsCents };
      })
      .sort((a, b) => b.payCents - a.payCents);

    return { totalRegularMins, totalOvertimeMins, totalPayCents, totalTipsCents, byEmployee };
  }

  @RequireSubscription('active')
  @Post('connections')
  async upsertPosConnection(@VenueScope() scope: Scope, @Body() body: UpsertPosConnectionDto) {
    this.requireManager(scope);
    const venueId = scope.venueId;
    const externalLocationId = body.externalLocationId?.trim() || null;
    const now = new Date();

    const existing = await this.prisma.posConnection.findFirst({
      where: {
        venueId,
        provider: body.provider as any,
      },
    });

    const updateExisting = async (connection: NonNullable<typeof existing>) => {
      const freshSecret = connection.webhookSecret ? null : generateWebhookSecret();
      const updated = await this.prisma.posConnection.update({
        where: { id: connection.id },
        data: {
          status: body.status as any,
          externalLocationId,
          updatedAt: now,
          ...(freshSecret ? { webhookSecret: freshSecret.hashedSecret } : {}),
        },
      });
      return { ...this.mapConnection(updated), webhookSecret: freshSecret?.secret ?? null };
    };

    if (existing) return updateExisting(existing);

    const freshSecret = generateWebhookSecret();
    try {
      const created = await this.prisma.posConnection.create({
        data: {
          venueId,
          provider: body.provider as any,
          externalLocationId,
          status: body.status as any,
          webhookSecret: freshSecret.hashedSecret,
          createdAt: now,
          updatedAt: now,
        },
      });

      return { ...this.mapConnection(created), webhookSecret: freshSecret.secret };
    } catch (error: any) {
      if (error?.code !== 'P2002') throw error;
      const winner = await this.prisma.posConnection.findFirst({
        where: { venueId, provider: body.provider as any },
      });
      if (!winner) throw error;
      return updateExisting(winner);
    }
  }

  @RequireSubscription('active')
  @Audited('webhook_secret.rotate_pos', { entityType: 'pos_connection', summary: 'Rotated POS connection secret' })
  @Post('connections/:id/rotate-secret')
  async rotatePosConnectionSecret(@VenueScope() scope: Scope, @Param('id') id: string) {
    this.requireManager(scope);
    const connection = await this.prisma.posConnection.findFirst({
      where: { id, venueId: scope.venueId },
      select: { id: true },
    });
    if (!connection) throw new NotFoundException('POS connection not found');

    const freshSecret = generateWebhookSecret();
    await this.prisma.posConnection.update({
      where: { id: connection.id },
      data: { webhookSecret: freshSecret.hashedSecret, updatedAt: new Date() },
    });
    return { webhookSecret: freshSecret.secret };
  }

  private mapConnection(conn: {
    id: string;
    venueId: string;
    provider: string;
    externalLocationId: string | null;
    status: string;
    lastSyncAt: Date | null;
    createdAt: Date;
    updatedAt: Date;
  }) {
    return {
      _id: conn.id,
      id: conn.id,
      venueId: conn.venueId,
      provider: conn.provider,
      externalLocationId: conn.externalLocationId,
      status: conn.status,
      lastSyncAt: conn.lastSyncAt ? conn.lastSyncAt.getTime() : null,
      createdAt: conn.createdAt.getTime(),
      updatedAt: conn.updatedAt.getTime(),
    };
  }

  private mapCheck(check: {
    id: string;
    venueId: string;
    provider: string;
    externalCheckId: string;
    tableLabel: string | null;
    serverName: string | null;
    guestName: string | null;
    guestCount: number | null;
    openedAt: Date;
    closedAt: Date | null;
    subtotalCents: number;
    taxCents: number | null;
    tipCents: number;
    totalCents: number;
    discountCents: number | null;
    compCents: number | null;
    promoCents: number | null;
    menuItems: unknown;
    status: string;
    updatedAt: Date;
  }) {
    return {
      _id: check.id,
      id: check.id,
      venueId: check.venueId,
      provider: check.provider,
      externalCheckId: check.externalCheckId,
      tableLabel: check.tableLabel,
      serverName: check.serverName,
      guestName: check.guestName,
      guestCount: check.guestCount,
      openedAt: check.openedAt.getTime(),
      closedAt: check.closedAt ? check.closedAt.getTime() : null,
      subtotalCents: check.subtotalCents,
      taxCents: check.taxCents,
      tipCents: check.tipCents,
      totalCents: check.totalCents,
      discountCents: check.discountCents,
      compCents: check.compCents,
      promoCents: check.promoCents,
      menuItems: check.menuItems
        ? (check.menuItems as any[]).map((it) => ({
            name: it.name,
            category: it.category ?? null,
            quantity: it.quantity,
            priceCents: it.priceCents,
          }))
        : null,
      status: check.status,
      updatedAt: check.updatedAt.getTime(),
    };
  }
}

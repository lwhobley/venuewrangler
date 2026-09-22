import {
  BadRequestException,
  Body,
  Controller,
  ForbiddenException,
  Get,
  Header,
  Post,
  Query,
  Res,
} from '@nestjs/common';
import { IsInt, IsNumber, IsOptional, IsString, MaxLength } from 'class-validator';
import { canManageVenue } from '../../auth/roles';
import { RequireSubscription } from '../../billing/require-subscription.decorator';
import { csvCell, csvDocument } from '../../common/csv';
import { zonedDateBounds, zonedIsoDate } from '../../common/venue-time';
import { PrismaService } from '../../prisma/prisma.service';
import { VenueScope } from '../../venue/venue-scope.decorator';
import type { VenueScopedRequest } from '../../venue/venue-scope.interceptor';
import { Audited } from '../audit/audited.decorator';
import { GustoPayrollService } from './gusto-payroll.service';
import { PayrollConnectService } from './payroll-connect.service';
import { hoursPushUnavailable, isHoursPushProvider } from './payroll-providers';
import { Public } from '../../auth/public.decorator';
import { SkipVenueScope } from '../../venue/skip-venue-scope.decorator';
import type { Response } from 'express';

type Scope = VenueScopedRequest['venueScope'];

class ProviderPushDto {
  @IsString()
  @MaxLength(64)
  provider!: string;

  @IsString()
  @MaxLength(32)
  startDate!: string;

  @IsString()
  @MaxLength(32)
  endDate!: string;
}

class ProviderMapDto {
  @IsString()
  @MaxLength(64)
  provider!: string;

  @IsString()
  @MaxLength(64)
  profileId!: string;

  @IsOptional()
  @IsString()
  @MaxLength(64)
  payrollEmployeeId?: string;
}

class ProviderDto {
  @IsString()
  @MaxLength(64)
  provider!: string;
}

class PushPayrollDto {
  @IsString()
  @MaxLength(32)
  startDate!: string;

  @IsString()
  @MaxLength(32)
  endDate!: string;
}

class MapPayrollEmployeeDto {
  @IsString()
  @MaxLength(64)
  profileId!: string;

  @IsOptional()
  @IsString()
  @MaxLength(64)
  payrollEmployeeId?: string;
}

class RecordPayrollExportDto {
  @IsString()
  @MaxLength(64)
  provider!: string;

  @IsString()
  @MaxLength(32)
  periodStart!: string;

  @IsString()
  @MaxLength(32)
  periodEnd!: string;

  @IsInt()
  @IsOptional()
  rowCount?: number;

  @IsNumber()
  @IsOptional()
  totalHours?: number;
}

const ISO_DATE = /^\d{4}-\d{2}-\d{2}$/;
const MAX_PAYROLL_DAYS = 366;
const MAX_PAYROLL_ROWS = 20_000;

function payrollDate(value: string): number {
  const time = Date.parse(`${value}T00:00:00Z`);
  if (!ISO_DATE.test(value) || !Number.isFinite(time) || new Date(time).toISOString().slice(0, 10) !== value) {
    throw new BadRequestException('Payroll dates must be valid YYYY-MM-DD calendar dates.');
  }
  return time;
}

/**
 * Resolve the [periodStart, periodEnd) instant range for a payroll period in
 * the venue's own local calendar, not the server's UTC day. Hardcoding
 * `T00:00:00.000Z` / `T23:59:59.999Z` here previously bucketed shifts near
 * midnight into the wrong pay period for any venue not on UTC (e.g. a
 * "2026-07-07" period end fell at 19:59:59 local in America/New_York).
 * periodEnd is an exclusive upper bound (the venue-local start of the day
 * after endIso), matching zonedDateBounds' convention.
 */
async function resolvePayrollPeriod(
  prisma: PrismaService,
  venueId: string,
  startDate: string | undefined,
  endDate: string | undefined,
): Promise<{ periodStart: Date; periodEnd: Date; startIso: string; endIso: string }> {
  const venue = await prisma.venue.findUnique({ where: { id: venueId }, select: { timezone: true } });
  const tz = venue?.timezone ?? null;
  const now = Date.now();
  const defaultStartIso = zonedIsoDate(tz, now - 14 * 24 * 60 * 60 * 1000);
  const defaultEndIso = zonedIsoDate(tz, now);
  const startIso = startDate ?? defaultStartIso;
  const endIso = endDate ?? defaultEndIso;
  const days = (payrollDate(endIso) - payrollDate(startIso)) / 86_400_000 + 1;
  if (days < 1 || days > MAX_PAYROLL_DAYS) {
    throw new BadRequestException(`Payroll periods must be ordered and span at most ${MAX_PAYROLL_DAYS} days.`);
  }
  const periodStart = new Date(zonedDateBounds(tz, startIso).start);
  const periodEnd = new Date(zonedDateBounds(tz, endIso).end);
  return { periodStart, periodEnd, startIso, endIso };
}

async function buildPayrollRows(
  prisma: PrismaService,
  venueId: string,
  periodStart: Date,
  periodEnd: Date,
) {
  const [staff, entries] = await Promise.all([
    prisma.profile.findMany({
      where: { venueId },
      orderBy: { fullName: 'asc' },
      take: MAX_PAYROLL_ROWS + 1,
    }),
    prisma.timeEntry.findMany({
      where: {
        venueId,
        clockInAt: { lte: periodEnd },
        clockOutAt: { not: null, gte: periodStart },
      },
      orderBy: { clockInAt: 'asc' },
      take: MAX_PAYROLL_ROWS + 1,
    }),
  ]);
  if (staff.length > MAX_PAYROLL_ROWS || entries.length > MAX_PAYROLL_ROWS) {
    throw new BadRequestException('Payroll export is too large. Choose a smaller period; no partial export was generated.');
  }

  const inPeriod = (e: (typeof entries)[number]) => {
    if (!e.clockOutAt) return false;
    const end = e.clockOutAt.getTime();
    return end > periodStart.getTime() && e.clockInAt.getTime() < periodEnd.getTime();
  };
  const hoursOf = (rows: typeof entries) =>
    rows.reduce((sum, e) => {
      if (!e.clockOutAt) return sum;
      const start = Math.max(e.clockInAt.getTime(), periodStart.getTime());
      const end = Math.min(e.clockOutAt.getTime(), periodEnd.getTime());
      let durationMs = Math.max(0, end - start);
      const breaks = (e.breaks as any[]) || [];
      for (const b of breaks) {
        if (b.type !== 'unpaid' || !b.startAt || !b.endAt) continue;
        const breakStart = Math.max(start, Number(b.startAt));
        const breakEnd = Math.min(end, Number(b.endAt));
        if (!Number.isFinite(breakStart) || !Number.isFinite(breakEnd)) continue;
        durationMs -= Math.max(0, breakEnd - breakStart);
      }
      return sum + Math.max(0, durationMs) / 3600000;
    }, 0);
  const round2 = (n: number) => Math.round(n * 100) / 100;

  // Build a profileId → entries index in O(N) so each staff member lookup is O(1).
  // This replaces the previous O(N×M) entries.filter() inside staff.map().
  const entriesByProfile = new Map<string, typeof entries>();
  for (const entry of entries) {
    if (!entry.profileId || !inPeriod(entry)) continue;
    const list = entriesByProfile.get(entry.profileId) ?? [];
    list.push(entry);
    entriesByProfile.set(entry.profileId, list);
  }

  const rows = staff.map((member) => ({
    profileId: member.id as string | null,
    employeeName: member.fullName,
    role: member.role as string,
    jobTitle: member.jobTitle,
    payrollEmployeeId: member.payrollEmployeeId ?? null,
    regularHours: round2(hoursOf(entriesByProfile.get(member.id) ?? [])),
  })).map((row) => ({
    ...row,
    totalHours: row.regularHours,
  }));

  // Wage records retained after account deletion (profileId is null) still
  // belong on payroll — group them by the snapshotted name.
  const formerByName = new Map<string, typeof entries>();
  for (const e of entries) {
    if (e.profileId !== null || !inPeriod(e)) continue;
    const name = e.profileFullName ?? 'Former staff';
    formerByName.set(name, [...(formerByName.get(name) ?? []), e]);
  }
  for (const [name, rowsForName] of formerByName) {
      rows.push({
        profileId: null,
        employeeName: name,
        role: 'staff',
        jobTitle: 'Former staff',
        payrollEmployeeId: null,
        regularHours: round2(hoursOf(rowsForName)),
        totalHours: round2(hoursOf(rowsForName)),
      });
    }

  return rows;
}

@Controller('v1/payroll')
export class PayrollController {
  constructor(
    private readonly prisma: PrismaService,
    private readonly gusto: GustoPayrollService,
    private readonly connect: PayrollConnectService,
  ) {}

  private requireManager(scope: Scope): asserts scope is NonNullable<Scope> {
    if (!scope || !canManageVenue(scope.role, scope.allAccess)) throw new ForbiddenException('Not authorized');
  }

  @RequireSubscription('paid')
  @Get('summary')
  async getPayrollSummary(
    @VenueScope() scope: Scope,
    @Query('startDate') startDate?: string,
    @Query('endDate') endDate?: string,
  ) {
    this.requireManager(scope);
    const { periodStart, periodEnd, startIso, endIso } = await resolvePayrollPeriod(this.prisma, scope.venueId, startDate, endDate);

    const [rows, links] = await Promise.all([
      buildPayrollRows(this.prisma, scope.venueId, periodStart, periodEnd),
      this.prisma.payrollEmployeeMap.findMany({ where: { venueId: scope.venueId }, select: { profileId: true, provider: true, externalId: true } }),
    ]);
    const totalHours = Math.round(rows.reduce((sum, r) => sum + r.totalHours, 0) * 100) / 100;

    return {
      byEmployee: rows,
      payrollLinks: links,
      totals: {
        totalHours,
        employeeCount: rows.filter((r) => r.totalHours > 0).length,
        periodStart: periodStart.getTime(),
        periodEnd: periodEnd.getTime(),
        startDate: startIso,
        endDate: endIso,
      },
    };
  }

  @RequireSubscription('paid')
  @Audited('payroll.export', { entityType: 'payroll', summary: 'Exported payroll CSV' })
  @Get('export-csv')
  @Header('Content-Type', 'text/csv; charset=utf-8')
  @Header('Content-Disposition', 'attachment; filename="payroll.csv"')
  async exportPayrollCsv(
    @VenueScope() scope: Scope,
    @Query('startDate') startDate?: string,
    @Query('endDate') endDate?: string,
  ) {
    this.requireManager(scope);
    const { periodStart, periodEnd, startIso, endIso } = await resolvePayrollPeriod(this.prisma, scope.venueId, startDate, endDate);

    const rows = await buildPayrollRows(this.prisma, scope.venueId, periodStart, periodEnd);
    const headers = ['Employee', 'Role', 'Regular Hours', 'Total Hours', 'Start Date', 'End Date'];
    const csvRows = [headers.map(csvCell).join(',')];
    for (const row of rows) {
      csvRows.push([
        csvCell(row.employeeName),
        csvCell(row.role),
        csvCell((row as { regularHours?: number }).regularHours ?? row.totalHours),
        csvCell(row.totalHours),
        csvCell(startIso),
        csvCell(endIso),
      ].join(','));
    }
    return csvDocument(csvRows);
  }

  @RequireSubscription('paid')
  @Post('record-export')
  async recordPayrollExport(@VenueScope() scope: Scope, @Body() body: RecordPayrollExportDto) {
    this.requireManager(scope);
    const periodStart = new Date(body.periodStart);
    const periodEnd = new Date(body.periodEnd);
    if (isNaN(periodStart.getTime()) || isNaN(periodEnd.getTime())) {
      throw new BadRequestException('Invalid period dates');
    }
    const record = await this.prisma.payrollExport.create({
      data: {
        venueId: scope.venueId,
        provider: body.provider,
        periodStart,
        periodEnd,
        rowCount: body.rowCount ?? 0,
        totalHours: body.totalHours ?? 0,
        createdBy: scope.profileId,
      },
    });
    return { id: record.id };
  }

  @RequireSubscription('paid')
  @Post('gusto/authorize')
  gustoAuthorize(@VenueScope() scope: Scope) {
    this.requireManager(scope);
    return this.gusto.authorize(scope);
  }

  @Public()
  @SkipVenueScope()
  @Get('gusto/callback')
  async gustoCallback(@Query('code') code: string | undefined, @Query('state') state: string | undefined, @Res() res: Response) {
    try {
      await this.gusto.completeCallback(code ?? '', state ?? '');
      res.redirect(302, 'venuewrangler://payroll?gusto=connected');
    } catch (error) {
      const message = error instanceof Error ? error.message : 'Gusto connection failed';
      res.status(400).type('html').send(`<!doctype html><p>${escapeHtml(message)}</p>`);
    }
  }

  @RequireSubscription('paid')
  @Audited('payroll.gusto_push', { entityType: 'payroll', summary: 'Pushed hours to Gusto' })
  @Post('gusto/push')
  async pushGusto(@VenueScope() scope: Scope, @Body() body: PushPayrollDto) {
    this.requireManager(scope);
    const period = await resolvePayrollPeriod(this.prisma, scope.venueId, body.startDate, body.endDate);
    return this.gusto.push(scope, period);
  }

  @RequireSubscription('paid')
  @Audited('payroll.employee_mapped', { entityType: 'profile', summary: 'Mapped a Gusto employee id' })
  @Post('gusto/mappings')
  mapPayrollEmployee(@VenueScope() scope: Scope, @Body() body: MapPayrollEmployeeDto) {
    this.requireManager(scope);
    return this.gusto.mapEmployee(scope, body.profileId, body.payrollEmployeeId);
  }

  @RequireSubscription('paid')
  @Post('connect/authorize')
  authorizeProvider(@VenueScope() scope: Scope, @Body() body: ProviderDto) {
    this.requireManager(scope);
    if (body.provider === 'gusto') return this.gusto.authorize(scope);
    return this.connect.authorize(scope, body.provider);
  }

  @Public()
  @SkipVenueScope()
  @Get('connect/callback')
  async connectCallback(
    @Query('code') code: string | undefined,
    @Query('state') state: string | undefined,
    @Query('realmId') realmId: string | undefined,
    @Res() res: Response,
  ) {
    try {
      const provider = await this.connect.completeCallback(code ?? '', state ?? '', realmId);
      const target = provider === 'gusto' ? await this.gusto.completeCallback(code ?? '', state ?? '').then(() => 'gusto') : provider;
      res.redirect(302, `venuewrangler://payroll?provider=${encodeURIComponent(target)}`);
    } catch (error) {
      const message = error instanceof Error ? error.message : 'Payroll connection failed';
      res.status(400).type('html').send(`<!doctype html><p>${escapeHtml(message)}</p>`);
    }
  }

  @RequireSubscription('paid')
  @Audited('payroll.provider_push', { entityType: 'payroll', summary: 'Pushed hours to a payroll provider' })
  @Post('connect/push')
  async pushProvider(@VenueScope() scope: Scope, @Body() body: ProviderPushDto) {
    this.requireManager(scope);
    const unavailable = hoursPushUnavailable(body.provider);
    if (unavailable) throw new BadRequestException(unavailable);
    const period = await resolvePayrollPeriod(this.prisma, scope.venueId, body.startDate, body.endDate);
    if (body.provider === 'gusto') return this.gusto.push(scope, period);
    if (!isHoursPushProvider(body.provider)) throw new BadRequestException(unavailable);
    return this.connect.push(scope, body.provider, period);
  }

  @RequireSubscription('paid')
  @Audited('payroll.provider_mapped', { entityType: 'profile', summary: 'Mapped a payroll employee id' })
  @Post('connect/mappings')
  mapProviderEmployee(@VenueScope() scope: Scope, @Body() body: ProviderMapDto) {
    this.requireManager(scope);
    if (body.provider === 'gusto') return this.gusto.mapEmployee(scope, body.profileId, body.payrollEmployeeId);
    return this.connect.mapEmployee(scope, body.provider, body.profileId, body.payrollEmployeeId);
  }
}

function escapeHtml(value: string): string {
  return value.replace(/[&<>"']/g, (ch) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[ch] ?? ch));
}

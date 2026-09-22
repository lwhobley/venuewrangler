import { BadRequestException, Injectable, Logger, ServiceUnavailableException } from '@nestjs/common';
import { zonedIsoDate } from '../../common/venue-time';
import { PrismaService } from '../../prisma/prisma.service';
import { runWithoutTenant } from '../../prisma/tenant-context';
import { overlapsPeriod, roundHours, workedHours } from './gusto-hours';
import { decryptPayrollSecret, encryptPayrollSecret, readPayrollState, signPayrollState } from './payroll-crypto';
import { externalIdPattern, hoursPushUnavailable, isHoursPushProvider, providerLabel, type HoursPushProvider } from './payroll-providers';
import { QuickBooksClient } from './quickbooks-client';
import { SquareClient } from './square-client';

const PUSH_BATCH = 100;
const CLAIM_STALE_MS = 15 * 60 * 1000;

type Scope = { venueId: string; profileId: string };
type Punch = {
  id: string;
  employeeName: string;
  externalId: string | null;
  clockInAt: Date;
  clockOutAt: Date;
  hours: number;
  txnDate: string;
};

@Injectable()
export class PayrollConnectService {
  private readonly logger = new Logger(PayrollConnectService.name);

  constructor(
    private readonly prisma: PrismaService,
    private readonly quickbooks: QuickBooksClient,
    private readonly square: SquareClient,
  ) {}

  authorize(scope: Scope, provider: string): { url: string } {
    const unavailable = hoursPushUnavailable(provider);
    if (unavailable) throw new BadRequestException(unavailable);
    if (provider === 'gusto') throw new BadRequestException('Use the Gusto connect route');
    try {
      const state = signPayrollState({ venueId: scope.venueId, provider, exp: Date.now() + 10 * 60 * 1000 });
      const url = provider === 'quickbooks_payroll' ? this.quickbooks.authorizeUrl(state) : this.square.authorizeUrl(state);
      return { url };
    } catch (error) {
      throw new ServiceUnavailableException(error instanceof Error ? error.message : 'Payroll provider is not configured');
    }
  }

  async completeCallback(code: string, state: string, realmId?: string): Promise<string> {
    if (!code || !state) throw new BadRequestException('Payroll provider did not return a code');
    const parsed = readPayrollState(state);
    if (parsed.provider === 'gusto') return 'gusto';
    if (!isHoursPushProvider(parsed.provider)) throw new BadRequestException(hoursPushUnavailable(parsed.provider) ?? 'Unsupported provider');
    const tokens = parsed.provider === 'quickbooks_payroll'
      ? await this.quickbooks.exchangeCode(code)
      : await this.square.exchangeCode(code);
    const companyUuid = parsed.provider === 'quickbooks_payroll'
      ? realmId?.trim() || ''
      : await this.square.primaryLocationId(tokens.accessToken) ?? '';
    if (!companyUuid) {
      throw new BadRequestException(parsed.provider === 'quickbooks_payroll'
        ? 'QuickBooks did not return a company id'
        : 'Square did not return a location');
    }
    await runWithoutTenant(() => this.prisma.payrollConnection.upsert({
      where: { venueId_provider: { venueId: parsed.venueId, provider: parsed.provider } },
      create: {
        venueId: parsed.venueId,
        provider: parsed.provider,
        companyUuid,
        accessTokenCipher: encryptPayrollSecret(tokens.accessToken),
        refreshTokenCipher: encryptPayrollSecret(tokens.refreshToken),
        tokenExpiresAt: tokens.expiresAt,
        status: 'connected',
      },
      update: {
        companyUuid,
        accessTokenCipher: encryptPayrollSecret(tokens.accessToken),
        refreshTokenCipher: encryptPayrollSecret(tokens.refreshToken),
        tokenExpiresAt: tokens.expiresAt,
        status: 'connected',
      },
    }));
    return parsed.provider;
  }

  async mapEmployee(scope: Scope, provider: string, profileId: string, externalId: string | null | undefined): Promise<{ payrollEmployeeId: string | null }> {
    if (!isHoursPushProvider(provider) || provider === 'gusto') {
      throw new BadRequestException(hoursPushUnavailable(provider) ?? 'Use the Gusto mapping route');
    }
    const next = externalId?.trim() || null;
    if (next && !externalIdPattern(provider).test(next)) {
      throw new BadRequestException(`${providerLabel(provider)} employee id is not in the expected format`);
    }
    const profile = await this.prisma.profile.findFirst({ where: { id: profileId, venueId: scope.venueId } });
    if (!profile) throw new BadRequestException('Staff member was not found');
    if (!next) {
      await this.prisma.payrollEmployeeMap.deleteMany({ where: { venueId: scope.venueId, profileId, provider } });
      return { payrollEmployeeId: null };
    }
    try {
      await this.prisma.payrollEmployeeMap.upsert({
        where: { venueId_profileId_provider: { venueId: scope.venueId, profileId, provider } },
        create: { venueId: scope.venueId, profileId, provider, externalId: next },
        update: { externalId: next },
      });
    } catch (error) {
      if (typeof error === 'object' && error && 'code' in error && (error as { code?: string }).code === 'P2002') {
        throw new BadRequestException('That employee id is already mapped to someone else');
      }
      throw error;
    }
    return { payrollEmployeeId: next };
  }

  async push(scope: Scope, provider: HoursPushProvider, period: { periodStart: Date; periodEnd: Date }): Promise<{ sent: number; remaining: number; totalHours: number }> {
    if (provider === 'gusto') throw new BadRequestException('Use the Gusto push route');
    const venue = await this.prisma.venue.findUnique({ where: { id: scope.venueId }, select: { timezone: true } });
    const punches = await this.loadPunches(scope.venueId, provider, venue?.timezone ?? null, period.periodStart, period.periodEnd);
    const blocked = punches.filter((punch) => !punch.externalId);
    if (blocked.length > 0) {
      const names = [...new Set(blocked.map((punch) => punch.employeeName))].join(', ');
      throw new BadRequestException(`Cannot push payroll. These people have hours and no ${providerLabel(provider)} employee id: ${names}. Map them before pushing. No hours were sent.`);
    }
    const connection = await this.prisma.payrollConnection.findFirst({ where: { venueId: scope.venueId, provider, status: 'connected' } });
    if (!connection) throw new BadRequestException(`Connect ${providerLabel(provider)} before pushing hours. No hours were sent.`);
    const accessToken = await this.freshAccessToken(provider, connection);
    const batch = punches.slice(0, PUSH_BATCH);
    let sent = 0;
    let totalHours = 0;
    for (const punch of batch) {
      const claimed = await this.claim(scope.venueId, provider, punch.id);
      if (!claimed) continue;
      try {
        const externalId = provider === 'quickbooks_payroll'
          ? (await this.quickbooks.createTimeActivity(accessToken, connection.companyUuid, {
            TxnDate: punch.txnDate,
            EmployeeRef: { value: punch.externalId! },
            StartTime: punch.clockInAt.toISOString(),
            EndTime: punch.clockOutAt.toISOString(),
          })).id
          : (await this.square.createTimecard(accessToken, {
            idempotencyKey: punch.id,
            teamMemberId: punch.externalId!,
            locationId: connection.companyUuid,
            startAt: punch.clockInAt.toISOString(),
            endAt: punch.clockOutAt.toISOString(),
          })).id;
        await this.prisma.payrollTimeSheetPush.updateMany({
          where: { venueId: scope.venueId, provider, timeEntryId: punch.id },
          data: { externalId: externalId || 'sent' },
        });
        sent += 1;
        totalHours = roundHours(totalHours + punch.hours);
      } catch (error) {
        await this.prisma.payrollTimeSheetPush.deleteMany({ where: { venueId: scope.venueId, provider, timeEntryId: punch.id, externalId: null } });
        this.logger.warn(`${provider} push failed for ${punch.id}: ${error instanceof Error ? error.message : String(error)}`);
        throw new BadRequestException(`${providerLabel(provider)} rejected a time entry for ${punch.employeeName}. Hours already accepted were kept. Retry to send the rest.`);
      }
    }
    const remaining = Math.max(0, punches.length - batch.length);
    if (remaining === 0 && sent > 0) {
      await this.prisma.payrollExport.create({
        data: {
          venueId: scope.venueId,
          provider,
          periodStart: period.periodStart,
          periodEnd: period.periodEnd,
          rowCount: sent,
          totalHours,
          createdBy: scope.profileId,
          externalRef: provider,
        },
      });
    }
    return { sent, remaining, totalHours };
  }

  private async loadPunches(venueId: string, provider: string, timezone: string | null, periodStart: Date, periodEnd: Date): Promise<Punch[]> {
    const [profiles, maps, entries, already] = await Promise.all([
      this.prisma.profile.findMany({ where: { venueId }, select: { id: true, fullName: true } }),
      this.prisma.payrollEmployeeMap.findMany({ where: { venueId, provider }, select: { profileId: true, externalId: true } }),
      this.prisma.timeEntry.findMany({
        where: { venueId, clockInAt: { lt: periodEnd }, clockOutAt: { not: null, gt: periodStart } },
        orderBy: { clockInAt: 'asc' },
      }),
      this.prisma.payrollTimeSheetPush.findMany({
        where: { venueId, provider, externalId: { not: null } },
        select: { timeEntryId: true },
      }),
    ]);
    const pushed = new Set(already.map((row) => row.timeEntryId));
    const people = new Map(profiles.map((profile) => [profile.id, profile.fullName]));
    const ids = new Map(maps.map((row) => [row.profileId, row.externalId]));
    const punches: Punch[] = [];
    for (const entry of entries) {
      if (!entry.clockOutAt || pushed.has(entry.id) || !overlapsPeriod(entry, periodStart, periodEnd)) continue;
      const hours = workedHours(entry);
      if (hours <= 0) continue;
      punches.push({
        id: entry.id,
        employeeName: (entry.profileId && people.get(entry.profileId)) || entry.profileFullName || 'Former staff',
        externalId: entry.profileId ? ids.get(entry.profileId) ?? null : null,
        clockInAt: entry.clockInAt,
        clockOutAt: entry.clockOutAt,
        hours,
        txnDate: zonedIsoDate(timezone, entry.clockInAt.getTime()),
      });
    }
    return punches;
  }

  private async claim(venueId: string, provider: string, timeEntryId: string): Promise<boolean> {
    await this.prisma.payrollTimeSheetPush.deleteMany({
      where: { venueId, provider, timeEntryId, externalId: null, createdAt: { lt: new Date(Date.now() - CLAIM_STALE_MS) } },
    });
    try {
      await this.prisma.payrollTimeSheetPush.create({ data: { venueId, provider, timeEntryId } });
      return true;
    } catch (error) {
      if (typeof error === 'object' && error && 'code' in error && (error as { code?: string }).code === 'P2002') return false;
      throw error;
    }
  }

  private async freshAccessToken(provider: HoursPushProvider, connection: { id: string; accessTokenCipher: string; refreshTokenCipher: string; tokenExpiresAt: Date }): Promise<string> {
    if (connection.tokenExpiresAt.getTime() - Date.now() > 60_000) return decryptPayrollSecret(connection.accessTokenCipher);
    const tokens = provider === 'quickbooks_payroll'
      ? await this.quickbooks.refresh(decryptPayrollSecret(connection.refreshTokenCipher))
      : await this.square.refresh(decryptPayrollSecret(connection.refreshTokenCipher));
    await this.prisma.payrollConnection.update({
      where: { id: connection.id },
      data: {
        accessTokenCipher: encryptPayrollSecret(tokens.accessToken),
        refreshTokenCipher: encryptPayrollSecret(tokens.refreshToken),
        tokenExpiresAt: tokens.expiresAt,
      },
    });
    return tokens.accessToken;
  }
}

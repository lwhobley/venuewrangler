import { BadRequestException, Injectable, Logger, ServiceUnavailableException } from '@nestjs/common';
import { PrismaService } from '../../prisma/prisma.service';
import { runWithoutTenant } from '../../prisma/tenant-context';
import { GustoClient, type GustoTimeSheet } from './gusto-client';
import { zonedDateBounds } from '../../common/venue-time';
import { classifyAgainstWeek, overlapsPeriod, roundHours, weekKey, workedHours, type PunchHours } from './gusto-hours';
import { decryptPayrollSecret, encryptPayrollSecret, readPayrollState, signPayrollState } from './payroll-crypto';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const PUSH_BATCH = 100;
const CLAIM_STALE_MS = 15 * 60 * 1000;

type Scope = { venueId: string; profileId: string };

@Injectable()
export class GustoPayrollService {
  private readonly logger = new Logger(GustoPayrollService.name);

  constructor(
    private readonly prisma: PrismaService,
    private readonly gusto: GustoClient,
  ) {}

  authorize(scope: Scope): { url: string } {
    try {
      const state = signPayrollState({ venueId: scope.venueId, provider: 'gusto', exp: Date.now() + 10 * 60 * 1000 });
      return { url: this.gusto.authorizeUrl(state) };
    } catch (error) {
      throw new ServiceUnavailableException(error instanceof Error ? error.message : 'Gusto is not configured');
    }
  }

  async completeCallback(code: string, state: string): Promise<void> {
    if (!code || !state) throw new BadRequestException('Gusto did not return a code');
    let venueId: string;
    try {
      venueId = readPayrollState(state).venueId;
    } catch (error) {
      throw new BadRequestException(error instanceof Error ? error.message : 'Gusto state is invalid');
    }
    const tokens = await this.gusto.exchangeCode(code);
    const companyUuid = await this.gusto.companyUuid(tokens.accessToken);
    await runWithoutTenant(() => this.prisma.payrollConnection.upsert({
      where: { venueId_provider: { venueId, provider: 'gusto' } },
      create: {
        venueId,
        provider: 'gusto',
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
  }

  async mapEmployee(scope: Scope, profileId: string, payrollEmployeeId: string | null | undefined): Promise<{ payrollEmployeeId: string | null }> {
    const next = payrollEmployeeId?.trim() || null;
    if (next && !UUID.test(next)) throw new BadRequestException('Gusto employee id must be a UUID');
    const profile = await this.prisma.profile.findFirst({ where: { id: profileId, venueId: scope.venueId } });
    if (!profile) throw new BadRequestException('Staff member was not found');
    try {
      await this.prisma.profile.update({ where: { id: profile.id }, data: { payrollEmployeeId: next } });
    } catch (error) {
      if (typeof error === 'object' && error && 'code' in error && (error as { code?: string }).code === 'P2002') {
        throw new BadRequestException('That Gusto employee id is already mapped to someone else');
      }
      throw error;
    }
    return { payrollEmployeeId: next };
  }

  async push(scope: Scope, period: { periodStart: Date; periodEnd: Date }): Promise<{ sent: number; remaining: number; totalHours: number }> {
    const venue = await this.prisma.venue.findUnique({ where: { id: scope.venueId }, select: { timezone: true } });
    const timezone = venue?.timezone ?? null;
    const punches = await this.loadPunches(scope.venueId, timezone, period.periodStart, period.periodEnd);
    const blocked = punches.filter((punch) => punch.hours > 0 && !punch.payrollEmployeeId);
    if (blocked.length > 0) {
      const names = [...new Set(blocked.map((punch) => punch.employeeName))].join(', ');
      throw new BadRequestException(`Cannot push payroll. These people have hours and no Gusto employee id: ${names}. Map them before pushing. No hours were sent.`);
    }

    const connection = await this.prisma.payrollConnection.findFirst({ where: { venueId: scope.venueId, provider: 'gusto', status: 'connected' } });
    if (!connection) throw new BadRequestException('Connect Gusto before pushing hours. No hours were sent.');

    const accessToken = await this.freshAccessToken(connection);
    const jobs = new Map<string, string>();
    for (const punch of punches) {
      if (punch.hours <= 0 || !punch.payrollEmployeeId || jobs.has(punch.payrollEmployeeId)) continue;
      let jobUuid: string | null = null;
      try {
        jobUuid = await this.gusto.primaryJobUuid(accessToken, punch.payrollEmployeeId);
      } catch (error) {
        this.logger.warn(`Gusto job lookup failed for ${punch.profileId}: ${error instanceof Error ? error.message : String(error)}`);
        throw new BadRequestException(`Cannot push payroll. Gusto could not confirm a job for ${punch.employeeName}. No hours were sent.`);
      }
      if (!jobUuid) {
        throw new BadRequestException(`Cannot push payroll. Gusto has no job for ${punch.employeeName}. No hours were sent.`);
      }
      jobs.set(punch.payrollEmployeeId, jobUuid);
    }

    const pending = punches.filter((punch) => punch.hours > 0);
    const batch = pending.slice(0, PUSH_BATCH);
    let sent = 0;
    let totalHours = 0;
    for (const punch of batch) {
      const claimed = await this.claim(scope.venueId, punch.id);
      if (!claimed) continue;
      const sheet = this.sheetFor(punch, timezone, jobs.get(punch.payrollEmployeeId!)!);
      try {
        const created = await this.gusto.createTimeSheet(accessToken, connection.companyUuid, sheet);
        await this.prisma.payrollTimeSheetPush.updateMany({
          where: { venueId: scope.venueId, provider: 'gusto', timeEntryId: punch.id },
          data: { externalId: created.uuid || 'sent' },
        });
        sent += 1;
        totalHours = roundHours(totalHours + punch.hours);
      } catch (error) {
        await this.prisma.payrollTimeSheetPush.deleteMany({ where: { venueId: scope.venueId, provider: 'gusto', timeEntryId: punch.id, externalId: null } });
        this.logger.warn(`Gusto push failed for ${punch.id}: ${error instanceof Error ? error.message : String(error)}`);
        throw new BadRequestException(`Gusto rejected a time sheet for ${punch.employeeName}. Hours already accepted were kept. Retry to send the rest.`);
      }
    }

    const remaining = Math.max(0, pending.length - batch.length);
    if (remaining === 0 && sent > 0) {
      await this.prisma.payrollExport.create({
        data: {
          venueId: scope.venueId,
          provider: 'gusto',
          periodStart: period.periodStart,
          periodEnd: period.periodEnd,
          rowCount: sent,
          totalHours,
          createdBy: scope.profileId,
          externalRef: 'gusto-time-sheets',
        },
      });
    }
    return { sent, remaining, totalHours };
  }

  private async loadPunches(venueId: string, timezone: string | null, periodStart: Date, periodEnd: Date): Promise<PunchHours[]> {
    const loadStart = new Date(zonedDateBounds(timezone, weekKey(timezone, periodStart)).start);
    const [profiles, entries, already] = await Promise.all([
      this.prisma.profile.findMany({ where: { venueId }, select: { id: true, fullName: true, payrollEmployeeId: true } }),
      this.prisma.timeEntry.findMany({
        where: { venueId, clockInAt: { lt: periodEnd }, clockOutAt: { not: null, gt: loadStart } },
        orderBy: { clockInAt: 'asc' },
      }),
      this.prisma.payrollTimeSheetPush.findMany({
        where: { venueId, provider: 'gusto', externalId: { not: null } },
        select: { timeEntryId: true },
      }),
    ]);
    const pushed = new Set(already.map((row) => row.timeEntryId));
    const people = new Map(profiles.map((profile) => [profile.id, profile]));
    const weekHours = new Map<string, number>();
    const punches: PunchHours[] = [];
    for (const entry of entries) {
      if (!entry.clockOutAt) continue;
      const hours = workedHours(entry);
      if (hours <= 0) continue;
      const person = entry.profileId ? people.get(entry.profileId) : undefined;
      const key = `${entry.profileId ?? entry.profileFullName ?? 'former'}:${weekKey(timezone, entry.clockInAt)}`;
      const soFar = weekHours.get(key) ?? 0;
      const split = classifyAgainstWeek(hours, soFar);
      weekHours.set(key, soFar + hours);
      if (pushed.has(entry.id) || !overlapsPeriod(entry, periodStart, periodEnd)) continue;
      punches.push({
        id: entry.id,
        profileId: entry.profileId,
        employeeName: person?.fullName ?? entry.profileFullName ?? 'Former staff',
        payrollEmployeeId: person?.payrollEmployeeId ?? null,
        clockInAt: entry.clockInAt,
        clockOutAt: entry.clockOutAt,
        hours,
        regular: split.regular,
        overtime: split.overtime,
      });
    }
    return punches;
  }

  private sheetFor(punch: PunchHours, timezone: string | null, jobUuid: string): GustoTimeSheet {
    const entries: GustoTimeSheet['entries'] = [];
    if (punch.regular > 0) entries.push({ hours_worked: punch.regular, pay_classification: 'Regular' });
    if (punch.overtime > 0) entries.push({ hours_worked: punch.overtime, pay_classification: 'Overtime' });
    return {
      entity_uuid: punch.payrollEmployeeId!,
      entity_type: 'Employee',
      job_uuid: jobUuid,
      time_zone: timezone || 'UTC',
      shift_started_at: punch.clockInAt.toISOString(),
      shift_ended_at: punch.clockOutAt.toISOString(),
      entries,
    };
  }

  private async claim(venueId: string, timeEntryId: string): Promise<boolean> {
    await this.prisma.payrollTimeSheetPush.deleteMany({
      where: { venueId, provider: 'gusto', timeEntryId, externalId: null, createdAt: { lt: new Date(Date.now() - CLAIM_STALE_MS) } },
    });
    try {
      await this.prisma.payrollTimeSheetPush.create({ data: { venueId, provider: 'gusto', timeEntryId } });
      return true;
    } catch (error) {
      if (typeof error === 'object' && error && 'code' in error && (error as { code?: string }).code === 'P2002') return false;
      throw error;
    }
  }

  private async freshAccessToken(connection: { id: string; accessTokenCipher: string; refreshTokenCipher: string; tokenExpiresAt: Date }): Promise<string> {
    if (connection.tokenExpiresAt.getTime() - Date.now() > 60_000) return decryptPayrollSecret(connection.accessTokenCipher);
    const tokens = await this.gusto.refresh(decryptPayrollSecret(connection.refreshTokenCipher));
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

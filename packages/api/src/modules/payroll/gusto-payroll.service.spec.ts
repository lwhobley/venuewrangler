import { BadRequestException } from '@nestjs/common';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { GustoPayrollService } from './gusto-payroll.service';
import { encryptPayrollSecret } from './payroll-crypto';

const VENUE = 'venue-1';
const SCOPE = { venueId: VENUE, profileId: 'manager-1' };
const PERIOD = {
  periodStart: new Date('2026-09-21T00:00:00.000Z'),
  periodEnd: new Date('2026-09-24T00:00:00.000Z'),
};
const EMPLOYEE = '11111111-1111-1111-1111-111111111111';

function punch(id: string, start: string, end: string, profileId: string | null = 'profile-1', name: string | null = 'Ada Lovelace') {
  return {
    id,
    venueId: VENUE,
    profileId,
    profileFullName: name,
    clockInAt: new Date(start),
    clockOutAt: new Date(end),
    breaks: null,
  };
}

function harness(entries: unknown[], opts?: { payrollEmployeeId?: string | null; pushed?: string[]; profiles?: unknown[] }) {
  process.env.PAYROLL_TOKEN_KEY = 'test-payroll-token-key-32chars-min';
  const prisma = {
    venue: { findUnique: vi.fn().mockResolvedValue({ timezone: 'UTC' }) },
    profile: {
      findMany: vi.fn().mockResolvedValue(opts?.profiles ?? [{
        id: 'profile-1',
        fullName: 'Ada Lovelace',
        payrollEmployeeId: opts?.payrollEmployeeId === undefined ? EMPLOYEE : opts.payrollEmployeeId,
      }]),
      findFirst: vi.fn(),
      update: vi.fn(),
    },
    timeEntry: { findMany: vi.fn().mockResolvedValue(entries) },
    payrollTimeSheetPush: {
      findMany: vi.fn().mockResolvedValue((opts?.pushed ?? []).map((timeEntryId) => ({ timeEntryId }))),
      deleteMany: vi.fn().mockResolvedValue({ count: 1 }),
      create: vi.fn().mockResolvedValue({ id: 'claim-1' }),
      updateMany: vi.fn().mockResolvedValue({ count: 1 }),
    },
    payrollConnection: {
      findFirst: vi.fn().mockResolvedValue({
        id: 'conn-1',
        companyUuid: 'company-1',
        accessTokenCipher: encryptPayrollSecret('access'),
        refreshTokenCipher: encryptPayrollSecret('refresh'),
        tokenExpiresAt: new Date(Date.now() + 60 * 60 * 1000),
        status: 'connected',
      }),
    },
    payrollExport: { create: vi.fn().mockResolvedValue({ id: 'export-1' }) },
  };
  const gusto = {
    primaryJobUuid: vi.fn().mockResolvedValue('job-1'),
    createTimeSheet: vi.fn().mockResolvedValue({ uuid: 'sheet-1' }),
    refresh: vi.fn(),
  };
  const service = new GustoPayrollService(prisma as never, gusto as never);
  return { prisma, gusto, service };
}

describe('GustoPayrollService.push', () => {
  afterEach(() => {
    delete process.env.PAYROLL_TOKEN_KEY;
  });

  it('refuses unmapped people with hours before calling Gusto', async () => {
    const { gusto, prisma, service } = harness([
      punch('entry-1', '2026-09-21T09:00:00.000Z', '2026-09-21T17:00:00.000Z'),
    ], { payrollEmployeeId: null });

    await expect(service.push(SCOPE, PERIOD)).rejects.toThrow(/no Gusto employee id: Ada Lovelace/);
    expect(gusto.createTimeSheet).not.toHaveBeenCalled();
    expect(gusto.primaryJobUuid).not.toHaveBeenCalled();
    expect(prisma.payrollTimeSheetPush.create).not.toHaveBeenCalled();
    expect(prisma.payrollExport.create).not.toHaveBeenCalled();
  });

  it('refuses former staff hours that cannot be mapped', async () => {
    const { gusto, service } = harness([
      punch('entry-1', '2026-09-21T09:00:00.000Z', '2026-09-21T17:00:00.000Z', null, 'Gone Staff'),
    ], { profiles: [] });

    await expect(service.push(SCOPE, PERIOD)).rejects.toBeInstanceOf(BadRequestException);
    await expect(service.push(SCOPE, PERIOD)).rejects.toThrow(/Gone Staff/);
    expect(gusto.createTimeSheet).not.toHaveBeenCalled();
  });

  it('classifies hours over 40 in the venue week as overtime and ignores any client total', async () => {
    const { gusto, service } = harness([
      punch('already', '2026-09-21T00:00:00.000Z', '2026-09-22T08:00:00.000Z'),
      punch('next', '2026-09-22T18:00:00.000Z', '2026-09-23T04:00:00.000Z'),
    ], { pushed: ['already'] });

    await expect(service.push(SCOPE, PERIOD)).resolves.toMatchObject({ sent: 1, remaining: 0 });
    expect(gusto.createTimeSheet).toHaveBeenCalledWith('access', 'company-1', expect.objectContaining({
      entity_uuid: EMPLOYEE,
      job_uuid: 'job-1',
      entries: [
        { hours_worked: 8, pay_classification: 'Regular' },
        { hours_worked: 2, pay_classification: 'Overtime' },
      ],
    }));
  });

  it('releases the claim and does not record an export when Gusto rejects the sheet', async () => {
    const { gusto, prisma, service } = harness([
      punch('entry-1', '2026-09-21T09:00:00.000Z', '2026-09-21T17:00:00.000Z'),
    ]);
    gusto.createTimeSheet.mockRejectedValue(new Error('Gusto time sheet failed (422)'));

    await expect(service.push(SCOPE, PERIOD)).rejects.toThrow(/Gusto rejected/);
    expect(prisma.payrollTimeSheetPush.deleteMany).toHaveBeenCalledWith({
      where: { venueId: VENUE, provider: 'gusto', timeEntryId: 'entry-1', externalId: null },
    });
    expect(prisma.payrollExport.create).not.toHaveBeenCalled();
  });
});

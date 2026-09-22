import { BadRequestException } from '@nestjs/common';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { PayrollConnectService } from './payroll-connect.service';
import { encryptPayrollSecret } from './payroll-crypto';

const SCOPE = { venueId: 'venue-1', profileId: 'manager-1' };
const PERIOD = {
  periodStart: new Date('2026-09-21T00:00:00.000Z'),
  periodEnd: new Date('2026-09-24T00:00:00.000Z'),
};

function harness(entries: unknown[] = []) {
  process.env.PAYROLL_TOKEN_KEY = 'test-payroll-token-key-32chars-min';
  const prisma = {
    venue: { findUnique: vi.fn().mockResolvedValue({ timezone: 'UTC' }) },
    profile: { findMany: vi.fn().mockResolvedValue([{ id: 'profile-1', fullName: 'Ada Lovelace' }]), findFirst: vi.fn() },
    payrollEmployeeMap: { findMany: vi.fn().mockResolvedValue([{ profileId: 'profile-1', externalId: 'tm-1' }]) },
    timeEntry: { findMany: vi.fn().mockResolvedValue(entries) },
    payrollTimeSheetPush: {
      findMany: vi.fn().mockResolvedValue([]),
      deleteMany: vi.fn().mockResolvedValue({ count: 0 }),
      create: vi.fn().mockResolvedValue({ id: 'claim-1' }),
      updateMany: vi.fn().mockResolvedValue({ count: 1 }),
    },
    payrollConnection: {
      findFirst: vi.fn().mockResolvedValue({
        id: 'conn-1',
        companyUuid: 'loc-1',
        accessTokenCipher: encryptPayrollSecret('access'),
        refreshTokenCipher: encryptPayrollSecret('refresh'),
        tokenExpiresAt: new Date(Date.now() + 60 * 60 * 1000),
      }),
    },
    payrollExport: { create: vi.fn().mockResolvedValue({ id: 'export-1' }) },
  };
  const quickbooks = { createTimeActivity: vi.fn(), exchangeCode: vi.fn(), refresh: vi.fn(), authorizeUrl: vi.fn() };
  const square = {
    createTimecard: vi.fn().mockResolvedValue({ id: 'card-1' }),
    exchangeCode: vi.fn(),
    refresh: vi.fn(),
    authorizeUrl: vi.fn(),
    primaryLocationId: vi.fn(),
  };
  const service = new PayrollConnectService(prisma as never, quickbooks as never, square as never);
  return { prisma, square, service };
}

describe('PayrollConnectService', () => {
  afterEach(() => {
    delete process.env.PAYROLL_TOKEN_KEY;
  });

  it('refuses providers that have no hours API before reading punches', async () => {
    const { prisma, service } = harness();
    expect(() => service.authorize(SCOPE, 'adp')).toThrow(/ADP has no customer hours-push API/);
    expect(prisma.timeEntry.findMany).not.toHaveBeenCalled();
  });

  it('refuses unmapped Square hours before creating a timecard', async () => {
    const { square, service, prisma } = harness([{
      id: 'entry-1',
      profileId: 'profile-1',
      profileFullName: 'Ada Lovelace',
      clockInAt: new Date('2026-09-21T09:00:00.000Z'),
      clockOutAt: new Date('2026-09-21T17:00:00.000Z'),
      breaks: null,
    }]);
    prisma.payrollEmployeeMap.findMany.mockResolvedValue([]);

    await expect(service.push(SCOPE, 'square_payroll', PERIOD)).rejects.toBeInstanceOf(BadRequestException);
    expect(square.createTimecard).not.toHaveBeenCalled();
  });

  it('sends a Square timecard without inventing a wage', async () => {
    const { square, service } = harness([{
      id: 'entry-1',
      profileId: 'profile-1',
      profileFullName: 'Ada Lovelace',
      clockInAt: new Date('2026-09-21T09:00:00.000Z'),
      clockOutAt: new Date('2026-09-21T17:00:00.000Z'),
      breaks: null,
    }]);

    await expect(service.push(SCOPE, 'square_payroll', PERIOD)).resolves.toMatchObject({ sent: 1 });
    expect(square.createTimecard).toHaveBeenCalledWith('access', expect.objectContaining({
      teamMemberId: 'tm-1',
      locationId: 'loc-1',
      startAt: '2026-09-21T09:00:00.000Z',
      endAt: '2026-09-21T17:00:00.000Z',
    }));
    expect(square.createTimecard.mock.calls[0][1]).not.toHaveProperty('wage');
  });
});

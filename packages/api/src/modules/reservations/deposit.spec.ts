import { describe, expect, it, vi } from 'vitest';
import { markBeoDepositPaid, markReservationDepositPaid, unpaidBeoDepositBlocksContract, unpaidDepositBlocksSeating } from './deposit';

describe('reservation deposits', () => {
  it('blocks seating until the deposit is paid or waived', () => {
    expect(unpaidDepositBlocksSeating({ depositDueCents: 5000, depositStatus: 'due' })).toBe(true);
    expect(unpaidDepositBlocksSeating({ depositDueCents: 5000, depositStatus: null })).toBe(true);
    expect(unpaidDepositBlocksSeating({ depositDueCents: 5000, depositStatus: 'paid' })).toBe(false);
    expect(unpaidDepositBlocksSeating({ depositDueCents: 5000, depositStatus: 'waived' })).toBe(false);
    expect(unpaidDepositBlocksSeating({ depositDueCents: 0, depositStatus: null })).toBe(false);
  });

  it('does not mark a deposit paid when Stripe charged a different amount', async () => {
    const prisma = {
      reservation: {
        findFirst: vi.fn().mockResolvedValue({ id: 'res-1', depositDueCents: 5000, depositStatus: 'due' }),
        updateMany: vi.fn(),
      },
    };
    await expect(markReservationDepositPaid(prisma as never, {
      venueId: 'venue-1',
      reservationId: 'res-1',
      amountCents: 100,
      checkoutSessionId: 'cs_1',
      paymentIntentId: 'pi_1',
    })).resolves.toBe('ignored');
    expect(prisma.reservation.updateMany).not.toHaveBeenCalled();
  });

  it('blocks a BEO contract until the deposit is paid or waived', () => {
    expect(unpaidBeoDepositBlocksContract({ depositCents: 100000, depositStatus: null })).toBe(true);
    expect(unpaidBeoDepositBlocksContract({ depositCents: 100000, depositStatus: 'paid' })).toBe(false);
  });

  it('does not mark a BEO deposit paid when the amount does not match', async () => {
    const prisma = {
      crmBeo: {
        findFirst: vi.fn().mockResolvedValue({ id: 'beo-1', depositCents: 100000, depositStatus: 'due' }),
        updateMany: vi.fn(),
      },
    };
    await expect(markBeoDepositPaid(prisma as never, {
      venueId: 'venue-1',
      beoId: 'beo-1',
      amountCents: 50,
      checkoutSessionId: 'cs_1',
      paymentIntentId: null,
    })).resolves.toBe('ignored');
    expect(prisma.crmBeo.updateMany).not.toHaveBeenCalled();
  });
});

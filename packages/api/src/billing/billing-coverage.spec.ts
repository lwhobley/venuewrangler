import { describe, expect, it, vi } from 'vitest';
import { resolveVenueSubscriptionStatus } from './subscription-status';
import { AppBillingController } from '../modules/app/app-billing.controller';

describe('billing coverage regressions', () => {
  it.each(['active', 'cancelled', 'past_due'])(
    'uses the paying subscription status (%s), not a covered venue trial', async (status) => {
      const prisma = { subscription: { findFirst: vi.fn().mockResolvedValue({
        id: 'child', status: 'trialing', trialEndsAt: new Date(0), billingSubscriptionId: 'payer',
        billingSubscription: { id: 'payer', status, planId: 'venueflow_multi_venue_5', billingSubscriptionId: null },
      }) } } as any;
      expect(await resolveVenueSubscriptionStatus(prisma, {
        venueId: 'covered', venueStatus: 'trialing', venuePlatform: null, trialEndsAt: new Date(0),
      })).toBe(status);
    },
  );

  it('revokes covered venues when the paying subscription downgrades to single', async () => {
    const prisma = { subscription: { findFirst: vi.fn().mockResolvedValue({
      billingSubscriptionId: 'payer', billingSubscription: { status: 'active', planId: 'single' },
    }) } } as any;
    expect(await resolveVenueSubscriptionStatus(prisma, { venueId: 'covered', venueStatus: 'active' })).toBe('expired');
  });

  it('does not replay a single-venue Apple entitlement onto another venue', async () => {
    const prisma: any = {
      $executeRaw: vi.fn(),
      subscription: {
        findFirst: vi.fn().mockResolvedValue({ id: 'current', venueId: 'venue-b' }),
        findUnique: vi.fn().mockResolvedValue({ id: 'payer', venueId: 'venue-a', platform: 'apple' }),
        update: vi.fn(), create: vi.fn(),
      },
      venue: { update: vi.fn() },
    };
    prisma.$transaction = (fn: any) => fn(prisma);
    const profiles = { requireBillingProfile: vi.fn().mockResolvedValue({ venueId: 'venue-b' }), getProfile: vi.fn() };
    const controller = new AppBillingController(prisma, {} as any, profiles as any);
    vi.spyOn(controller as any, 'assertAllowedAppleSync').mockImplementation(() => {});
    vi.spyOn(controller as any, 'verifyRevenueCatEntitlement').mockResolvedValue({
      productId: 'com.venuewrangler.monthly', subscriberId: 'customer-1', currentPeriodEnd: new Date('2030-01-01'),
    });
    await expect(controller.syncAppleSubscription({ sub: 'user-1' }, { productId: 'com.venuewrangler.monthly' }))
      .rejects.toThrow(/bound|linked|another venue/i);
    expect(prisma.venue.update).not.toHaveBeenCalled();
  });
});

vi.mock('../common/rate-limit', () => ({ assertWithinSharedRateLimit: vi.fn() }));

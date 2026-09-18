import { describe, expect, it, vi } from 'vitest';
import { resolveVenueSubscriptionStatus } from './subscription-status';
import type { PrismaService } from '../prisma/prisma.service';

function fakePrisma(subscriptionStatus: string | null, trialEndsAt?: Date | null): PrismaService {
  return {
    subscription: {
      findFirst: async () =>
        subscriptionStatus ? { id: 'sub_1', status: subscriptionStatus, trialEndsAt: trialEndsAt ?? null } : null,
      updateMany: async () => ({ count: 1 }),
    },
    venue: {
      updateMany: async () => ({ count: 1 }),
    },
  } as unknown as PrismaService;
}

describe('resolveVenueSubscriptionStatus', () => {
  it('does not trust a cached active venue without a subscription', async () => {
    const result = await resolveVenueSubscriptionStatus(fakePrisma(null), {
      venueId: 'v1',
      venueStatus: 'active',
    });
    expect(result).toBe('expired');
  });

  it('checks the authoritative subscription even when the cached venue is active', async () => {
    const findFirst = vi.fn().mockResolvedValue({ status: 'cancelled' });
    const prisma = { subscription: { findFirst } } as unknown as PrismaService;
    const result = await resolveVenueSubscriptionStatus(prisma, { venueId: 'v1', venueStatus: 'active' });
    expect(result).toBe('cancelled');
    expect(findFirst).toHaveBeenCalledOnce();
  });

  it('falls back to the latest subscription record when the venue status is terminal', async () => {
    const result = await resolveVenueSubscriptionStatus(fakePrisma('active'), {
      venueId: 'v1',
      venueStatus: 'expired',
    });
    expect(result).toBe('active');
  });

  it('reports trialing when there is no status but the trial is still active', async () => {
    const result = await resolveVenueSubscriptionStatus(fakePrisma(null), {
      venueId: 'v1',
      venueStatus: null,
      trialEndsAt: new Date(Date.now() + 60_000),
    });
    expect(result).toBe('trialing');
  });

  it('expires a venue trial once the trial end has passed', async () => {
    const result = await resolveVenueSubscriptionStatus(fakePrisma('trialing', new Date(Date.now() - 60_000)), {
      venueId: 'v1',
      venueStatus: 'trialing',
    });
    expect(result).toBe('expired');
  });

  it('returns expired when there is no status and the trial has expired', async () => {
    const result = await resolveVenueSubscriptionStatus(fakePrisma(null), {
      venueId: 'v1',
      venueStatus: null,
      trialEndsAt: new Date(Date.now() - 60_000),
    });
    expect(result).toBe('expired');
  });
});

describe('app-native trial resolution', () => {
  const future = () => new Date(Date.now() + 5 * 24 * 60 * 60 * 1000);
  const past = () => new Date(Date.now() - 1000);

  it('checks for payer coverage before using a live app-native trial', async () => {
    // 'trialing' is where every new customer spends their first 14 days, so
    // this read sat in front of every gated request during that window.
    const findFirst = vi.fn();
    const prisma = { subscription: { findFirst } } as unknown as PrismaService;

    const result = await resolveVenueSubscriptionStatus(prisma, {
      venueId: 'v1',
      venueStatus: 'trialing',
      venuePlatform: null,
      trialEndsAt: future(),
    });

    expect(result).toBe('trialing');
    expect(findFirst).toHaveBeenCalledOnce();
  });

  it('still reads the subscription once an external provider owns the venue', async () => {
    // The provider's status and trial end are authoritative and can disagree
    // with venue.subscriptionStatus, so the fast path must not apply here.
    const findFirst = vi.fn().mockResolvedValue({ id: 'sub_1', status: 'cancelled', trialEndsAt: null });
    const prisma = {
      subscription: { findFirst, updateMany: async () => ({ count: 0 }) },
      venue: { updateMany: async () => ({ count: 0 }) },
    } as unknown as PrismaService;

    const result = await resolveVenueSubscriptionStatus(prisma, {
      venueId: 'v1',
      venueStatus: 'trialing',
      venuePlatform: 'stripe',
      trialEndsAt: future(),
    });

    expect(findFirst).toHaveBeenCalledTimes(1);
    expect(result).toBe('cancelled');
  });

  it('does not fast-path an expired trial', async () => {
    const findFirst = vi.fn().mockResolvedValue(null);
    const prisma = {
      subscription: { findFirst, updateMany: async () => ({ count: 0 }) },
      venue: { updateMany: async () => ({ count: 0 }) },
    } as unknown as PrismaService;

    const result = await resolveVenueSubscriptionStatus(prisma, {
      venueId: 'v1',
      venueStatus: 'trialing',
      venuePlatform: null,
      trialEndsAt: past(),
    });

    expect(findFirst).toHaveBeenCalledTimes(1);
    expect(result).toBe('expired');
  });

  it('does not fast-path when the platform is unknown to the caller', async () => {
    // Omitting venuePlatform must be safe by default rather than optimistic.
    const findFirst = vi.fn().mockResolvedValue({ id: 'sub_1', status: 'trialing', trialEndsAt: future() });
    const prisma = { subscription: { findFirst } } as unknown as PrismaService;

    await resolveVenueSubscriptionStatus(prisma, {
      venueId: 'v1',
      venueStatus: 'trialing',
      trialEndsAt: future(),
    });

    expect(findFirst).toHaveBeenCalledTimes(1);
  });
});

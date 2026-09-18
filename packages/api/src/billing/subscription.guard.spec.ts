import { describe, expect, it, vi } from 'vitest';
import { HttpException } from '@nestjs/common';
import { SubscriptionGuard } from './subscription.guard';

/**
 * Unit coverage for the billing gate that protects every paid feature.
 * When request.venueScope is already populated (the common path — the venue-scope
 * interceptor ran first), canActivate makes a pure allow/deny decision and never
 * touches the database, so we exercise the full tier × status matrix with a stub
 * Prisma that would throw if called.
 */
function makeContext(venueScope: unknown, user?: unknown) {
  const request = { venueScope, user };
  return {
    switchToHttp: () => ({ getRequest: () => request }),
    getHandler: () => ({}),
    getClass: () => ({}),
  } as any;
}

function makeVerifiedContext(verifiedVenueProfile: unknown, user: unknown) {
  const request = { verifiedVenueProfile, user };
  return {
    switchToHttp: () => ({ getRequest: () => request }),
    getHandler: () => ({}),
    getClass: () => ({}),
  } as any;
}

function makeGuard(tier: string | undefined) {
  const reflector = { getAllAndOverride: vi.fn().mockReturnValue(tier) } as any;
  // Throws if any code path tries to hit the DB — proves these cases are pure.
  const prisma = new Proxy({}, { get() { throw new Error('Prisma should not be queried'); } }) as any;
  return new SubscriptionGuard(reflector, prisma);
}

function makeDbGuard(tier: string | undefined, profile: any) {
  const reflector = { getAllAndOverride: vi.fn().mockReturnValue(tier) } as any;
  const prisma = {
    profile: {
      findUnique: vi.fn().mockResolvedValue(profile),
      findFirst: vi.fn().mockResolvedValue(profile),
    },
    subscription: {
      findFirst: vi.fn().mockResolvedValue(profile?.venue ? { status: profile.venue.subscriptionStatus, trialEndsAt: profile.trialEndsAt } : null),
    },
  } as any;
  return { guard: new SubscriptionGuard(reflector, prisma), prisma };
}

const scope = (subscriptionStatus: string | null, allAccess = false) => ({
  profileId: 'p1', fullName: 'A', venueId: 'v1', venueName: 'V', role: 'manager',
  allAccess, subscriptionStatus, trialEndsAt: null,
});

describe('SubscriptionGuard', () => {
  it('allows ungated routes (no tier decorator)', async () => {
    const guard = makeGuard(undefined);
    await expect(guard.canActivate(makeContext(scope('expired')))).resolves.toBe(true);
  });

  it('lets allAccess accounts bypass billing regardless of status', async () => {
    const guard = makeGuard('paid');
    await expect(guard.canActivate(makeContext(scope(null, true)))).resolves.toBe(true);
  });

  describe("tier 'active' (any active or trialing subscription)", () => {
    it.each(['active', 'trialing'])('allows status=%s', async (status) => {
      const guard = makeGuard('active');
      await expect(guard.canActivate(makeContext(scope(status)))).resolves.toBe(true);
    });

    it.each(['past_due', 'paused', 'cancelled', 'expired', null])('denies status=%s with 402', async (status) => {
      const guard = makeGuard('active');
      await expect(guard.canActivate(makeContext(scope(status)))).rejects.toBeInstanceOf(HttpException);
    });
  });

  describe("tier 'paid' (only fully active)", () => {
    it('allows status=active', async () => {
      const guard = makeGuard('paid');
      await expect(guard.canActivate(makeContext(scope('active')))).resolves.toBe(true);
    });

    it('denies status=trialing — a trial does not satisfy paid-only', async () => {
      const guard = makeGuard('paid');
      await expect(guard.canActivate(makeContext(scope('trialing')))).rejects.toBeInstanceOf(HttpException);
    });
  });

  it('denies with 402 when there is no resolvable venue scope', async () => {
    const guard = makeGuard('active');
    // venueScope undefined + no authenticated user → resolveVenueScope returns null
    // without querying Prisma.
    await expect(guard.canActivate(makeContext(undefined, undefined))).rejects.toBeInstanceOf(HttpException);
  });

  it('resolves protected route scope from the database instead of stale token claims', async () => {
    const { guard, prisma } = makeDbGuard('active', {
      id: 'fresh-profile',
      fullName: 'Fresh User',
      role: 'staff',
      allAccess: false,
      membershipStatus: 'active',
      trialEndsAt: null,
      venueId: 'fresh-venue',
      venue: { id: 'fresh-venue', name: 'Fresh Venue', subscriptionStatus: 'active' },
    });
    const context = makeContext(undefined, {
      sub: 'user-1',
      profileId: 'stale-profile',
      venueId: 'stale-venue',
      role: 'owner',
      allAccess: true,
    });

    await expect(guard.canActivate(context)).resolves.toBe(true);
    expect(prisma.profile.findFirst).toHaveBeenCalledWith(expect.objectContaining({ where: expect.objectContaining({ userId: 'user-1' }) }));
    expect(context.switchToHttp().getRequest().venueScope).toMatchObject({
      profileId: 'fresh-profile',
      venueId: 'fresh-venue',
      role: 'staff',
      allAccess: false,
    });
  });

  it('reuses AuthGuard verified membership without querying Profile again', async () => {
    const { guard, prisma } = makeDbGuard('active', null);
    prisma.subscription.findFirst.mockResolvedValue({ status: 'active', platform: 'stripe' });
    const context = makeVerifiedContext({
      id: 'verified-profile',
      fullName: 'Verified User',
      role: 'manager',
      allAccess: false,
      trialEndsAt: null,
      venueId: 'verified-venue',
      venue: { id: 'verified-venue', name: 'Verified Venue', subscriptionStatus: 'active' },
    }, { sub: 'user-1', venueId: 'stale-venue' });

    await expect(guard.canActivate(context)).resolves.toBe(true);
    expect(prisma.profile.findFirst).not.toHaveBeenCalled();
    expect(context.switchToHttp().getRequest().venueScope).toMatchObject({
      profileId: 'verified-profile',
      venueId: 'verified-venue',
      role: 'manager',
    });
  });

  it.each(['pending', 'rejected', 'revoked'])('denies %s memberships even when the venue is subscribed', async (membershipStatus) => {
    const { guard } = makeDbGuard('active', {
      id: 'p1',
      fullName: 'Inactive User',
      role: 'owner',
      allAccess: true,
      membershipStatus,
      trialEndsAt: null,
      venueId: 'v1',
      venue: { id: 'v1', name: 'Venue', subscriptionStatus: 'active' },
    });

    await expect(guard.canActivate(makeContext(undefined, { sub: 'user-1' }))).rejects.toBeInstanceOf(HttpException);
  });

  it('falls back to the JWT venueId instead of crashing on a duplicated X-Venue-Id header', async () => {
    // Express parses a repeated header as string[]. resolveVenueScope used to
    // cast it straight into a Prisma `where: { venueId }` filter, throwing a
    // PrismaClientValidationError (surfaced as a 500) instead of a clean 402/403.
    const { guard, prisma } = makeDbGuard('active', {
      id: 'fresh-profile',
      fullName: 'Fresh User',
      role: 'staff',
      allAccess: false,
      membershipStatus: 'active',
      trialEndsAt: null,
      venueId: 'jwt-venue',
      venue: { id: 'jwt-venue', name: 'JWT Venue', subscriptionStatus: 'active' },
    });
    const context = makeContext(undefined, { sub: 'user-1', venueId: 'jwt-venue' });
    context.switchToHttp().getRequest().headers = { 'x-venue-id': ['venue-a', 'venue-b'] };

    await expect(guard.canActivate(context)).resolves.toBe(true);
    expect(prisma.profile.findFirst).toHaveBeenCalledWith(
      expect.objectContaining({ where: expect.objectContaining({ venueId: 'jwt-venue' }) }),
    );
  });
});

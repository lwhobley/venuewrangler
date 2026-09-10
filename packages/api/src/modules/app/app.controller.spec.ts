import { BadRequestException, ForbiddenException, NotFoundException } from '@nestjs/common';
import { describe, expect, it, vi } from 'vitest';
import { assertWithinSharedRateLimit } from '../../common/rate-limit';
import { AppController } from './app.controller';
import { ProfileService } from './profile.service';
import { getTenantVenueId, runWithTenant } from '../../prisma/tenant-context';

vi.mock('../../common/rate-limit', () => ({
  assertWithinSharedRateLimit: vi.fn().mockResolvedValue(undefined),
}));

describe('AppController invite preview', () => {
  it('rate-limits and rejects an invalid invite without exposing details', async () => {
    const prisma = { invite: { findFirst: vi.fn().mockResolvedValue(null) } };
    const controller = new AppController(prisma as any, {} as any, {} as any);

    await expect(controller.previewInvite({ ip: '127.0.0.1' } as any, 'bad-code'))
      .rejects.toBeInstanceOf(NotFoundException);
    expect(assertWithinSharedRateLimit).toHaveBeenCalled();
  });

  it('rejects malformed or unbounded invite codes with BadRequestException', async () => {
    const prisma = { invite: { findFirst: vi.fn() } };
    const controller = new AppController(prisma as any, {} as any, {} as any);

    await expect(controller.previewInvite({ ip: '127.0.0.1' } as any, ''))
      .rejects.toBeInstanceOf(BadRequestException);
    await expect(controller.previewInvite({ ip: '127.0.0.1' } as any, 'abc'))
      .rejects.toBeInstanceOf(BadRequestException);
    await expect(controller.previewInvite({ ip: '127.0.0.1' } as any, 'a'.repeat(65)))
      .rejects.toBeInstanceOf(BadRequestException);
    expect(prisma.invite.findFirst).not.toHaveBeenCalled();
  });

  it('returns only the team name for a valid public invite', async () => {
    const expiresAt = new Date(Date.now() + 60_000);
    const prisma = {
      invite: {
        findFirst: vi.fn().mockResolvedValue({
          id: 'invite-1',
          venueId: 'venue-1',
          role: 'staff',
          jobTitle: 'Server',
          expiresAt,
        }),
      },
      venue: { findUnique: vi.fn().mockResolvedValue({ name: 'Test Venue' }) },
    };
    const controller = new AppController(prisma as any, {} as any, {} as any);

    await expect(controller.previewInvite({ ip: '127.0.0.1' } as any, 'VW-ABC123')).resolves.toEqual({
      valid: true,
      venueName: 'Test Venue',
    });
  });
});

describe('AppController redeem-my-invite', () => {
  // The no-invite fallback adopts an unclaimed roster profile by deleting the
  // caller's own profile. A caller who already belongs to a venue must never
  // reach it: doing so would tear them out of their venue and, for a sole
  // owner, orphan it — bypassing the last-admin guard on account deletion.
  it('does not delete the profile of a caller who already belongs to a venue', async () => {
    const existingProfile = {
      id: 'profile-owner',
      email: 'owner@example.com',
      fullName: 'Olive Owner',
      role: 'owner',
      jobTitle: 'Owner',
      venueId: 'venue-a',
      allAccess: false,
      venue: { id: 'venue-a', name: 'Venue A', latitude: 1, longitude: 2, geofenceRadiusM: 150 },
    };
    const prisma = {
      user: { findUnique: vi.fn().mockResolvedValue({ email: 'owner@example.com', emailVerifiedAt: new Date() }) },
      profile: {
        findUnique: vi.fn().mockResolvedValue(existingProfile),
        findFirst: vi.fn().mockImplementation((args: any) => {
          if (args?.where?.userId) return Promise.resolve(existingProfile);
          return Promise.resolve({ id: 'profile-roster', venueId: 'venue-b', venue: { id: 'venue-b' } });
        }),
        findMany: vi.fn().mockResolvedValue([{ id: 'profile-owner', venueId: 'venue-a', venue: { id: 'venue-a', name: 'Venue A' }, role: 'owner' }]),
        delete: vi.fn(),
        update: vi.fn().mockResolvedValue({ ...existingProfile, id: 'profile-roster', venueId: 'venue-b' }),
      },
      invite: { findMany: vi.fn().mockResolvedValue([]) },
    };
    const profiles = new ProfileService(prisma as any);
    const controller = new AppController(prisma as any, {} as any, profiles);

    const result = await controller.redeemMyInvite({ sub: 'user-owner' } as any);

    expect(result.redeemed).toBe(false);
    expect(result).toMatchObject({ venue: { id: 'venue-a' } });
    expect(prisma.profile.delete).not.toHaveBeenCalled();
    expect(prisma.profile.update).not.toHaveBeenCalled();
  });

  it('adopts an unclaimed roster profile when the caller has no venue', async () => {
    const adopted = {
      id: 'profile-roster',
      email: 'new@example.com',
      fullName: 'Nina New',
      role: 'staff',
      jobTitle: 'Server',
      venueId: 'venue-b',
      allAccess: false,
      venue: { id: 'venue-b', name: 'Venue B', latitude: 3, longitude: 4, geofenceRadiusM: 150 },
    };
    const prisma = {
      user: { findUnique: vi.fn().mockResolvedValue({ email: 'new@example.com', emailVerifiedAt: new Date() }) },
      profile: {
        findUnique: vi.fn().mockResolvedValue({ id: 'profile-temp', venueId: null, venue: null }),
        findFirst: vi.fn().mockImplementation((args: any) => {
          if (args?.where?.userId === 'user-new') return Promise.resolve({ id: 'profile-temp', venueId: null, venue: null });
          return Promise.resolve({ id: 'profile-roster', role: 'staff', venueId: 'venue-b', venue: { id: 'venue-b' } });
        }),
        findMany: vi.fn().mockResolvedValue([]),
        delete: vi.fn(),
        update: vi.fn().mockResolvedValue(adopted),
      },
      invite: { findMany: vi.fn().mockResolvedValue([]) },
      $transaction: vi.fn(async (fn: any) => fn(prisma)),
    };
    const profiles = new ProfileService(prisma as any);
    const controller = new AppController(prisma as any, {} as any, profiles);

    const result = await controller.redeemMyInvite({ sub: 'user-new' } as any);

    expect(result.redeemed).toBe(true);
    expect(result).toMatchObject({ venue: { id: 'venue-b' } });
    expect(prisma.profile.delete).toHaveBeenCalledWith({ where: { id: 'profile-temp' } });
    expect(prisma.profile.update).toHaveBeenCalledWith(
      expect.objectContaining({ where: { id: 'profile-roster' }, data: { userId: 'user-new', role: 'staff' } }),
    );
  });

  it('keeps the role the manager put on the roster instead of forcing staff', async () => {
    // Regression (E02): adoption hardcoded 'staff', so someone added to the
    // roster as a manager claimed their account and landed in a workspace
    // without the controls they had been told to expect.
    const adopted = {
      id: 'profile-roster',
      email: 'mo@example.com',
      fullName: 'Mo Manager',
      role: 'manager',
      jobTitle: 'GM',
      venueId: 'venue-b',
      allAccess: false,
      venue: { id: 'venue-b', name: 'Venue B', latitude: 3, longitude: 4, geofenceRadiusM: 150 },
    };
    const prisma: any = {
      user: { findUnique: vi.fn().mockResolvedValue({ email: 'mo@example.com', emailVerifiedAt: new Date() }) },
      profile: {
        findUnique: vi.fn().mockResolvedValue({ id: 'profile-temp', venueId: null, venue: null }),
        findFirst: vi.fn().mockImplementation((args: any) => {
          if (args?.where?.userId === 'user-mo') return Promise.resolve({ id: 'profile-temp', venueId: null, venue: null });
          return Promise.resolve({ id: 'profile-roster', role: 'manager', venueId: 'venue-b', venue: { id: 'venue-b' } });
        }),
        findMany: vi.fn().mockResolvedValue([]),
        delete: vi.fn(),
        update: vi.fn().mockResolvedValue(adopted),
      },
      invite: { findMany: vi.fn().mockResolvedValue([]) },
      $transaction: vi.fn(async (fn: any) => fn(prisma)),
    };
    const controller = new AppController(prisma, {} as any, new ProfileService(prisma));

    await controller.redeemMyInvite({ sub: 'user-mo' } as any);

    expect(prisma.profile.update).toHaveBeenCalledWith(
      expect.objectContaining({ data: { userId: 'user-mo', role: 'manager' } }),
    );
  });

  it('does not hand out owner or admin by claiming a roster row', async () => {
    const prisma: any = {
      user: { findUnique: vi.fn().mockResolvedValue({ email: 'o@example.com', emailVerifiedAt: new Date() }) },
      profile: {
        findUnique: vi.fn().mockResolvedValue({ id: 'profile-temp', venueId: null, venue: null }),
        findFirst: vi.fn().mockImplementation((args: any) => {
          if (args?.where?.userId === 'user-o') return Promise.resolve({ id: 'profile-temp', venueId: null, venue: null });
          return Promise.resolve({ id: 'profile-roster', role: 'owner', venueId: 'venue-b', venue: { id: 'venue-b' } });
        }),
        findMany: vi.fn().mockResolvedValue([]),
        delete: vi.fn(),
        update: vi.fn().mockResolvedValue({ id: 'profile-roster', role: 'manager', venueId: 'venue-b', venue: { id: 'venue-b', name: 'B', latitude: 1, longitude: 2, geofenceRadiusM: 150 } }),
      },
      invite: { findMany: vi.fn().mockResolvedValue([]) },
      $transaction: vi.fn(async (fn: any) => fn(prisma)),
    };
    const controller = new AppController(prisma, {} as any, new ProfileService(prisma));

    await controller.redeemMyInvite({ sub: 'user-o' } as any);

    expect(prisma.profile.update).toHaveBeenCalledWith(
      expect.objectContaining({ data: { userId: 'user-o', role: 'manager' } }),
    );
  });
});

describe('AppController multi-venue invariants', () => {
  it('returns the active venue join code only through the manager endpoint', async () => {
    const profiles = {
      requireManagerProfile: vi.fn().mockResolvedValue({
        venueId: 'venue-1', venue: { code: 'VW-ABCDEFGHJK' },
      }),
    };
    const controller = new AppController({} as any, {} as any, profiles as any);

    await expect(controller.getVenueJoinCode({ sub: 'manager-1' } as any))
      .resolves.toEqual({ code: 'VW-ABCDEFGHJK' });
  });

  it('rotates the active venue join code to a new high-entropy human code', async () => {
    const prisma = {
      venue: {
        findUnique: vi.fn().mockResolvedValue(null),
        update: vi.fn().mockResolvedValue({}),
      },
    };
    const profiles = {
      requireManagerProfile: vi.fn().mockResolvedValue({ venueId: 'venue-1', venue: { code: 'VW-OLD' } }),
    };
    const controller = new AppController(prisma as any, {} as any, profiles as any);

    const result = await controller.rotateVenueJoinCode({ sub: 'manager-1' } as any);

    expect(result.code).toMatch(/^VW-[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{10}$/);
    expect(prisma.venue.update).toHaveBeenCalledWith({ where: { id: 'venue-1' }, data: { code: result.code } });
  });

  it('clears the current tenant only while verifying membership in the target venue', async () => {
    const targetProfile = {
      id: 'profile-b', userId: 'user-1', venueId: 'venue-b', role: 'owner', allAccess: false,
      membershipStatus: 'active', fullName: 'Owner Olivia', email: 'owner@example.com', jobTitle: 'Owner',
      venue: { id: 'venue-b', name: 'Venue B', latitude: 1, longitude: 2, geofenceRadiusM: 150 },
    };
    const profiles = {
      requireVenueProfile: vi.fn(async () => {
        expect(getTenantVenueId()).toBeUndefined();
        return targetProfile;
      }),
      isEmailVerified: vi.fn().mockResolvedValue(true),
      listUserVenues: vi.fn().mockResolvedValue([{ id: 'venue-b', name: 'Venue B', role: 'owner', profileId: 'profile-b' }]),
    };
    const controller = new AppController({} as any, {} as any, profiles as any);

    const result = await runWithTenant('venue-a', () => controller.switchVenue({ sub: 'user-1' } as any, { venueId: 'venue-b' }));

    expect(profiles.requireVenueProfile).toHaveBeenCalledWith(expect.objectContaining({ sub: 'user-1' }), 'venue-b');
    expect(result).toMatchObject({ profile: { venueId: 'venue-b' }, venue: { id: 'venue-b' } });
  });

  it('serializes venue registration by user and checks the cap under that lock', async () => {
    const prisma: any = {
      $executeRaw: vi.fn().mockResolvedValue(undefined),
      profile: {
        findMany: vi.fn().mockResolvedValue(Array.from({ length: 5 }, (_, index) => ({ venueId: `venue-${index}` }))),
      },
      venue: { create: vi.fn() },
    };
    prisma.$transaction = vi.fn(async (callback: any) => callback(prisma));
    const profiles = {
      ensureUser: vi.fn().mockResolvedValue({ id: 'user-1' }),
      isEmailVerified: vi.fn().mockResolvedValue(true),
    };
    const controller = new AppController(prisma, {} as any, profiles as any);

    await expect(controller.registerVenue(
      { sub: 'user-1', email: 'owner@example.com' } as any,
      { businessName: 'Sixth Venue', staffRange: '1-15', latitude: 40.7, longitude: -74.0 } as any,
    )).rejects.toBeInstanceOf(ForbiddenException);

    expect(prisma.$executeRaw.mock.calls[0]?.[1]).toBe('register-venue:user-1');
    expect(prisma.profile.findMany.mock.invocationCallOrder[0]).toBeGreaterThan(prisma.$executeRaw.mock.invocationCallOrder[0]);
    expect(prisma.venue.create).not.toHaveBeenCalled();
  });

  it('deletes the caller\'s venueless signup profile once a venue profile is created', async () => {
    // Signup always creates a venueless Profile row. Registering a venue then
    // creates a second, venued row for the same user. If the venueless row is
    // left behind, "oldest matching profile" fallbacks elsewhere (see
    // profile.service.ts / auth.guard.ts) can pick it over the real venue
    // membership and silently disable venue-scoped behavior.
    const existingProfile = { id: 'profile-signup', userId: 'user-1', venueId: null, email: 'owner@example.com', fullName: 'Owner' };
    const prisma: any = {
      $executeRaw: vi.fn().mockResolvedValue(undefined),
      profile: {
        findMany: vi.fn().mockResolvedValue([]),
        // Distinguish the duplicate-venue-name check (has a `venue` filter)
        // from the plain existingProfile lookup by userId only.
        findFirst: vi.fn().mockImplementation((args: any) =>
          Promise.resolve(args?.where?.venue ? null : existingProfile)),
        create: vi.fn().mockResolvedValue({ id: 'profile-venue', venueId: 'venue-new', userId: 'user-1' }),
        delete: vi.fn().mockResolvedValue(existingProfile),
        count: vi.fn().mockResolvedValue(1),
      },
      venue: {
        findUnique: vi.fn().mockResolvedValue(null),
        create: vi.fn().mockResolvedValue({ id: 'venue-new', name: 'New Venue' }),
      },
      subscription: { create: vi.fn().mockResolvedValue({}) },
      staffOnboardingTask: { createMany: vi.fn().mockResolvedValue({ count: 0 }) },
      team: { upsert: vi.fn().mockResolvedValue({}) },
    };
    prisma.$transaction = vi.fn(async (callback: any) => callback(prisma));
    const profiles = {
      ensureUser: vi.fn().mockResolvedValue({ id: 'user-1' }),
      isEmailVerified: vi.fn().mockResolvedValue(true),
      listUserVenues: vi.fn().mockResolvedValue([{ id: 'venue-new', name: 'New Venue', role: 'admin', profileId: 'profile-venue' }]),
    };
    const controller = new AppController(prisma, {} as any, profiles as any);

    await controller.registerVenue(
      { sub: 'user-1', email: 'owner@example.com' } as any,
      { businessName: 'New Venue', staffRange: '1-15', latitude: 40.7, longitude: -74.0 } as any,
    );

    expect(prisma.profile.delete).toHaveBeenCalledWith({ where: { id: 'profile-signup' } });
  });

  it('defaults a new venue to UTC when the caller sends no timezone', async () => {
    // Regression for VW-24: Venue.timezone is now required at the database
    // layer. Every creation path must resolve a concrete value rather than
    // relying on a nullable column silently accepting an omission.
    const existingProfile = { id: 'profile-signup', userId: 'user-1', venueId: null, email: 'owner@example.com', fullName: 'Owner' };
    const prisma: any = {
      $executeRaw: vi.fn().mockResolvedValue(undefined),
      profile: {
        findMany: vi.fn().mockResolvedValue([]),
        findFirst: vi.fn().mockImplementation((args: any) =>
          Promise.resolve(args?.where?.venue ? null : existingProfile)),
        create: vi.fn().mockResolvedValue({ id: 'profile-venue', venueId: 'venue-new', userId: 'user-1' }),
        delete: vi.fn().mockResolvedValue(existingProfile),
        count: vi.fn().mockResolvedValue(1),
      },
      venue: {
        findUnique: vi.fn().mockResolvedValue(null),
        create: vi.fn().mockResolvedValue({ id: 'venue-new', name: 'New Venue' }),
      },
      subscription: { create: vi.fn().mockResolvedValue({}) },
      staffOnboardingTask: { createMany: vi.fn().mockResolvedValue({ count: 0 }) },
      team: { upsert: vi.fn().mockResolvedValue({}) },
    };
    prisma.$transaction = vi.fn(async (callback: any) => callback(prisma));
    const profiles = {
      ensureUser: vi.fn().mockResolvedValue({ id: 'user-1' }),
      isEmailVerified: vi.fn().mockResolvedValue(true),
      listUserVenues: vi.fn().mockResolvedValue([{ id: 'venue-new', name: 'New Venue', role: 'admin', profileId: 'profile-venue' }]),
    };
    const controller = new AppController(prisma, {} as any, profiles as any);

    await controller.registerVenue(
      { sub: 'user-1', email: 'owner@example.com' } as any,
      { businessName: 'New Venue', staffRange: '1-15', latitude: 40.7, longitude: -74.0 } as any,
    );

    expect(prisma.venue.create).toHaveBeenCalledWith(
      expect.objectContaining({ data: expect.objectContaining({ timezone: 'UTC' }) }),
    );
  });

  it('does not delete an existing profile that already belongs to another venue', async () => {
    // A user registering an additional venue (multi-venue) already has a
    // venued profile as their "existingProfile" match; that one must survive.
    const existingProfile = { id: 'profile-other-venue', userId: 'user-1', venueId: 'venue-a', email: 'owner@example.com', fullName: 'Owner' };
    const prisma: any = {
      $executeRaw: vi.fn().mockResolvedValue(undefined),
      profile: {
        findMany: vi.fn().mockResolvedValue([{ venueId: 'venue-a' }]),
        findFirst: vi.fn().mockImplementation((args: any) =>
          Promise.resolve(args?.where?.venue ? null : existingProfile)),
        create: vi.fn().mockResolvedValue({ id: 'profile-venue-b', venueId: 'venue-b', userId: 'user-1' }),
        delete: vi.fn(),
        count: vi.fn().mockResolvedValue(1),
      },
      venue: {
        findUnique: vi.fn().mockResolvedValue(null),
        create: vi.fn().mockResolvedValue({ id: 'venue-b', name: 'Second Venue' }),
      },
      subscription: {
        create: vi.fn().mockResolvedValue({}),
        findFirst: vi.fn().mockResolvedValue({ id: 'sub-multi', venueId: 'venue-a', status: 'active', planId: 'venueflow_multi_venue_5', platform: 'stripe' }),
        findUnique: vi.fn().mockResolvedValue({ id: 'sub-multi', venueId: 'venue-a', status: 'active', planId: 'venueflow_multi_venue_5', platform: 'stripe' }),
        count: vi.fn().mockResolvedValue(0),
      },
      staffOnboardingTask: { createMany: vi.fn().mockResolvedValue({ count: 0 }) },
      team: { upsert: vi.fn().mockResolvedValue({}) },
    };
    prisma.$transaction = vi.fn(async (callback: any) => callback(prisma));
    const profiles = {
      ensureUser: vi.fn().mockResolvedValue({ id: 'user-1' }),
      isEmailVerified: vi.fn().mockResolvedValue(true),
      listUserVenues: vi.fn().mockResolvedValue([]),
    };
    const controller = new AppController(prisma, {} as any, profiles as any);

    await controller.registerVenue(
      { sub: 'user-1', email: 'owner@example.com' } as any,
      { businessName: 'Second Venue', staffRange: '1-15', latitude: 40.7, longitude: -74.0 } as any,
    );

    expect(prisma.profile.delete).not.toHaveBeenCalled();
    expect(prisma.subscription.create).toHaveBeenCalledWith(expect.objectContaining({ data: expect.objectContaining({
      billingSubscriptionId: 'sub-multi', status: 'expired', trialEndsAt: null,
    }) }));
  });

  it('refuses to create a venue at the 0,0 geofence sentinel', async () => {
    const prisma: any = {
      $executeRaw: vi.fn().mockResolvedValue(undefined),
      profile: {
        findMany: vi.fn().mockResolvedValue([]),
        findFirst: vi.fn().mockResolvedValue(null),
      },
      venue: { create: vi.fn() },
    };
    prisma.$transaction = vi.fn(async (callback: any) => callback(prisma));
    const profiles = {
      ensureUser: vi.fn().mockResolvedValue({ id: 'user-1' }),
      isEmailVerified: vi.fn().mockResolvedValue(true),
    };
    const controller = new AppController(prisma, {} as any, profiles as any);

    await expect(controller.registerVenue(
      { sub: 'user-1', email: 'owner@example.com' } as any,
      { businessName: 'Null Island', staffRange: '1-15', latitude: 0, longitude: 0 } as any,
    )).rejects.toThrow('Set the venue coordinates');
    expect(prisma.venue.create).not.toHaveBeenCalled();
  });

  it('checks last-admin safety for every venue before deleting a multi-venue account', async () => {
    const profiles = [
      { id: 'profile-a', email: 'owner@example.com', fullName: 'Owner', role: 'owner', venueId: 'venue-a', membershipStatus: 'active' },
      { id: 'profile-b', email: 'owner@example.com', fullName: 'Owner', role: 'owner', venueId: 'venue-b', membershipStatus: 'active' },
    ];
    const prisma: any = {
      $executeRaw: vi.fn().mockResolvedValue(undefined),
      user: { findUnique: vi.fn().mockResolvedValue({ email: 'owner@example.com' }), deleteMany: vi.fn() },
      profile: {
        findMany: vi.fn().mockResolvedValue(profiles),
        count: vi.fn()
          .mockResolvedValueOnce(2)
          .mockResolvedValueOnce(1),
        deleteMany: vi.fn(),
      },
      pushToken: { deleteMany: vi.fn() }, availability: { deleteMany: vi.fn() },
      subscription: { findMany: vi.fn().mockResolvedValue([]), count: vi.fn().mockResolvedValue(0) },
      timeEntry: { updateMany: vi.fn(), update: vi.fn(), findMany: vi.fn().mockResolvedValue([]) }, scheduleShift: { updateMany: vi.fn() },
      session: { deleteMany: vi.fn() }, authAccount: { deleteMany: vi.fn() },
    };
    prisma.$transaction = vi.fn(async (callback: any) => callback(prisma));
    const controller = new AppController(prisma, {} as any, {} as any);

    await expect(controller.deleteMyAccount({ sub: 'user-1' } as any)).rejects.toThrow(
      'Transfer venue ownership or confirm deletion',
    );
    expect(prisma.$executeRaw).toHaveBeenCalledTimes(2);
    expect(prisma.user.deleteMany).not.toHaveBeenCalled();
  });

  it('rejects deletion when caller is the sole owner/admin of a single-member venue', async () => {
    const profiles = [
      { id: 'profile-sole', email: 'owner@example.com', fullName: 'Sole Owner', role: 'owner', venueId: 'venue-single', membershipStatus: 'active' },
    ];
    const prisma: any = {
      $executeRaw: vi.fn().mockResolvedValue(undefined),
      user: { findUnique: vi.fn().mockResolvedValue({ email: 'owner@example.com' }), deleteMany: vi.fn() },
      profile: {
        findMany: vi.fn().mockResolvedValue(profiles),
        count: vi.fn().mockResolvedValue(1),
        deleteMany: vi.fn(),
      },
      pushToken: { deleteMany: vi.fn() }, availability: { deleteMany: vi.fn() },
      subscription: { findMany: vi.fn().mockResolvedValue([]), count: vi.fn().mockResolvedValue(0) },
      timeEntry: { updateMany: vi.fn(), update: vi.fn(), findMany: vi.fn().mockResolvedValue([]) }, scheduleShift: { updateMany: vi.fn() },
      session: { deleteMany: vi.fn() }, authAccount: { deleteMany: vi.fn() },
    };
    prisma.$transaction = vi.fn(async (callback: any) => callback(prisma));
    const controller = new AppController(prisma, {} as any, {} as any);

    await expect(controller.deleteMyAccount({ sub: 'user-1' } as any)).rejects.toThrow(
      'Transfer venue ownership or confirm deletion',
    );
    expect(prisma.user.deleteMany).not.toHaveBeenCalled();
  });

  it('deletes an owned venue only after explicit final-owner confirmation', async () => {
    const profiles = [
      { id: 'profile-sole', email: 'owner@example.com', fullName: 'Sole Owner', role: 'owner', venueId: 'venue-single', membershipStatus: 'active' },
    ];
    const prisma: any = {
      $executeRaw: vi.fn().mockResolvedValue(undefined),
      $queryRaw: vi.fn().mockResolvedValue([]),
      user: { findUnique: vi.fn().mockResolvedValue({ email: 'owner@example.com' }), deleteMany: vi.fn() },
      profile: {
        findMany: vi.fn().mockResolvedValue(profiles),
        count: vi.fn().mockResolvedValue(1),
        deleteMany: vi.fn().mockResolvedValue({ count: 1 }),
      },
      venue: {
        deleteMany: vi.fn().mockResolvedValue({ count: 1 }),
        findMany: vi.fn().mockResolvedValue([{ id: 'venue-single', name: 'Single Venue' }]),
      },
      chatImage: { findMany: vi.fn().mockResolvedValue([]), count: vi.fn().mockResolvedValue(0) },
      venueDocument: { findMany: vi.fn().mockResolvedValue([]), count: vi.fn().mockResolvedValue(0) },
      checklistCompletion: { findMany: vi.fn().mockResolvedValue([]), count: vi.fn().mockResolvedValue(0) },
      objectDeletionJob: { create: vi.fn() },
      retainedTimeEntry: { createMany: vi.fn() },
      pushToken: { deleteMany: vi.fn() }, availability: { deleteMany: vi.fn() },
      subscription: { findMany: vi.fn().mockResolvedValue([]), count: vi.fn().mockResolvedValue(0) },
      timeEntry: { updateMany: vi.fn(), update: vi.fn(), findMany: vi.fn().mockResolvedValue([]), deleteMany: vi.fn(), count: vi.fn().mockResolvedValue(0) },
      scheduleShift: { updateMany: vi.fn() },
      session: { deleteMany: vi.fn() }, authAccount: { deleteMany: vi.fn() },
    };
    prisma.$transaction = vi.fn(async (callback: any) => callback(prisma));
    const email = { send: vi.fn().mockResolvedValue(undefined) };
    const controller = new AppController(prisma, email as any, {} as any);

    await expect(controller.deleteMyAccount(
      { sub: 'user-1' } as any,
      { deleteOwnedVenues: true },
    )).resolves.toEqual({ ok: true });

    expect(prisma.profile.deleteMany).toHaveBeenCalledWith({ where: { venueId: { in: ['venue-single'] } } });
    expect(prisma.$queryRaw).toHaveBeenCalledTimes(2);
    expect(prisma.venue.deleteMany).toHaveBeenCalledWith({ where: { id: { in: ['venue-single'] } } });
    expect(prisma.timeEntry.updateMany).toHaveBeenCalledWith({
      where: { profileId: 'profile-sole' },
      data: { profileFullName: 'deleted_user_profile-sole', isOpen: false },
    });
    expect(prisma.user.deleteMany).toHaveBeenCalledWith({ where: { id: 'user-1' } });
  });

  it('uses set-based archival without an arbitrary row-count refusal', async () => {
    const profiles = [
      { id: 'profile-sole', email: 'owner@example.com', fullName: 'Sole Owner', role: 'owner', venueId: 'venue-single', membershipStatus: 'active' },
    ];
    const prisma: any = {
      $executeRaw: vi.fn().mockResolvedValue(undefined),
      $queryRaw: vi.fn().mockResolvedValue([]),
      user: { findUnique: vi.fn().mockResolvedValue({ email: 'owner@example.com' }), deleteMany: vi.fn() },
      profile: {
        findMany: vi.fn().mockResolvedValue(profiles),
        count: vi.fn().mockResolvedValue(1),
        deleteMany: vi.fn(),
      },
      venue: { deleteMany: vi.fn().mockResolvedValue({ count: 1 }) },
      chatImage: { findMany: vi.fn(), count: vi.fn().mockResolvedValue(0) },
      venueDocument: { findMany: vi.fn(), count: vi.fn().mockResolvedValue(0) },
      checklistCompletion: { findMany: vi.fn(), count: vi.fn().mockResolvedValue(0) },
      objectDeletionJob: { create: vi.fn() },
      retainedTimeEntry: { createMany: vi.fn() },
      pushToken: { deleteMany: vi.fn() }, availability: { deleteMany: vi.fn() },
      subscription: { findMany: vi.fn().mockResolvedValue([]), count: vi.fn().mockResolvedValue(0) },
      timeEntry: { updateMany: vi.fn(), update: vi.fn(), findMany: vi.fn().mockResolvedValue([]) },
      scheduleShift: { updateMany: vi.fn() },
      session: { deleteMany: vi.fn() }, authAccount: { deleteMany: vi.fn() },
    };
    prisma.$transaction = vi.fn(async (callback: any) => callback(prisma));
    const controller = new AppController(prisma, { send: vi.fn() } as any, {} as any);

    await expect(controller.deleteMyAccount(
      { sub: 'user-1' } as any,
      { deleteOwnedVenues: true },
    )).resolves.toEqual({ ok: true });

    expect(prisma.chatImage.count).not.toHaveBeenCalled();
    expect(prisma.venue.deleteMany).toHaveBeenCalled();
    expect(prisma.user.deleteMany).toHaveBeenCalled();
    expect(prisma.$transaction.mock.calls[0][1]).toMatchObject({ timeout: 30_000 });
  });

  it('archives every employee wage record before the venue cascade destroys them', async () => {
    const profiles = [
      { id: 'profile-sole', email: 'owner@example.com', fullName: 'Sole Owner', role: 'owner', venueId: 'venue-single', membershipStatus: 'active' },
    ];
    // Two entries belonging to a DIFFERENT employee — the case that matters.
    // TimeEntry.venue is onDelete: Cascade, so without the archive step these
    // rows disappear when the owner deletes their own account.
    const otherStaffEntries = [
      {
        id: 'te-1', venueId: 'venue-single', profileId: 'profile-bailey', profileFullName: null,
        clockInAt: new Date('2026-01-02T09:00:00Z'), clockOutAt: new Date('2026-01-02T17:00:00Z'),
        isOpen: false, breaks: null, createdAt: new Date('2026-01-02T09:00:00Z'),
        profile: { fullName: 'Bartender Bailey', email: 'bailey@example.com' },
      },
      {
        id: 'te-2', venueId: 'venue-single', profileId: 'profile-snap', profileFullName: 'Snapshot Only',
        clockInAt: new Date('2026-01-03T09:00:00Z'), clockOutAt: null,
        isOpen: true, breaks: null, createdAt: new Date('2026-01-03T09:00:00Z'),
        profile: null,
      },
    ];
    let timeEntryPage = 0;
    const prisma: any = {
      $executeRaw: vi.fn().mockResolvedValue(undefined),
      $queryRaw: vi.fn().mockResolvedValue([]),
      user: { findUnique: vi.fn().mockResolvedValue({ email: 'owner@example.com' }), deleteMany: vi.fn() },
      profile: {
        findMany: vi.fn().mockResolvedValue(profiles),
        count: vi.fn().mockResolvedValue(1),
        deleteMany: vi.fn().mockResolvedValue({ count: 1 }),
      },
      venue: {
        deleteMany: vi.fn().mockResolvedValue({ count: 1 }),
        findMany: vi.fn().mockResolvedValue([{ id: 'venue-single', name: 'Single Venue' }]),
      },
      chatImage: { findMany: vi.fn().mockResolvedValue([]), count: vi.fn().mockResolvedValue(0) },
      venueDocument: { findMany: vi.fn().mockResolvedValue([]), count: vi.fn().mockResolvedValue(0) },
      checklistCompletion: { findMany: vi.fn().mockResolvedValue([]), count: vi.fn().mockResolvedValue(0) },
      objectDeletionJob: { create: vi.fn() },
      retainedTimeEntry: { createMany: vi.fn() },
      pushToken: { deleteMany: vi.fn() }, availability: { deleteMany: vi.fn() },
      subscription: { findMany: vi.fn().mockResolvedValue([]), count: vi.fn().mockResolvedValue(0) },
      // First call returns the page, second returns empty to end the loop.
      timeEntry: {
        updateMany: vi.fn(),
        update: vi.fn(),
        deleteMany: vi.fn(),
        findMany: vi.fn(async (args: any) => {
          if (args?.where?.clockOutAt === null) return [];
          return timeEntryPage++ === 0 ? otherStaffEntries : [];
        }),
        count: vi.fn().mockResolvedValue(0),
      },
      scheduleShift: { updateMany: vi.fn() },
      session: { deleteMany: vi.fn() }, authAccount: { deleteMany: vi.fn() },
    };
    prisma.$transaction = vi.fn(async (callback: any) => callback(prisma));
    const controller = new AppController(prisma, { send: vi.fn() } as any, {} as any);

    await controller.deleteMyAccount({ sub: 'user-1' } as any, { deleteOwnedVenues: true });

    // $executeRaw is invoked two ways in this flow: tagged-template calls
    // (`` tx.$executeRaw`...` ``, where call[0] is the raw strings array) for
    // advisory locks, and `tx.$executeRaw(Prisma.sql`...`)` (call[0] is a Sql
    // object with a .strings property) for the archive inserts. Normalize both.
    const executeRawCalls = prisma.$executeRaw.mock.calls.map((call: any, index: number) => {
      const raw = call[0];
      const text = Array.isArray(raw) ? raw.join('') : String(raw?.strings?.join('') ?? raw);
      return { text, order: prisma.$executeRaw.mock.invocationCallOrder[index] };
    });
    const findArchiveCall = (table: string) => {
      const found = executeRawCalls.find((call: any) => call.text.includes(`INSERT INTO "${table}"`));
      if (!found) throw new Error(`No archive INSERT found for ${table}`);
      return found;
    };

    const timeEntryArchive = findArchiveCall('RetainedTimeEntry');
    // Pseudonymize the departing account's own rows only. Co-workers keep their
    // real name/email — an anonymized wage record cannot satisfy FLSA §516.2,
    // so blanket-anonymizing the venue would retain the rows and still lose the
    // compliance value they exist for.
    expect(timeEntryArchive.text).toContain("'deleted_user_' || t.\"profileId\"");
    expect(timeEntryArchive.text).toContain('CASE WHEN t."profileId" IS NOT NULL');
    expect(timeEntryArchive.text).toContain('ELSE t."profileFullName" END');
    expect(timeEntryArchive.text).toContain('ELSE p."email" END');

    // PosCheck/PosLaborPunch are also Cascade from Venue with no other
    // retention path — they must be archived before the cascade too.
    const posCheckArchive = findArchiveCall('RetainedPosCheck');
    const posLaborArchive = findArchiveCall('RetainedPosLaborPunch');

    // And every archive insert must happen before the cascade, not after.
    const cascadeOrder = prisma.venue.deleteMany.mock.invocationCallOrder[0];
    expect(timeEntryArchive.order).toBeLessThan(cascadeOrder);
    expect(posCheckArchive.order).toBeLessThan(cascadeOrder);
    expect(posLaborArchive.order).toBeLessThan(cascadeOrder);
  });

  it('refuses to delete a venue whose subscription still covers another venue\'s billing', async () => {
    const profiles = [
      { id: 'profile-sole', email: 'owner@example.com', fullName: 'Sole Owner', role: 'owner', venueId: 'venue-billing', membershipStatus: 'active' },
    ];
    const prisma: any = {
      $executeRaw: vi.fn().mockResolvedValue(undefined),
      $queryRaw: vi.fn().mockResolvedValue([]),
      user: { findUnique: vi.fn().mockResolvedValue({ email: 'owner@example.com' }), deleteMany: vi.fn() },
      profile: {
        findMany: vi.fn().mockResolvedValue(profiles),
        count: vi.fn().mockResolvedValue(1),
        deleteMany: vi.fn(),
      },
      venue: { deleteMany: vi.fn(), findMany: vi.fn().mockResolvedValue([]) },
      subscription: {
        findMany: vi.fn().mockResolvedValue([{ id: 'sub-billing' }]),
        // Another venue's subscription still points at this one as its
        // billing parent — the venue-billing account cannot be deleted
        // without silently cutting that other venue off its paid plan.
        count: vi.fn().mockResolvedValue(1),
      },
    };
    prisma.$transaction = vi.fn(async (callback: any) => callback(prisma));
    const controller = new AppController(prisma, { send: vi.fn() } as any, {} as any);

    await expect(controller.deleteMyAccount(
      { sub: 'user-1' } as any,
      { deleteOwnedVenues: true },
    )).rejects.toThrow('covers other venues');

    expect(prisma.venue.deleteMany).not.toHaveBeenCalled();
    expect(prisma.subscription.count).toHaveBeenCalledWith({
      where: { billingSubscriptionId: { in: ['sub-billing'] }, venueId: { notIn: ['venue-billing'] } },
    });
  });

  it('closes a still-running punch with a real clock-out so the final shift stays payable', async () => {
    const profiles = [
      { id: 'profile-leaver', email: 'leaver@example.com', fullName: 'Lee Leaver', role: 'staff', venueId: 'venue-other', membershipStatus: 'active' },
    ];
    const prisma: any = {
      $executeRaw: vi.fn().mockResolvedValue(undefined),
      $queryRaw: vi.fn().mockResolvedValue([]),
      user: { findUnique: vi.fn().mockResolvedValue({ email: 'leaver@example.com' }), deleteMany: vi.fn() },
      profile: {
        findMany: vi.fn().mockResolvedValue(profiles),
        // Not the last owner/admin anywhere, so no venue is deleted: the time
        // entries survive at a venue this user merely worked at.
        count: vi.fn().mockResolvedValue(3),
        deleteMany: vi.fn().mockResolvedValue({ count: 1 }),
      },
      venue: { deleteMany: vi.fn(), findMany: vi.fn().mockResolvedValue([]) },
      objectDeletionJob: { create: vi.fn() },
      retainedTimeEntry: { createMany: vi.fn() },
      pushToken: { deleteMany: vi.fn() }, availability: { deleteMany: vi.fn() },
      subscription: { findMany: vi.fn().mockResolvedValue([]), count: vi.fn().mockResolvedValue(0) },
      timeEntry: {
        updateMany: vi.fn(),
        update: vi.fn(),
        deleteMany: vi.fn(),
        findMany: vi.fn().mockResolvedValue([{ id: 'entry-open', breaks: [{ startAt: 1, endAt: null, type: 'unpaid' }] }]),
        count: vi.fn().mockResolvedValue(0),
      },
      scheduleShift: { updateMany: vi.fn() },
      session: { deleteMany: vi.fn() }, authAccount: { deleteMany: vi.fn() },
      // The surviving venue gets its member count resynced after the profile goes.
      team: { upsert: vi.fn() },
    };
    prisma.$transaction = vi.fn(async (callback: any) => callback(prisma));
    const controller = new AppController(prisma, { send: vi.fn() } as any, {} as any);

    await controller.deleteMyAccount({ sub: 'user-1' } as any);

    // Flipping isOpen to false while leaving clockOutAt null makes the row
    // invisible to payroll (which filters clockOutAt: { not: null }) and
    // unreachable by a correction request once profileId is nulled — the
    // employee's last partial shift would silently never be paid.
    expect(prisma.timeEntry.findMany).toHaveBeenCalledWith({
      where: { profileId: { in: ['profile-leaver'] }, clockOutAt: null },
      select: { id: true, breaks: true },
    });
    expect(prisma.timeEntry.update).toHaveBeenCalledWith({
      where: { id: 'entry-open' },
      data: expect.objectContaining({
        clockOutAt: expect.any(Date),
        isOpen: false,
        breaks: [expect.objectContaining({ endAt: expect.any(Number), type: 'unpaid' })],
      }),
    });
    const closeOrder = prisma.timeEntry.update.mock.invocationCallOrder[0];
    const renameCall = prisma.timeEntry.updateMany.mock.calls.findIndex(
      ([args]: any[]) => typeof args?.data?.profileFullName === 'string',
    );
    expect(closeOrder).toBeLessThan(prisma.timeEntry.updateMany.mock.invocationCallOrder[renameCall]);
  });
});

describe('AppController createInvite', () => {
  it('supersedes an existing unused invite for the same email before creating a new one', async () => {
    // Regression for VW-25: nothing stopped multiple simultaneous pending
    // invites for one email at one venue.
    const managerProfile = {
      id: 'profile-manager', userId: 'user-1', venueId: 'venue-1', role: 'owner',
      allAccess: false, membershipStatus: 'active', fullName: 'Owner',
      venue: { id: 'venue-1', name: 'Test Venue' },
    };
    const deleteMany = vi.fn().mockResolvedValue({ count: 1 });
    const create = vi.fn().mockResolvedValue({ id: 'invite-new', code: 'VW-ABCDE', expiresAt: new Date() });
    const prisma: any = {
      profile: { findFirst: vi.fn().mockResolvedValue(managerProfile) },
      invite: { findUnique: vi.fn().mockResolvedValue(null), deleteMany, create },
    };
    prisma.$transaction = vi.fn((callback: any) => callback(prisma));
    const profiles = new ProfileService(prisma);
    const email = { send: vi.fn().mockResolvedValue(undefined) };
    const controller = new AppController(prisma, email as any, profiles);

    await controller.createInvite(
      { sub: 'user-1' } as any,
      { role: 'staff', jobTitle: 'Server', email: 'New.Hire@Example.com' } as any,
    );

    expect(deleteMany).toHaveBeenCalledWith({
      where: { venueId: 'venue-1', email: 'new.hire@example.com', usedBy: null },
    });
    expect(create).toHaveBeenCalledOnce();
    expect(deleteMany.mock.invocationCallOrder[0]).toBeLessThan(create.mock.invocationCallOrder[0]);
  });

  it('does not attempt to supersede when the invite has no email (phone-only staff invite)', async () => {
    const managerProfile = {
      id: 'profile-manager', userId: 'user-1', venueId: 'venue-1', role: 'owner',
      allAccess: false, membershipStatus: 'active', fullName: 'Owner',
      venue: { id: 'venue-1', name: 'Test Venue' },
    };
    const deleteMany = vi.fn().mockResolvedValue({ count: 0 });
    const create = vi.fn().mockResolvedValue({ id: 'invite-new', code: 'VW-ABCDE', expiresAt: new Date() });
    const prisma: any = {
      profile: { findFirst: vi.fn().mockResolvedValue(managerProfile) },
      invite: { findUnique: vi.fn().mockResolvedValue(null), deleteMany, create },
    };
    prisma.$transaction = vi.fn((callback: any) => callback(prisma));
    const profiles = new ProfileService(prisma);
    const email = { send: vi.fn().mockResolvedValue(undefined) };
    const controller = new AppController(prisma, email as any, profiles);

    await controller.createInvite(
      { sub: 'user-1' } as any,
      { role: 'staff', jobTitle: 'Server' } as any,
    );

    expect(deleteMany).not.toHaveBeenCalled();
    expect(create).toHaveBeenCalledOnce();
  });

  it('throws ForbiddenException when a non-elevated manager attempts to create a manager invite', async () => {
    const plainManagerProfile = {
      id: 'profile-mgr', userId: 'user-2', venueId: 'venue-1', role: 'manager',
      allAccess: false, membershipStatus: 'active', fullName: 'Plain Manager',
      venue: { id: 'venue-1', name: 'Test Venue' },
    };
    const prisma: any = {
      profile: { findFirst: vi.fn().mockResolvedValue(plainManagerProfile) },
    };
    const profiles = new ProfileService(prisma);
    const email = { send: vi.fn().mockResolvedValue(undefined) };
    const controller = new AppController(prisma, email as any, profiles);

    await expect(
      controller.createInvite(
        { sub: 'user-2' } as any,
        { role: 'manager', jobTitle: 'Assistant Manager', email: 'mgr@example.com' } as any,
      ),
    ).rejects.toThrow('Only owners and administrators can invite managers.');
  });
});


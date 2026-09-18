import { describe, expect, it, vi } from 'vitest';
import { UnauthorizedException } from '@nestjs/common';
import { AuthService, SESSION_DURATION_MS } from './auth.service';
import { hashInviteToken } from '../common/invite-token';

describe('AuthService one-time codes', () => {
  it('generates ten-digit numeric codes', () => {
    const service = new AuthService({} as never);
    expect(service.generateOneTimeCode()).toMatch(/^\d{10}$/);
  });
});

describe('AuthService session lifetime', () => {
  it('limits sessions to one day', () => {
    expect(SESSION_DURATION_MS).toBe(24 * 60 * 60 * 1000);
  });
});

describe('AuthService invited signup lifecycle', () => {
  it('reserves a valid invite and creates an inactive venue membership until email verification', async () => {
    const invite = {
      id: 'invite-1',
      venueId: 'venue-1',
      email: null,
      phone: null,
      role: 'staff',
      jobTitle: 'Server',
    };
    const profile = {
      id: 'profile-1',
      userId: 'user-1',
      email: 'staff@example.com',
      fullName: 'Test Staff',
      venueId: 'venue-1',
      role: 'staff',
      jobTitle: 'Server',
      membershipStatus: 'pending',
      venue: { id: 'venue-1', name: 'Test Venue' },
    };
    const tx = {
      invite: {
        updateMany: vi.fn().mockResolvedValue({ count: 1 }),
        update: vi.fn().mockResolvedValue({}),
      },
      profile: {
        findFirst: vi.fn().mockResolvedValue(null),
        create: vi.fn().mockResolvedValue(profile),
      },
    };
    const prisma = {
      user: { findUnique: vi.fn().mockResolvedValue({ emailVerifiedAt: null }) },
      invite: { findFirst: vi.fn().mockResolvedValue(invite) },
      session: { create: vi.fn().mockResolvedValue({ id: 'session-1' }) },
      $transaction: vi.fn((callback: (transaction: typeof tx) => unknown) => callback(tx)),
    };
    const service = new AuthService(prisma as never);

    const result = await service.issueSession(
      'user-1',
      'staff@example.com',
      'Test Staff',
      'shared-manager-token',
    );

    expect(prisma.invite.findFirst).toHaveBeenCalledOnce();
    expect(tx.profile.create).toHaveBeenCalledWith(expect.objectContaining({
      data: expect.objectContaining({
        venueId: 'venue-1',
        role: 'staff',
        jobTitle: 'Server',
        membershipStatus: 'pending',
      }),
    }));
    expect(tx.invite.update).toHaveBeenCalledWith({
      where: { id: 'invite-1' },
      data: { usedBy: 'profile-1' },
    });
    expect(result.profile).toBe(profile);
  });
});

describe('AuthService.issueSession branch coverage', () => {
  it('plain login/signup with no invite token creates a default profile without a venue grant', async () => {
    const tx = {
      invite: {
        updateMany: vi.fn(),
        update: vi.fn(),
      },
      profile: {
        findFirst: vi.fn().mockResolvedValue(null),
        create: vi.fn().mockResolvedValue({ id: 'profile-new', venueId: undefined }),
      },
    };
    const prisma = {
      user: { findUnique: vi.fn().mockResolvedValue({ emailVerifiedAt: null }) },
      invite: { findFirst: vi.fn() },
      session: { create: vi.fn().mockResolvedValue({ id: 'session-1' }) },
      $transaction: vi.fn((callback: (transaction: typeof tx) => unknown) => callback(tx)),
    };
    const service = new AuthService(prisma as never);

    await service.issueSession('user-1', 'newuser@example.com');

    expect(prisma.invite.findFirst).not.toHaveBeenCalled();
    expect(tx.invite.updateMany).not.toHaveBeenCalled();
    expect(tx.profile.create).toHaveBeenCalledWith(expect.objectContaining({
      data: expect.objectContaining({
        userId: 'user-1',
        email: 'newuser@example.com',
        fullName: 'newuser',
        role: 'staff',
        jobTitle: 'Staff',
        venueId: undefined,
      }),
    }));
    expect(tx.profile.create.mock.calls[0][0].data).not.toHaveProperty('membershipStatus');
    expect(tx.invite.update).not.toHaveBeenCalled();
  });

  it('falls through to no-grant behavior when the invite token is not found, used, or expired', async () => {
    const tx = {
      invite: {
        updateMany: vi.fn(),
        update: vi.fn(),
      },
      profile: {
        findFirst: vi.fn().mockResolvedValue(null),
        create: vi.fn().mockResolvedValue({ id: 'profile-new' }),
      },
    };
    const prisma = {
      user: { findUnique: vi.fn().mockResolvedValue({ emailVerifiedAt: null }) },
      invite: { findFirst: vi.fn().mockResolvedValue(null) },
      session: { create: vi.fn().mockResolvedValue({ id: 'session-1' }) },
      $transaction: vi.fn((callback: (transaction: typeof tx) => unknown) => callback(tx)),
    };
    const service = new AuthService(prisma as never);

    await service.issueSession('user-1', 'newuser@example.com', undefined, 'stale-token');

    expect(prisma.invite.findFirst).toHaveBeenCalledWith({
      where: {
        OR: [{ tokenHash: hashInviteToken('stale-token') }, { code: { equals: 'stale-token', mode: 'insensitive' } }],
        usedBy: null,
        expiresAt: { gt: expect.any(Date) },
      },
    });
    expect(tx.invite.updateMany).not.toHaveBeenCalled();
    expect(tx.invite.update).not.toHaveBeenCalled();
    expect(tx.profile.create).toHaveBeenCalledWith(expect.objectContaining({
      data: expect.objectContaining({ venueId: undefined }),
    }));
  });

  it('rejects when the invite was sent to a different email address, without starting a transaction', async () => {
    const invite = {
      id: 'invite-mismatch',
      venueId: 'venue-1',
      email: 'manager@example.com',
      phone: null,
      role: 'manager',
      jobTitle: 'Manager',
    };
    const prisma = {
      user: { findUnique: vi.fn().mockResolvedValue({ emailVerifiedAt: null }) },
      invite: { findFirst: vi.fn().mockResolvedValue(invite) },
      session: { create: vi.fn() },
      $transaction: vi.fn(),
    };
    const service = new AuthService(prisma as never);

    await expect(
      service.issueSession('user-1', 'someoneelse@example.com', undefined, 'manager-token'),
    ).rejects.toThrow(UnauthorizedException);

    expect(prisma.$transaction).not.toHaveBeenCalled();
  });

  it('rejects when the invite was sent to a different phone number and carries no email', async () => {
    const invite = {
      id: 'invite-phone-mismatch',
      venueId: 'venue-1',
      email: null,
      phone: '15551234567',
      role: 'staff',
      jobTitle: 'Server',
    };
    const prisma = {
      user: { findUnique: vi.fn().mockResolvedValue({ emailVerifiedAt: null }) },
      invite: { findFirst: vi.fn().mockResolvedValue(invite) },
      session: { create: vi.fn() },
      $transaction: vi.fn(),
    };
    const service = new AuthService(prisma as never);

    await expect(
      service.issueSession('user-1', 'staff@example.com', undefined, 'phone-token', '(555) 999-8888'),
    ).rejects.toThrow(UnauthorizedException);

    expect(prisma.$transaction).not.toHaveBeenCalled();
  });

  it('treats a claim race (updateMany count 0) as no active invite', async () => {
    const invite = {
      id: 'invite-race',
      venueId: 'venue-1',
      email: null,
      phone: null,
      role: 'staff',
      jobTitle: 'Server',
    };
    const tx = {
      invite: {
        updateMany: vi.fn().mockResolvedValue({ count: 0 }),
        update: vi.fn(),
      },
      profile: {
        findFirst: vi.fn().mockResolvedValue(null),
        create: vi.fn().mockResolvedValue({ id: 'profile-new' }),
      },
    };
    const prisma = {
      user: { findUnique: vi.fn().mockResolvedValue({ emailVerifiedAt: null }) },
      invite: { findFirst: vi.fn().mockResolvedValue(invite) },
      session: { create: vi.fn().mockResolvedValue({ id: 'session-1' }) },
      $transaction: vi.fn((callback: (transaction: typeof tx) => unknown) => callback(tx)),
    };
    const service = new AuthService(prisma as never);

    await service.issueSession('user-1', 'staff@example.com', undefined, 'shared-token');

    expect(tx.invite.updateMany).toHaveBeenCalledWith({
      where: { id: 'invite-race', usedBy: null },
      data: { usedBy: 'pending:user-1' },
    });
    // Lost the claim race -> no grant -> create path with no venueId, and the
    // final invite.update (marking usedBy the resulting profile id) never runs.
    expect(tx.profile.create).toHaveBeenCalledWith(expect.objectContaining({
      data: expect.objectContaining({ venueId: undefined }),
    }));
    expect(tx.invite.update).not.toHaveBeenCalled();
  });

  it('surfaces a matching unclaimed roster row as pendingAdoption instead of merging it automatically', async () => {
    // A bare verified-email match used to be adopted silently on every login
    // with no invite-token proof and no confirmation — see AuthService's
    // findAdoptableProfile doc comment. It must now only ever be a candidate
    // the caller confirms via confirmProfileAdoption().
    const existingProfile = { id: 'existing-1', userId: 'user-1', venueId: null, fullName: 'Placeholder Self', trialEndsAt: new Date() };
    const placeholderProfile = {
      id: 'placeholder-1',
      userId: null,
      venueId: 'venue-9',
      fullName: 'Invited Manager',
      role: 'manager',
      venue: { id: 'venue-9', name: 'Other Venue' },
    };
    const updatedExistingProfile = { ...existingProfile, email: 'manager@example.com' };
    const tx = {
      invite: { updateMany: vi.fn(), update: vi.fn() },
      profile: {
        findFirst: vi.fn()
          .mockResolvedValueOnce(existingProfile) // existingByUser lookup (where: { userId })
          .mockResolvedValueOnce(null) // no established workplace profile
          .mockResolvedValueOnce(placeholderProfile), // adoptableProfile lookup
        delete: vi.fn(),
        update: vi.fn().mockResolvedValue(updatedExistingProfile),
        create: vi.fn(),
      },
      auditLog: { create: vi.fn().mockResolvedValue({}) },
    };
    const prisma = {
      user: { findUnique: vi.fn().mockResolvedValue({ emailVerifiedAt: new Date() }) },
      invite: { findFirst: vi.fn() },
      session: { create: vi.fn().mockResolvedValue({ id: 'session-1' }) },
      $transaction: vi.fn((callback: (transaction: typeof tx) => unknown) => callback(tx)),
    };
    const service = new AuthService(prisma as never);

    const result = await service.issueSession('user-1', 'manager@example.com');

    // Nothing about the caller's own profile changes because of the match.
    expect(tx.profile.delete).not.toHaveBeenCalled();
    expect(tx.profile.update).toHaveBeenCalledWith({
      where: { id: 'existing-1' },
      data: { email: 'manager@example.com' },
      include: { venue: true },
    });
    expect(tx.auditLog.create).not.toHaveBeenCalled();
    expect(result.profile).toBe(updatedExistingProfile);
    expect(result.pendingAdoption).toEqual({
      profileId: 'placeholder-1',
      venueId: 'venue-9',
      venueName: 'Other Venue',
      role: 'manager',
    });
  });

  it('does not surface pendingAdoption when the caller already belongs to a different venue', async () => {
    const existingProfile = { id: 'existing-1', userId: 'user-1', venueId: 'venue-1', fullName: 'Real Member', trialEndsAt: new Date() };
    const placeholderProfile = {
      id: 'placeholder-1',
      userId: null,
      venueId: 'venue-9',
      fullName: 'Invited Manager',
      role: 'manager',
      venue: { id: 'venue-9', name: 'Other Venue' },
    };
    const tx = {
      invite: { updateMany: vi.fn(), update: vi.fn() },
      profile: {
        findFirst: vi.fn()
          .mockResolvedValueOnce(existingProfile)
          .mockResolvedValueOnce(placeholderProfile),
        delete: vi.fn(),
        update: vi.fn().mockResolvedValue(existingProfile),
        create: vi.fn(),
      },
      auditLog: { create: vi.fn() },
    };
    const prisma = {
      user: { findUnique: vi.fn().mockResolvedValue({ emailVerifiedAt: new Date() }) },
      invite: { findFirst: vi.fn() },
      session: { create: vi.fn().mockResolvedValue({ id: 'session-1' }) },
      $transaction: vi.fn((callback: (transaction: typeof tx) => unknown) => callback(tx)),
    };
    const service = new AuthService(prisma as never);

    const result = await service.issueSession('user-1', 'manager@example.com');

    expect(result.pendingAdoption).toBeNull();
  });

  it('creates a new profile for the invited venue when the user already has a profile at a different venue', async () => {
    const invite = {
      id: 'invite-other-venue',
      venueId: 'venue-2',
      email: null,
      phone: null,
      role: 'manager',
      jobTitle: 'General Manager',
    };
    const existingProfileAtOtherVenue = {
      id: 'existing-2',
      userId: 'user-1',
      venueId: 'venue-1',
      fullName: 'Original Name',
      venue: { id: 'venue-1', name: 'Venue One' },
    };
    const createdProfile = { id: 'profile-venue-2', venueId: 'venue-2' };
    const tx = {
      invite: {
        updateMany: vi.fn().mockResolvedValue({ count: 1 }),
        update: vi.fn().mockResolvedValue({}),
      },
      profile: {
        findFirst: vi.fn()
          .mockResolvedValueOnce(null) // existingProfileForVenue (venue-2) - none yet
          .mockResolvedValueOnce(existingProfileAtOtherVenue), // existingByUser - profile at venue-1
        create: vi.fn().mockResolvedValue(createdProfile),
      },
    };
    const prisma = {
      user: { findUnique: vi.fn().mockResolvedValue({ emailVerifiedAt: null }) },
      invite: { findFirst: vi.fn().mockResolvedValue(invite) },
      session: { create: vi.fn().mockResolvedValue({ id: 'session-1' }) },
      $transaction: vi.fn((callback: (transaction: typeof tx) => unknown) => callback(tx)),
    };
    const service = new AuthService(prisma as never);

    await service.issueSession('user-1', 'manager@example.com', undefined, 'other-venue-token');

    expect(tx.profile.create).toHaveBeenCalledWith(expect.objectContaining({
      data: expect.objectContaining({
        userId: 'user-1',
        email: 'manager@example.com',
        fullName: 'Original Name',
        role: 'manager',
        jobTitle: 'General Manager',
        venueId: 'venue-2',
        membershipStatus: 'pending',
      }),
    }));
    expect(tx.invite.update).toHaveBeenCalledWith({
      where: { id: 'invite-other-venue' },
      data: { usedBy: 'profile-venue-2' },
    });
  });

  it('plain-updates an existing profile (no adoption, no venue grant) and backfills a missing trial end date', async () => {
    const existingProfile = {
      id: 'existing-3',
      userId: 'user-1',
      venueId: 'venue-3',
      fullName: 'Old Name',
      trialEndsAt: null,
      venue: { id: 'venue-3', name: 'Venue Three' },
    };
    const updatedProfile = { ...existingProfile, fullName: 'New Name' };
    const tx = {
      invite: { updateMany: vi.fn(), update: vi.fn() },
      profile: {
        findFirst: vi.fn().mockResolvedValue(existingProfile),
        update: vi.fn().mockResolvedValue(updatedProfile),
        create: vi.fn(),
      },
    };
    const prisma = {
      user: { findUnique: vi.fn().mockResolvedValue({ emailVerifiedAt: null }) },
      invite: { findFirst: vi.fn() },
      session: { create: vi.fn().mockResolvedValue({ id: 'session-1' }) },
      $transaction: vi.fn((callback: (transaction: typeof tx) => unknown) => callback(tx)),
    };
    const service = new AuthService(prisma as never);

    const result = await service.issueSession('user-1', 'staff@example.com', 'New Name');

    expect(tx.profile.update).toHaveBeenCalledWith({
      where: { id: 'existing-3' },
      data: {
        email: 'staff@example.com',
        fullName: 'New Name',
        trialEndsAt: expect.any(Date),
      },
      include: { venue: true },
    });
    expect(tx.profile.create).not.toHaveBeenCalled();
    expect(result.profile).toBe(updatedProfile);
  });
});

describe('AuthService.confirmProfileAdoption', () => {
  it('adopts the candidate profile after re-validating it is still unclaimed and matches the caller\'s verified email', async () => {
    const candidate = {
      id: 'placeholder-1',
      userId: null,
      email: 'manager@example.com',
      venueId: 'venue-9',
      role: 'manager',
      venue: { id: 'venue-9', name: 'Other Venue' },
    };
    const adopted = { ...candidate, userId: 'user-1', membershipStatus: 'active' };
    const tx = {
      profile: {
        findFirst: vi.fn()
          .mockResolvedValueOnce(candidate) // candidate re-check
          .mockResolvedValueOnce(null), // existingByUser lookup
        delete: vi.fn(),
        update: vi.fn().mockResolvedValue(adopted),
      },
      auditLog: { create: vi.fn().mockResolvedValue({}) },
    };
    const prisma = {
      user: { findUnique: vi.fn().mockResolvedValue({ email: 'manager@example.com', emailVerifiedAt: new Date() }) },
      $transaction: vi.fn((callback: (transaction: typeof tx) => unknown) => callback(tx)),
    };
    const service = new AuthService(prisma as never);

    const result = await service.confirmProfileAdoption('user-1', 'placeholder-1');

    expect(tx.profile.delete).not.toHaveBeenCalled();
    // membershipStatus must be 'active', not 'pending' — AuthGuard only ever
    // resolves null/'active' profiles (ACTIVE_MEMBERSHIP), and nothing else
    // in the system would activate a row created by this confirm flow.
    expect(tx.profile.update).toHaveBeenCalledWith({
      where: expect.objectContaining({ id: 'placeholder-1', userId: null, OR: [{ membershipStatus: null }, { membershipStatus: 'active' }] }),
      data: { userId: 'user-1', role: 'manager', membershipStatus: 'active' },
      include: { venue: true },
    });
    expect(tx.auditLog.create).toHaveBeenCalledWith(expect.objectContaining({
      data: expect.objectContaining({ action: 'profile_adopted', targetProfileId: 'placeholder-1' }),
    }));
    expect(result).toBe(adopted);
  });

  it('preserves the caller\'s venueless profile and its related history when adopting', async () => {
    const existingByUser = { id: 'existing-1', userId: 'user-1', venueId: null };
    const candidate = {
      id: 'placeholder-1', userId: null, email: 'manager@example.com', venueId: 'venue-9', role: 'staff',
      venue: { id: 'venue-9', name: 'Other Venue' },
    };
    const tx = {
      profile: {
        findFirst: vi.fn().mockResolvedValueOnce(candidate).mockResolvedValueOnce(existingByUser),
        delete: vi.fn().mockResolvedValue(existingByUser),
        update: vi.fn().mockResolvedValue({ ...candidate, userId: 'user-1' }),
      },
      auditLog: { create: vi.fn().mockResolvedValue({}) },
    };
    const prisma = {
      user: { findUnique: vi.fn().mockResolvedValue({ email: 'manager@example.com', emailVerifiedAt: new Date() }) },
      $transaction: vi.fn((callback: (transaction: typeof tx) => unknown) => callback(tx)),
    };
    const service = new AuthService(prisma as never);

    await service.confirmProfileAdoption('user-1', 'placeholder-1');

    expect(tx.profile.delete).not.toHaveBeenCalled();
  });

  it('rejects when the caller already belongs to a different venue', async () => {
    const existingByUser = { id: 'existing-1', userId: 'user-1', venueId: 'venue-1' };
    const candidate = {
      id: 'placeholder-1', userId: null, email: 'manager@example.com', venueId: 'venue-9', role: 'staff',
      venue: { id: 'venue-9', name: 'Other Venue' },
    };
    const tx = {
      profile: {
        findFirst: vi.fn().mockResolvedValueOnce(candidate).mockResolvedValueOnce(existingByUser),
        delete: vi.fn(),
        update: vi.fn(),
      },
      auditLog: { create: vi.fn() },
    };
    const prisma = {
      user: { findUnique: vi.fn().mockResolvedValue({ email: 'manager@example.com', emailVerifiedAt: new Date() }) },
      $transaction: vi.fn((callback: (transaction: typeof tx) => unknown) => callback(tx)),
    };
    const service = new AuthService(prisma as never);

    await expect(service.confirmProfileAdoption('user-1', 'placeholder-1')).rejects.toThrow(UnauthorizedException);
    expect(tx.profile.update).not.toHaveBeenCalled();
  });

  it('rejects when the candidate no longer matches (already claimed, deleted, or a stale id)', async () => {
    const tx = {
      profile: { findFirst: vi.fn().mockResolvedValue(null), delete: vi.fn(), update: vi.fn() },
      auditLog: { create: vi.fn() },
    };
    const prisma = {
      user: { findUnique: vi.fn().mockResolvedValue({ email: 'manager@example.com', emailVerifiedAt: new Date() }) },
      $transaction: vi.fn((callback: (transaction: typeof tx) => unknown) => callback(tx)),
    };
    const service = new AuthService(prisma as never);

    await expect(service.confirmProfileAdoption('user-1', 'stale-id')).rejects.toThrow(UnauthorizedException);
  });

  it('rejects when the account has not verified its email', async () => {
    const prisma = {
      user: { findUnique: vi.fn().mockResolvedValue({ email: 'manager@example.com', emailVerifiedAt: null }) },
      $transaction: vi.fn(),
    };
    const service = new AuthService(prisma as never);

    await expect(service.confirmProfileAdoption('user-1', 'placeholder-1')).rejects.toThrow(UnauthorizedException);
    expect(prisma.$transaction).not.toHaveBeenCalled();
  });
});

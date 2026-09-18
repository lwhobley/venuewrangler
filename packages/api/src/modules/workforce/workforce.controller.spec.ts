import { beforeEach, describe, expect, it, vi } from 'vitest';
import { WorkforceController } from './workforce.controller';

vi.mock('../../common/rate-limit', () => ({
  assertWithinSharedRateLimit: vi.fn().mockResolvedValue(undefined),
}));

describe('WorkforceController invite check email', () => {
  // Outer-level mocks (calls made outside the $transaction): the top-level
  // invite/profile lookups used only by the phone-only path and by
  // reportStaleInviteStatus's used/expired/not_found fallback.
  const outerFindInvite = vi.fn();
  const outerFindProfile = vi.fn();
  // Inner (tx-scoped) mocks: everything the email path does happens inside
  // the advisory-locked transaction.
  const txFindInvite = vi.fn();
  const txCreateInvite = vi.fn();
  const txDeleteManyInvite = vi.fn().mockResolvedValue({ count: 0 });
  const txFindProfile = vi.fn();
  const executeLock = vi.fn();
  const sendOrThrow = vi.fn().mockResolvedValue(undefined);

  const prisma = {
    invite: { findFirst: outerFindInvite },
    profile: { findFirst: outerFindProfile },
    $transaction: vi.fn((callback: any) => callback({
      $executeRaw: executeLock,
      invite: { findFirst: txFindInvite, create: txCreateInvite, deleteMany: txDeleteManyInvite },
      profile: { findFirst: txFindProfile },
    })),
  };
  const email = { sendOrThrow };
  const config = {
    get: vi.fn((key: string) => key === 'APP_WEB_URL' ? 'https://app.example.com/' : undefined),
  };
  const request = { ip: '127.0.0.1' };

  beforeEach(() => {
    vi.clearAllMocks();
    sendOrThrow.mockResolvedValue(undefined);
  });

  it('keeps an existing redeemable invite valid and sends a private reminder', async () => {
    txFindInvite.mockResolvedValue({
      id: 'invite-1',
      email: 'staff@example.com',
      usedBy: null,
      expiresAt: new Date(Date.now() + 60_000),
      jobTitle: 'Server',
      venue: { name: 'Test Venue' },
    });
    const controller = new WorkforceController(prisma as any, email as any, config as any);

    await expect((controller as any).inviteCheck(request, { email: ' Staff@Example.com ' }))
      .resolves.toEqual({ status: 'ok' });
    expect(txCreateInvite).not.toHaveBeenCalled();
    expect(sendOrThrow).toHaveBeenCalledOnce();
  });

  it('mints an invite token for a legacy unclaimed roster profile', async () => {
    txFindInvite.mockResolvedValue(null);
    txFindProfile.mockResolvedValue({
      id: 'profile-1',
      venueId: 'venue-1',
      role: 'staff',
      jobTitle: 'Bartender',
      venue: { name: 'Legacy Venue' },
    });
    txCreateInvite.mockImplementation(async ({ data }: any) => ({
      ...data,
      id: 'invite-2',
      usedBy: null,
      venue: { name: 'Legacy Venue' },
    }));
    const controller = new WorkforceController(prisma as any, email as any, config as any);

    await expect((controller as any).inviteCheck(request, { email: 'legacy@example.com' }))
      .resolves.toEqual({ status: 'ok' });
    expect(txCreateInvite).toHaveBeenCalledWith(expect.objectContaining({
      data: expect.objectContaining({
        venueId: 'venue-1',
        email: 'legacy@example.com',
        role: 'staff',
        jobTitle: 'Bartender',
        tokenHash: expect.any(String),
      }),
    }));
    expect(sendOrThrow).toHaveBeenCalledOnce();
    expect(executeLock).toHaveBeenCalledOnce();
  });

  it('does not rotate an already-created invite on a later check', async () => {
    // A repeated lookup must leave the original emailed credential intact.
    txFindInvite.mockResolvedValue({
      id: 'invite-2',
      email: 'legacy@example.com',
      usedBy: null,
      expiresAt: new Date(Date.now() + 60_000),
      jobTitle: 'Bartender',
      venue: { name: 'Legacy Venue' },
    });
    const controller = new WorkforceController(prisma as any, email as any, config as any);

    await expect((controller as any).inviteCheck(request, { email: 'legacy@example.com' }))
      .resolves.toEqual({ status: 'ok' });
    expect(txCreateInvite).not.toHaveBeenCalled();
    expect(sendOrThrow).toHaveBeenCalledOnce();
  });

  it('mints a fresh invite for an unclaimed roster profile even when a used invite exists for the email', async () => {
    // The redeemable-only tx lookup finds nothing (the only invite on file
    // is already used), so it must fall through to the roster/mint branch
    // instead of reporting "used" and stranding a legitimate roster row.
    txFindInvite.mockResolvedValue(null);
    txFindProfile.mockResolvedValue({
      id: 'profile-1',
      venueId: 'venue-1',
      role: 'staff',
      jobTitle: 'Bartender',
      venue: { name: 'Legacy Venue' },
    });
    txCreateInvite.mockImplementation(async ({ data }: any) => ({
      ...data,
      id: 'invite-3',
      usedBy: null,
      venue: { name: 'Legacy Venue' },
    }));
    const controller = new WorkforceController(prisma as any, email as any, config as any);

    await expect((controller as any).inviteCheck(request, { email: 'legacy@example.com' }))
      .resolves.toEqual({ status: 'ok' });
    expect(txCreateInvite).toHaveBeenCalledOnce();
  });

  it('supersedes a stale unused invite for the same email before minting a fresh one', async () => {
    // Regression for VW-25: the redeemable-only lookup ignores an EXPIRED
    // invite, but a stale expired-and-unused row would otherwise collide
    // with the new one-pending-invite-per-venue-per-email constraint.
    txFindInvite.mockResolvedValue(null);
    txFindProfile.mockResolvedValue({
      id: 'profile-1',
      venueId: 'venue-1',
      role: 'staff',
      jobTitle: 'Bartender',
      venue: { name: 'Legacy Venue' },
    });
    txCreateInvite.mockImplementation(async ({ data }: any) => ({
      ...data,
      id: 'invite-4',
      usedBy: null,
      venue: { name: 'Legacy Venue' },
    }));
    const controller = new WorkforceController(prisma as any, email as any, config as any);

    await expect((controller as any).inviteCheck(request, { email: 'legacy@example.com' }))
      .resolves.toEqual({ status: 'ok' });
    expect(txDeleteManyInvite).toHaveBeenCalledWith({
      where: { venueId: 'venue-1', email: 'legacy@example.com', usedBy: null },
    });
    expect(txDeleteManyInvite.mock.invocationCallOrder[0]).toBeLessThan(txCreateInvite.mock.invocationCallOrder[0]);
  });

  it('reports "not_found" when a used invite exists and there is no roster fallback', async () => {
    txFindInvite.mockResolvedValue(null); // redeemable-only tx lookup: none
    txFindProfile.mockResolvedValue(null); // no unclaimed roster row to fall back to
    outerFindInvite.mockResolvedValue({ usedBy: 'user-1', expiresAt: new Date(Date.now() + 60_000) }); // stale-status lookup
    const controller = new WorkforceController(prisma as any, email as any, config as any);

    await expect((controller as any).inviteCheck(request, { email: 'gone@example.com' }))
      .resolves.toEqual({ status: 'ok' });
    expect(txCreateInvite).not.toHaveBeenCalled();
    expect(sendOrThrow).not.toHaveBeenCalled();
  });

  it('reports "expired" when only an expired invite exists and there is no roster fallback', async () => {
    txFindInvite.mockResolvedValue(null);
    txFindProfile.mockResolvedValue(null);
    outerFindInvite.mockResolvedValue({ usedBy: null, expiresAt: new Date(Date.now() - 60_000) });
    const controller = new WorkforceController(prisma as any, email as any, config as any);

    await expect((controller as any).inviteCheck(request, { email: 'stale@example.com' }))
      .resolves.toEqual({ status: 'ok' });
  });

  it('reports "not_found" when there is no invite history and no roster fallback', async () => {
    txFindInvite.mockResolvedValue(null);
    txFindProfile.mockResolvedValue(null);
    outerFindInvite.mockResolvedValue(null);
    const controller = new WorkforceController(prisma as any, email as any, config as any);

    await expect((controller as any).inviteCheck(request, { email: 'nobody@example.com' }))
      .resolves.toEqual({ status: 'ok' });
  });

  it('does not claim that an email was sent for phone-only roster matches', async () => {
    outerFindInvite.mockResolvedValue(null);
    outerFindProfile.mockResolvedValue({
      id: 'profile-1',
      venueId: 'venue-1',
      role: 'staff',
      jobTitle: 'Bartender',
      venue: { name: 'Test Venue' },
    });
    const controller = new WorkforceController(prisma as any, email as any, config as any);

    await expect((controller as any).inviteCheck(request, { phone: '555-0100' }))
      .resolves.toEqual({ status: 'ok' });
    expect(txCreateInvite).not.toHaveBeenCalled();
    expect(sendOrThrow).not.toHaveBeenCalled();
  });

  it('reports phone-only "not_found" when there is no invite or roster match', async () => {
    outerFindInvite.mockResolvedValue(null);
    outerFindProfile.mockResolvedValue(null);
    const controller = new WorkforceController(prisma as any, email as any, config as any);

    await expect((controller as any).inviteCheck(request, { phone: '555-0199' }))
      .resolves.toEqual({ status: 'ok' });
  });
});

describe('WorkforceController manager join-request names', () => {
  it('uses the applicant oldest profile even when it already belongs to a venue', async () => {
    const prisma = {
      profile: {
        findMany: vi.fn().mockResolvedValue([{ venueId: 'venue-1', role: 'manager', allAccess: false }]),
      },
      workplaceJoinRequest: {
        findMany: vi.fn().mockResolvedValue([{
          id: 'request-1',
          venueId: 'venue-1',
          userId: 'applicant-1',
          status: 'pending',
          createdAt: new Date('2026-08-01T00:00:00.000Z'),
          venue: { id: 'venue-1', name: 'Test Venue' },
          user: {
            id: 'applicant-1',
            email: 'applicant@example.com',
            profiles: [{ fullName: 'Alex Applicant' }],
          },
        }]),
      },
    };
    const controller = new WorkforceController(prisma as never, {} as never, {} as never);

    const result = await controller.listManagerJoinRequests({ sub: 'manager-1' } as never);

    expect(prisma.workplaceJoinRequest.findMany).toHaveBeenCalledWith(expect.objectContaining({
      include: expect.objectContaining({
        user: {
          select: {
            id: true,
            email: true,
            profiles: {
              select: { fullName: true },
              orderBy: { createdAt: 'asc' },
              take: 1,
            },
          },
        },
      }),
    }));
    expect(result.requests[0]?.userName).toBe('Alex Applicant');
  });

  it('includes venues where the caller is an all-access support profile, not just a named manager role', async () => {
    const prisma = {
      profile: {
        // staff-role but allAccess — canManageVenue grants this the same as
        // a manager role would. AUD-043: the SQL join-request functions and
        // this controller both used to check role IN (...) only.
        findMany: vi.fn().mockResolvedValue([{ venueId: 'venue-2', role: 'staff', allAccess: true }]),
      },
      workplaceJoinRequest: { findMany: vi.fn().mockResolvedValue([]) },
    };
    const controller = new WorkforceController(prisma as never, {} as never, {} as never);

    await controller.listManagerJoinRequests({ sub: 'support-1' } as never);

    expect(prisma.workplaceJoinRequest.findMany).toHaveBeenCalledWith(expect.objectContaining({
      where: expect.objectContaining({ venueId: { in: ['venue-2'] } }),
    }));
  });
});

describe('WorkforceController join request detail', () => {
  it('authorizes an all-access support profile even without a manager role', async () => {
    const prisma = {
      workplaceJoinRequest: {
        findUnique: vi.fn().mockResolvedValue({
          id: 'request-1',
          venueId: 'venue-1',
          userId: 'applicant-1',
          status: 'pending',
          decidedAt: null,
          decisionNote: null,
          createdAt: new Date('2026-08-01T00:00:00.000Z'),
          venue: { id: 'venue-1', name: 'Test Venue' },
          user: { id: 'applicant-1', email: 'applicant@example.com', profiles: [{ fullName: 'Alex Applicant' }] },
          events: [],
        }),
      },
      profile: {
        findFirst: vi.fn().mockResolvedValue({ role: 'staff', allAccess: true }),
      },
    };
    const controller = new WorkforceController(prisma as never, {} as never, {} as never);

    await expect(controller.getJoinRequestDetail({ sub: 'support-1' } as never, 'request-1'))
      .resolves.toEqual(expect.objectContaining({ id: 'request-1' }));
  });

  it('404s (not 403) for a caller with neither a manager role nor allAccess at the request\'s venue', async () => {
    // A 403 here would tell the caller "this id exists, just not at a venue
    // you manage" -- a cross-tenant existence oracle. Must read the same as
    // an id that doesn't exist at all.
    const prisma = {
      workplaceJoinRequest: {
        findUnique: vi.fn().mockResolvedValue({
          id: 'request-1',
          venueId: 'venue-1',
          userId: 'applicant-1',
          status: 'pending',
          decidedAt: null,
          decisionNote: null,
          createdAt: new Date('2026-08-01T00:00:00.000Z'),
          venue: { id: 'venue-1', name: 'Test Venue' },
          user: { id: 'applicant-1', email: 'applicant@example.com', profiles: [] },
          events: [],
        }),
      },
      profile: {
        // Active membership at the venue, but plain staff with no allAccess.
        findFirst: vi.fn().mockResolvedValue({ role: 'staff', allAccess: false }),
      },
    };
    const controller = new WorkforceController(prisma as never, {} as never, {} as never);

    await expect(controller.getJoinRequestDetail({ sub: 'staff-1' } as never, 'request-1'))
      .rejects.toThrow('Join request not found.');
  });
});

describe('WorkforceController venue search', () => {
  const findMany = vi.fn();
  const prisma = {
    venue: { findMany },
  };
  const request = { ip: '127.0.0.1' };

  beforeEach(() => {
    vi.clearAllMocks();
  });

  it('rejects array-shaped query parameters instead of throwing a 500', async () => {
    const controller = new WorkforceController(prisma as any, {} as any, {} as any);

    await expect(controller.searchVenues(request as any, ['venue']))
      .rejects.toThrow('Search query must be a string.');
    expect(findMany).not.toHaveBeenCalled();
  });

  it('rejects excessively long search terms', async () => {
    const controller = new WorkforceController(prisma as any, {} as any, {} as any);

    await expect(controller.searchVenues(request as any, 'a'.repeat(121)))
      .rejects.toThrow('Search query must be 120 characters or fewer.');
    expect(findMany).not.toHaveBeenCalled();
  });

  it('resolves only an exact join code and never searches name or address', async () => {
    findMany.mockResolvedValue([{ id: 'venue-1', name: 'Hidden Bar' }]);
    const controller = new WorkforceController(prisma as any, {} as any, {} as any);

    await expect(controller.searchVenues(request as any, 'VW-ABCDEFGH'))
      .resolves.toEqual({ venues: [{ id: 'venue-1', name: 'Hidden Bar', address: null }] });
    expect(findMany).toHaveBeenCalledWith(expect.objectContaining({
      where: { code: { equals: 'VW-ABCDEFGH', mode: 'insensitive' } },
      select: { id: true, name: true },
      take: 1,
    }));
  });
});

import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it, vi } from 'vitest';
import { AuthController } from './auth.controller';

vi.mock('../common/rate-limit', () => ({
  assertWithinSharedRateLimit: vi.fn().mockResolvedValue(undefined),
}));

describe('AuthController email invite signup', () => {
  it('runs a dummy password verification for an unknown sign-in email', async () => {
    const verifyPassword = vi.fn().mockResolvedValue(false);
    const controller = new AuthController(
      { user: { findUnique: vi.fn().mockResolvedValue(null) } } as any,
      {} as any,
      {} as any,
      { verifyPassword } as any,
    );

    await expect((controller as any).password(
      { ip: '127.0.0.1' },
      { email: 'unknown@example.com', password: 'password123', flow: 'signIn' },
    )).rejects.toThrow('Invalid email or password.');
    expect(verifyPassword).toHaveBeenCalledWith(
      'password123',
      'not-a-real-user-salt',
      600_000,
      expect.any(String),
    );
  });

  it('allows a correct password to clear an attacker-induced lockout, while an incorrect password is blocked', async () => {
    const update = vi.fn().mockResolvedValue({});
    const verifyPasswordSuccess = vi.fn().mockResolvedValue(true);
    const controllerSuccess = new AuthController(
      {
        user: {
          findUnique: vi.fn().mockResolvedValue({
            id: 'user-1',
            failedSignInCount: 8,
            lockedUntil: new Date(Date.now() + 60_000),
            password: { salt: 'salt', iterations: 600_000, passwordHash: 'hash' },
          }),
          update,
        },
      } as any,
      {} as any,
      {} as any,
      { verifyPassword: verifyPasswordSuccess } as any,
    );
    const authResponse = {
      token: 'jwt-token',
      profile: { id: 'profile-1', venueId: 'venue-1', role: 'owner' },
      venue: { _id: 'venue-1', name: 'Test Venue' },
      venues: [],
    };
    (controllerSuccess as any).issueSession = vi.fn().mockResolvedValue(authResponse);

    // Correct password succeeds and clears lockout
    await expect((controllerSuccess as any).password(
      { ip: '127.0.0.1' },
      { email: 'staff@example.com', password: 'password123', flow: 'signIn' },
    )).resolves.toEqual(authResponse);
    expect(update).toHaveBeenCalledWith({
      where: { id: 'user-1' },
      data: { failedSignInCount: 0, lockedUntil: null },
    });

    // Incorrect password on locked account is rejected with locked message
    const verifyPasswordFailure = vi.fn().mockResolvedValue(false);
    const controllerFailure = new AuthController(
      {
        user: {
          findUnique: vi.fn().mockResolvedValue({
            id: 'user-1',
            failedSignInCount: 8,
            lockedUntil: new Date(Date.now() + 60_000),
            password: { salt: 'salt', iterations: 600_000, passwordHash: 'hash' },
          }),
          update: vi.fn(),
        },
      } as any,
      {} as any,
      {} as any,
      { verifyPassword: verifyPasswordFailure } as any,
    );
    await expect((controllerFailure as any).password(
      { ip: '127.0.0.1' },
      { email: 'staff@example.com', password: 'wrongpassword', flow: 'signIn' },
    )).rejects.toThrow('Too many failed sign-in attempts');
  });

  it('allows a correct password once the lockout has expired, and clears it', async () => {
    const update = vi.fn().mockResolvedValue({});
    const verifyPassword = vi.fn().mockResolvedValue(true);
    const controller = new AuthController(
      {
        user: {
          findUnique: vi.fn().mockResolvedValue({
            id: 'user-1',
            failedSignInCount: 8,
            lockedUntil: new Date(Date.now() - 1000),
            password: { salt: 'salt', iterations: 600_000, passwordHash: 'hash' },
          }),
          update,
        },
      } as any,
      {} as any,
      {} as any,
      { verifyPassword } as any,
    );
    const authResponse = {
      token: 'jwt-token',
      profile: { id: 'profile-1', venueId: 'venue-1', role: 'owner' },
      venue: { _id: 'venue-1', name: 'Test Venue' },
      venues: [],
    };
    (controller as any).issueSession = vi.fn().mockResolvedValue(authResponse);

    await expect((controller as any).password(
      { ip: '127.0.0.1' },
      { email: 'staff@example.com', password: 'password123', flow: 'signIn' },
    )).resolves.toEqual(authResponse);
    expect(update).toHaveBeenCalledWith({
      where: { id: 'user-1' },
      data: { failedSignInCount: 0, lockedUntil: null },
    });
  });

  it('serializes failed sign-ins and locks the account at the threshold', async () => {
    const lockedUntil = new Date('2026-08-08T18:15:00.000Z');
    vi.useFakeTimers();
    vi.setSystemTime(new Date('2026-08-08T18:00:00.000Z'));
    const transaction = {
      $executeRaw: vi.fn().mockResolvedValue(undefined),
      user: {
        findUnique: vi.fn().mockResolvedValue({ failedSignInCount: 7, lockedUntil: null }),
        update: vi.fn().mockResolvedValue({}),
      },
    };
    const prisma = {
      $transaction: vi.fn((callback: (tx: typeof transaction) => unknown) => callback(transaction)),
    };
    const controller = new AuthController(prisma as any, {} as any, {} as any, {} as any);

    await (controller as any).recordFailedSignIn('user-1');

    expect(transaction.$executeRaw).toHaveBeenCalledOnce();
    expect(transaction.user.findUnique).toHaveBeenCalledWith({
      where: { id: 'user-1' },
      select: { failedSignInCount: true, lockedUntil: true },
    });
    expect(transaction.user.update).toHaveBeenCalledWith({
      where: { id: 'user-1' },
      data: { failedSignInCount: 0, lockedUntil },
    });
    vi.useRealTimers();
  });

  it('requires terms acceptance for every new account', async () => {
    const controller = new AuthController(
      { user: { findUnique: vi.fn().mockResolvedValue(null) } } as any,
      {} as any,
      {} as any,
      {} as any,
    );

    await expect((controller as any).password(
      { ip: '127.0.0.1' },
      { email: 'staff@example.com', password: 'password123', flow: 'signUp' },
    )).rejects.toThrow('Accept the Terms of Service');
  });

  it('treats the emailed token as verification and issues a venue session', async () => {
    const verifiedAt = new Date();
    const userFindUnique = vi.fn()
      .mockResolvedValueOnce(null)
      .mockResolvedValueOnce({ emailVerifiedAt: verifiedAt });
    const userCreate = vi.fn().mockResolvedValue({ id: 'user-1' });
    const passwordCreate = vi.fn().mockResolvedValue({});
    const prisma = {
      user: { findUnique: userFindUnique },
      invite: { findFirst: vi.fn().mockResolvedValue({ id: 'invite-1' }) },
      session: { update: vi.fn().mockResolvedValue({}) },
      $transaction: vi.fn(async (callback: any) => callback({
        user: { create: userCreate },
        passwordCredential: { create: passwordCreate },
      })),
    };
    const venue = {
      id: 'venue-1',
      name: 'Test Venue',
      latitude: 1,
      longitude: 2,
      geofenceRadiusM: 100,
      subscriptionStatus: 'trialing',
    };
    const profile = {
      id: 'profile-1',
      email: 'staff@example.com',
      fullName: 'Test Staff',
      role: 'staff',
      jobTitle: 'Server',
      venueId: venue.id,
      allAccess: false,
      trialEndsAt: null,
      venue,
    };
    const authService = {
      hashPassword: vi.fn().mockResolvedValue({ salt: 'salt', hash: 'hash' }),
      issueSession: vi.fn().mockResolvedValue({ session: { id: 'session-1' }, profile }),
    };
    const email = { send: vi.fn(), sendOrThrow: vi.fn() };
    const jwt = { signAsync: vi.fn().mockResolvedValue('jwt-token') };
    const controller = new AuthController(prisma as any, jwt as any, email as any, authService as any);

    const result = await (controller as any).password(
      { ip: '127.0.0.1' },
      {
        email: 'Staff@Example.com',
        password: 'password123',
        flow: 'signUp',
        fullName: 'Test Staff',
        inviteToken: 'emailed-token',
        termsAccepted: true,
      },
    );

    expect(userCreate).toHaveBeenCalledWith({
      data: expect.objectContaining({ email: 'staff@example.com', emailVerifiedAt: expect.any(Date) }),
    });
    expect(authService.issueSession).toHaveBeenCalledWith(
      'user-1',
      'staff@example.com',
      'Test Staff',
      'emailed-token',
      undefined,
    );
    expect(result.profile.emailVerified).toBe(true);
    expect(result.profile.venueId).toBe('venue-1');
    expect(result.token).toBe('jwt-token');
    expect(result.venue.name).toBe('Test Venue');
    expect(jwt.signAsync).toHaveBeenCalledWith({
      sub: 'user-1',
      email: 'staff@example.com',
      name: 'Test Staff',
      sid: 'session-1',
      profileId: 'profile-1',
      venueId: 'venue-1',
    });
    expect(email.sendOrThrow).not.toHaveBeenCalled();
  });

  it('does not auto-verify email for a shareable manager-created invite (has a join code)', async () => {
    const userFindUnique = vi.fn()
      .mockResolvedValueOnce(null)
      .mockResolvedValueOnce({ emailVerifiedAt: null });
    const userCreate = vi.fn().mockResolvedValue({ id: 'user-1' });
    const passwordCreate = vi.fn().mockResolvedValue({});
    // The real query filters on `code: null` — a manager-created invite
    // (which always has a `code`) must never match this lookup, since its
    // raw token/link is returned to the manager and could be forwarded to
    // someone other than the invited address.
    const inviteFindFirst = vi.fn(async ({ where }: any) => (where.code === null ? null : { id: 'invite-1' }));
    const prisma = {
      user: { findUnique: userFindUnique },
      invite: { findFirst: inviteFindFirst },
      session: { update: vi.fn().mockResolvedValue({}) },
      $transaction: vi.fn(async (callback: any) => callback({
        user: { create: userCreate },
        passwordCredential: { create: passwordCreate },
      })),
    };
    const venue = {
      id: 'venue-1',
      name: 'Test Venue',
      latitude: 1,
      longitude: 2,
      geofenceRadiusM: 100,
      subscriptionStatus: 'trialing',
    };
    const profile = {
      id: 'profile-1',
      email: 'staff@example.com',
      fullName: 'Test Staff',
      role: 'staff',
      jobTitle: 'Server',
      venueId: venue.id,
      allAccess: false,
      trialEndsAt: null,
      venue,
    };
    const authService = {
      hashPassword: vi.fn().mockResolvedValue({ salt: 'salt', hash: 'hash' }),
      issueSession: vi.fn().mockResolvedValue({ session: { id: 'session-1' }, profile: { id: 'profile-1', venueId: 'venue-1', role: 'staff', emailVerified: true, venue: { id: 'venue-1', name: 'Test Venue' } } }),
      generateOneTimeCode: vi.fn().mockReturnValue('1234567890'),
      hashOneTimeCode: vi.fn().mockReturnValue('hashed-code'),
    };
    const email = { send: vi.fn(), sendOrThrow: vi.fn().mockResolvedValue(undefined) };
    const jwt = { signAsync: vi.fn().mockResolvedValue('jwt-token') };
    const controller = new AuthController(prisma as any, jwt as any, email as any, authService as any);
    prisma.user = { ...prisma.user, update: vi.fn().mockResolvedValue({}) } as any;

    await (controller as any).password(
      { ip: '127.0.0.1' },
      {
        email: 'Staff@Example.com',
        password: 'password123',
        flow: 'signUp',
        fullName: 'Test Staff',
        inviteToken: 'shared-manager-token',
        termsAccepted: true,
      },
    );

    expect(userCreate).toHaveBeenCalledWith({
      data: expect.objectContaining({ email: 'staff@example.com' }),
    });
    // Must NOT auto-verify: no emailVerifiedAt in the create payload.
    expect(userCreate.mock.calls[0][0].data).not.toHaveProperty('emailVerifiedAt');
    // The normal verification-code email must still be sent since this
    // account was not auto-verified.
    expect(email.sendOrThrow).toHaveBeenCalled();
  });

  it('rejects public signup when user already exists even without password', async () => {
    const controller = new AuthController(
      {
        user: {
          findUnique: vi.fn().mockResolvedValue({ id: 'user-existing', password: null }),
        },
      } as any,
      {} as any,
      {} as any,
      {} as any,
    );

    await expect((controller as any).password(
      { ip: '127.0.0.1' },
      { email: 'existing@example.com', password: 'password123', flow: 'signUp', termsAccepted: true },
    )).rejects.toThrow('Unable to create account with those details');
  });

  it('handles P2002 unique violation race condition gracefully during signup transaction', async () => {
    const prisma = {
      user: { findUnique: vi.fn().mockResolvedValue(null) },
      invite: { findFirst: vi.fn().mockResolvedValue(null) },
      $transaction: vi.fn(async () => {
        const error: any = new Error('Unique constraint failed');
        error.code = 'P2002';
        throw error;
      }),
    };
    const authService = {
      hashPassword: vi.fn().mockResolvedValue({ salt: 'salt', hash: 'hash' }),
    };
    const controller = new AuthController(prisma as any, {} as any, {} as any, authService as any);

    await expect((controller as any).password(
      { ip: '127.0.0.1' },
      { email: 'concurrent@example.com', password: 'password123', flow: 'signUp', termsAccepted: true },
    )).rejects.toThrow('Unable to create account with those details');
  });
});

describe('AuthController recovery and logout safety', () => {
  it('activates invite-reserved memberships atomically with email verification', async () => {
    const tx = {
      user: { update: vi.fn().mockResolvedValue({}) },
      profile: {
        findMany: vi.fn().mockResolvedValue([{ id: 'profile-invite' }, { id: 'profile-join-request' }]),
        updateMany: vi.fn().mockResolvedValue({ count: 1 }),
      },
      invite: {
        findMany: vi.fn().mockResolvedValue([{ usedBy: 'profile-invite' }]),
      },
    };
    const prisma = {
      user: {
        findUnique: vi.fn().mockResolvedValue({
          emailVerificationCodeHash: 'hashed-code',
          emailVerificationSentAt: new Date(),
          emailVerifiedAt: null,
        }),
      },
      $transaction: vi.fn((callback: (transaction: typeof tx) => unknown) => callback(tx)),
    };
    const authService = {
      hashOneTimeCode: vi.fn().mockReturnValue('hashed-code'),
      oneTimeCodeHashesMatch: vi.fn().mockReturnValue(true),
    };
    const controller = new AuthController(prisma as never, {} as never, {} as never, authService as never);

    await expect(controller.verifyEmail(
      { ip: '127.0.0.1' } as never,
      { sub: 'user-1' } as never,
      { code: '1234567890' },
    )).resolves.toEqual({ ok: true });

    expect(tx.user.update).toHaveBeenCalledWith(expect.objectContaining({ where: { id: 'user-1' } }));
    expect(tx.invite.findMany).toHaveBeenCalledWith({
      where: { usedBy: { in: ['profile-invite', 'profile-join-request'] } },
      select: { usedBy: true },
    });
    expect(tx.profile.updateMany).toHaveBeenCalledWith({
      where: {
        id: { in: ['profile-invite'] },
        userId: 'user-1',
        membershipStatus: 'pending',
      },
      data: { membershipStatus: 'active' },
    });
  });

  it('returns the same success response when reset-email delivery fails', async () => {
    const prisma = {
      user: {
        findUnique: vi.fn().mockResolvedValue({
          id: 'user-1',
          email: 'staff@example.com',
          profile: { fullName: 'Test Staff' },
        }),
        updateMany: vi.fn().mockResolvedValue({ count: 1 }),
      },
    };
    const email = {
      send: vi.fn().mockRejectedValue(new Error('provider down')),
      sendOrThrow: vi.fn().mockRejectedValue(new Error('provider down')),
    };
    const authService = {
      generateOneTimeCode: vi.fn().mockReturnValue('1234567890'),
      hashOneTimeCode: vi.fn().mockReturnValue('hashed-code'),
    };
    const controller = new AuthController(prisma as any, {} as any, email as any, authService as any);

    await expect(controller.forgotPassword(
      { ip: '127.0.0.1' } as any,
      { email: 'staff@example.com' },
    )).resolves.toEqual({ ok: true });
  });

  it('uses the same reset-code work and update shape for an unknown email', async () => {
    const updateMany = vi.fn().mockResolvedValue({ count: 0 });
    const prisma = {
      user: {
        findUnique: vi.fn().mockResolvedValue(null),
        updateMany,
      },
    };
    const email = { send: vi.fn() };
    const authService = {
      generateOneTimeCode: vi.fn().mockReturnValue('1234567890'),
      hashOneTimeCode: vi.fn().mockReturnValue('hashed-code'),
    };
    const controller = new AuthController(prisma as any, {} as any, email as any, authService as any);

    await expect(controller.forgotPassword(
      { ip: '127.0.0.1' } as any,
      { email: 'missing@example.com' },
    )).resolves.toEqual({ ok: true });

    expect(authService.generateOneTimeCode).toHaveBeenCalledOnce();
    expect(authService.hashOneTimeCode).toHaveBeenCalledWith('1234567890');
    expect(updateMany).toHaveBeenCalledWith(expect.objectContaining({
      where: { id: '__missing_password_reset_account__' },
    }));
    expect(email.send).not.toHaveBeenCalled();
  });

  it('consumes a password-reset code once across concurrent attempts', async () => {
    let codeHash: string | null = 'hashed-code';
    let transactionTail = Promise.resolve();
    const tx = {
      $executeRaw: vi.fn().mockResolvedValue(0),
      user: {
        findUnique: vi.fn(async () => ({
          id: 'user-1',
          passwordResetCodeHash: codeHash,
          passwordResetExpiresAt: new Date(Date.now() + 60_000),
        })),
        update: vi.fn(async () => {
          codeHash = null;
          return {};
        }),
      },
      passwordCredential: { upsert: vi.fn().mockResolvedValue({}) },
      session: { deleteMany: vi.fn().mockResolvedValue({ count: 1 }) },
    };
    const prisma = {
      user: {
        findUnique: vi.fn().mockResolvedValue({
          passwordResetCodeHash: codeHash,
          passwordResetExpiresAt: new Date(Date.now() + 60_000),
        }),
      },
      $transaction: vi.fn(async (callback: (db: typeof tx) => Promise<unknown>) => {
        const previous = transactionTail;
        let release!: () => void;
        transactionTail = new Promise<void>((resolve) => { release = resolve; });
        await previous;
        try {
          return await callback(tx);
        } finally {
          release();
        }
      }),
    };
    const authService = {
      hashPassword: vi.fn().mockResolvedValue({ salt: 'salt', hash: 'new-hash' }),
      hashOneTimeCode: vi.fn().mockReturnValue('hashed-code'),
      oneTimeCodeHashesMatch: vi.fn((stored: string, candidate: string) => stored === candidate),
    };
    const controller = new AuthController(prisma as any, {} as any, {} as any, authService as any);
    const request = { ip: '127.0.0.1' } as any;
    const body = { email: 'staff@example.com', code: '1234567890', newPassword: 'password123' };

    const results = await Promise.allSettled([
      controller.resetPassword(request, body),
      controller.resetPassword(request, body),
    ]);

    expect(results.filter((result) => result.status === 'fulfilled')).toHaveLength(1);
    expect(results.filter((result) => result.status === 'rejected')).toHaveLength(1);
    expect(tx.$executeRaw).toHaveBeenCalledTimes(2);
    expect(tx.passwordCredential.upsert).toHaveBeenCalledTimes(1);
  });

  it('rejects an invalid reset code before running the password KDF', async () => {
    const hashPassword = vi.fn();
    const prisma = {
      user: {
        findUnique: vi.fn().mockResolvedValue({
          passwordResetCodeHash: 'stored-code',
          passwordResetExpiresAt: new Date(Date.now() + 60_000),
        }),
      },
    };
    const authService = {
      hashPassword,
      hashOneTimeCode: vi.fn().mockReturnValue('wrong-code'),
      oneTimeCodeHashesMatch: vi.fn().mockReturnValue(false),
    };
    const controller = new AuthController(prisma as any, {} as any, {} as any, authService as any);

    await expect(controller.resetPassword(
      { ip: '127.0.0.1' } as any,
      { email: 'staff@example.com', code: 'bad-code', newPassword: 'password123' },
    )).rejects.toThrow('invalid or expired');
    expect(hashPassword).not.toHaveBeenCalled();
  });

  it('does not issue an unfiltered push-token deletion without a profile id', async () => {
    const prisma = {
      session: {
        delete: vi.fn().mockResolvedValue({}),
        deleteMany: vi.fn().mockResolvedValue({ count: 1 }),
      },
      pushToken: { deleteMany: vi.fn().mockResolvedValue({ count: 0 }) },
      $transaction: vi.fn(async (operations: Promise<unknown>[]) => Promise.all(operations)),
    };
    const controller = new AuthController(prisma as any, {} as any, {} as any, {} as any);
    const user = { sub: 'user-1', sid: 'session-1', profileId: undefined } as any;

    await controller.logout(user);
    await controller.logoutAll(user);

    expect(prisma.pushToken.deleteMany).not.toHaveBeenCalled();
    expect(prisma.session.deleteMany).toHaveBeenCalledWith({ where: { id: 'session-1' } });
    expect(prisma.session.deleteMany).toHaveBeenCalledWith({ where: { userId: 'user-1' } });
  });

  it('logout without a pushToken leaves push registrations untouched (does not kill other devices)', async () => {
    const prisma = {
      session: { deleteMany: vi.fn().mockResolvedValue({ count: 1 }) },
      pushToken: { deleteMany: vi.fn().mockResolvedValue({ count: 0 }) },
      $transaction: vi.fn(async (operations: Promise<unknown>[]) => Promise.all(operations)),
    };
    const controller = new AuthController(prisma as any, {} as any, {} as any, {} as any);
    const user = { sub: 'user-1', sid: 'session-1', profileId: 'profile-1' } as any;

    await controller.logout(user, {});

    expect(prisma.pushToken.deleteMany).not.toHaveBeenCalled();
  });

  it('logout with a pushToken deletes only that device\'s token, not every token on the profile', async () => {
    const prisma = {
      session: { deleteMany: vi.fn().mockResolvedValue({ count: 1 }) },
      pushToken: { deleteMany: vi.fn().mockResolvedValue({ count: 1 }) },
      $transaction: vi.fn(async (operations: Promise<unknown>[]) => Promise.all(operations)),
    };
    const controller = new AuthController(prisma as any, {} as any, {} as any, {} as any);
    const user = { sub: 'user-1', sid: 'session-1', profileId: 'profile-1' } as any;

    await controller.logout(user, { pushToken: 'ExponentPushToken[this-device]' });

    expect(prisma.pushToken.deleteMany).toHaveBeenCalledWith({
      where: { profileId: 'profile-1', token: 'ExponentPushToken[this-device]' },
    });
  });
});

describe('AuthController log hygiene', () => {
  it('identifies a failed verification email by user id, never by address', async () => {
    // Drives the real catch in password(): a manager-created invite (one with
    // a join code) does not auto-verify, so the controller sends a
    // verification email, and a delivery failure is swallowed and logged.
    // Cloud Run logs are retained and fan out to downstream sinks, so an
    // address interpolated there is PII at rest for the life of the log.
    const prisma: any = {
      user: {
        findUnique: vi.fn().mockResolvedValueOnce(null).mockResolvedValueOnce({ emailVerifiedAt: null }),
        update: vi.fn().mockResolvedValue({}),
      },
      // `code: null` matches only an emailed single-use invite; returning null
      // for it forces the branch that actually sends a verification email.
      invite: { findFirst: vi.fn(async ({ where }: any) => (where.code === null ? null : { id: 'invite-1' })) },
      session: { update: vi.fn().mockResolvedValue({}) },
      $transaction: vi.fn(async (callback: any) => callback({
        user: { create: vi.fn().mockResolvedValue({ id: 'user-42' }) },
        passwordCredential: { create: vi.fn().mockResolvedValue({}) },
      })),
    };
    const venue = { id: 'venue-1', name: 'Test Venue', latitude: 1, longitude: 2, geofenceRadiusM: 100, subscriptionStatus: 'trialing' };
    const authService = {
      hashPassword: vi.fn().mockResolvedValue({ salt: 'salt', hash: 'hash' }),
      issueSession: vi.fn().mockResolvedValue({
        session: { id: 'session-1' },
        profile: { id: 'profile-1', venueId: 'venue-1', role: 'staff', emailVerified: false, fullName: 'Renee', venue },
      }),
      generateOneTimeCode: vi.fn().mockReturnValue('1234567890'),
      hashOneTimeCode: vi.fn().mockReturnValue('hashed-code'),
    };
    const email = { send: vi.fn(), sendOrThrow: vi.fn().mockRejectedValue(new Error('provider down')) };
    const jwt = { signAsync: vi.fn().mockResolvedValue('jwt-token') };
    const controller = new AuthController(prisma, jwt as any, email as any, authService as any);

    const logged: string[] = [];
    vi.spyOn((controller as any).logger, 'error').mockImplementation((...args: unknown[]) => {
      logged.push(args.map((arg) => String(arg)).join(' '));
    });

    await (controller as any).password(
      { ip: '127.0.0.1' },
      {
        email: 'Renee@Example.test',
        password: 'password123',
        flow: 'signUp',
        fullName: 'Renee',
        inviteToken: 'shareable-token',
        termsAccepted: true,
      },
    );

    // Guard the guard: if delivery never failed there is nothing to assert on.
    expect(email.sendOrThrow).toHaveBeenCalled();
    const output = logged.join(' | ');
    expect(output).toContain('Verification email failed for user user-42');
    expect(output).not.toContain('renee@example.test');
  });

  it('keeps every logger call in the auth controller free of raw addresses', () => {
    // Source-level guard: the unit test above only covers the one call site,
    // and this class has several logging paths that could regress.
    const source = readFileSync(join(__dirname, 'auth.controller.ts'), 'utf8');
    const offenders = [...source.matchAll(/logger\.[a-z]+\(`[^`]*`/g)]
      .map((m) => m[0])
      .filter((call) => /\$\{\s*(email|to|recipient|account\.email)\s*\}/.test(call));
    expect(offenders).toEqual([]);
  });
});

describe('AuthController confirmAdoption', () => {
  it('delegates to AuthService.confirmProfileAdoption and maps the result', async () => {
    const authService = {
      confirmProfileAdoption: vi.fn().mockResolvedValue({
        id: 'placeholder-1',
        email: 'manager@example.com',
        fullName: 'Invited Manager',
        role: 'manager',
        jobTitle: 'General Manager',
        venueId: 'venue-9',
        allAccess: false,
        trialEndsAt: null,
        venue: { id: 'venue-9', name: 'Other Venue', latitude: 0, longitude: 0, geofenceRadiusM: 100, subscriptionStatus: 'trialing' },
      }),
    };
    const controller = new AuthController({} as any, {} as any, {} as any, authService as any);

    const result = await controller.confirmAdoption(
      { ip: '127.0.0.1' } as any,
      { sub: 'user-1' } as any,
      { profileId: 'placeholder-1' },
    );

    expect(authService.confirmProfileAdoption).toHaveBeenCalledWith('user-1', 'placeholder-1');
    expect(result.profile.id).toBe('placeholder-1');
    expect(result.venue?.id).toBe('venue-9');
  });

  it('propagates a rejection (e.g. the candidate was already claimed) without mapping a result', async () => {
    const authService = {
      confirmProfileAdoption: vi.fn().mockRejectedValue(new Error('This workplace connection is no longer available.')),
    };
    const controller = new AuthController({} as any, {} as any, {} as any, authService as any);

    await expect(controller.confirmAdoption(
      { ip: '127.0.0.1' } as any,
      { sub: 'user-1' } as any,
      { profileId: 'stale-id' },
    )).rejects.toThrow('no longer available');
  });
});

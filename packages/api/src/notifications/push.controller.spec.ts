import { ConflictException, ForbiddenException } from '@nestjs/common';
import { describe, expect, it, vi } from 'vitest';
import { PushController } from './push.controller';

describe('PushController', () => {
  it('requires an active venue scope', async () => {
    const controller = new PushController({} as any);
    await expect(controller.registerPushToken(undefined, { token: 'ExponentPushToken[test]', platform: 'ios' }))
      .rejects.toBeInstanceOf(ForbiddenException);
  });

  it('binds a registered token to the authenticated profile and venue', async () => {
    const upsert = vi.fn().mockResolvedValue({ id: 'push-1' });
    const findUnique = vi.fn().mockResolvedValue({ profileId: 'profile-1', venueId: 'venue-1' });
    const controller = new PushController({
      $transaction: (callback: any) => callback({ $executeRaw: vi.fn(), pushToken: { findUnique, upsert } }),
    } as any);

    await expect(controller.registerPushToken(
      { profileId: 'profile-1', venueId: 'venue-1' } as any,
      { token: 'ExponentPushToken[test]', platform: 'android' },
    )).resolves.toEqual({ id: 'push-1', ok: true });

    expect(upsert).toHaveBeenCalledWith(expect.objectContaining({
      where: { venueId_token: { venueId: 'venue-1', token: 'ExponentPushToken[test]' } },
      update: expect.objectContaining({ profileId: 'profile-1', venueId: 'venue-1', enabled: true }),
    }));
  });

  it('rejects rebinding a token owned by another profile at the same venue', async () => {
    const controller = new PushController({
      $transaction: (callback: any) => callback({
        $executeRaw: vi.fn(),
        pushToken: { findUnique: vi.fn().mockResolvedValue({ profileId: 'other', venueId: 'venue-1' }) },
      }),
    } as any);
    await expect(controller.registerPushToken(
      { profileId: 'profile-1', venueId: 'venue-1' } as any,
      { token: 'ExponentPushToken[test]', platform: 'android' },
    )).rejects.toBeInstanceOf(ConflictException);
  });

  it('allows the same token to be registered at a different venue', async () => {
    const upsert = vi.fn().mockResolvedValue({ id: 'push-2' });
    // No existing row for (venue-2, token) even though the token is bound
    // elsewhere for venue-1 — that other venue's row is a separate key now.
    const findUnique = vi.fn().mockResolvedValue(null);
    const controller = new PushController({
      $transaction: (callback: any) => callback({ $executeRaw: vi.fn(), pushToken: { findUnique, upsert } }),
    } as any);

    await expect(controller.registerPushToken(
      { profileId: 'profile-1', venueId: 'venue-2' } as any,
      { token: 'ExponentPushToken[test]', platform: 'android' },
    )).resolves.toEqual({ id: 'push-2', ok: true });

    expect(findUnique).toHaveBeenCalledWith({ where: { venueId_token: { venueId: 'venue-2', token: 'ExponentPushToken[test]' } } });
  });
});

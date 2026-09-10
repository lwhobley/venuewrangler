import { randomUUID } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import type { PrismaClient } from '@prisma/client';
import { setupTestDb } from '../test/setup-test-db';
import { AuthService } from './auth.service';

describe('profile adoption persistence (PostgreSQL)', () => {
  let prisma: PrismaClient;
  let teardown = async () => {};
  let userId: string;
  let venueId: string;
  const profileIds: string[] = [];
  beforeAll(async () => { ({ prisma, teardown } = await setupTestDb()); });
  afterAll(async () => {
    if (prisma) {
      await prisma.profile.deleteMany({ where: { id: { in: profileIds } } });
      if (userId) await prisma.user.delete({ where: { id: userId } });
      if (venueId) await prisma.venue.delete({ where: { id: venueId } });
    }
    await teardown();
  });
  it('preserves the onboarding profile and selects the adopted workplace on the next login', async () => {
    const email = `${randomUUID()}@example.test`;
    userId = (await prisma.user.create({ data: { email, emailVerifiedAt: new Date() } })).id;
    venueId = (await prisma.venue.create({ data: { name: 'Adoption Test', code: randomUUID(), latitude: 0, longitude: 0, geofenceRadiusM: 100 } })).id;
    const old = await prisma.profile.create({ data: { userId, email, fullName: 'Test Member', role: 'staff', jobTitle: 'Staff', createdAt: new Date('2020-01-01') } });
    profileIds.push(old.id);
    const candidate = await prisma.profile.create({ data: { email, fullName: 'Test Member', role: 'staff', jobTitle: 'Staff', venueId, membershipStatus: 'active' } });
    profileIds.push(candidate.id);
    const service = new AuthService(prisma as never);
    expect(await service.pendingProfileAdoption(userId)).toMatchObject({ profileId: candidate.id });
    await service.confirmProfileAdoption(userId, candidate.id);
    expect(await prisma.profile.findUnique({ where: { id: old.id } })).toMatchObject({ userId, venueId: null });
    expect((await service.issueSession(userId, email)).profile.id).toBe(candidate.id);
    expect(await service.pendingProfileAdoption(userId)).toBeNull();
  });
});

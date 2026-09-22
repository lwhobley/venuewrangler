import { describe, expect, it, vi } from 'vitest';
import { AuthService } from './auth.service';

function fixture(status: string | null, existing: object | null = null) {
  const candidate = { id: 'candidate', userId: null, email: 'fixture@example.test', role: 'manager', venueId: 'venue-1', membershipStatus: status, venue: { id: 'venue-1', name: 'Fixture' } };
  const tx = { profile: {
    findFirst: vi.fn().mockResolvedValueOnce(candidate).mockResolvedValueOnce(existing),
    delete: vi.fn(), update: vi.fn(async ({ data }) => ({ ...candidate, ...data })),
  }, auditLog: { create: vi.fn() } };
  const prisma = { user: { findUnique: vi.fn(async () => ({ email: candidate.email, emailVerifiedAt: new Date() })) }, $transaction: vi.fn(async (fn) => fn(tx)) };
  return { service: new AuthService(prisma as never), tx };
}

describe('profile adoption safeguards', () => {
  it.each(['inactive', 'pending'])('never self-activates a %s roster entry', async (status) => {
    const { service, tx } = fixture(status);
    await expect(service.confirmProfileAdoption('user-1', 'candidate')).rejects.toThrow('no longer available');
    expect(tx.profile.update).not.toHaveBeenCalled();
    expect(tx.profile.delete).not.toHaveBeenCalled();
  });
  it('preserves an existing same-venue profile and all its relationships', async () => {
    const { service, tx } = fixture('active', { id: 'established', venueId: 'venue-1' });
    await expect(service.confirmProfileAdoption('user-1', 'candidate')).rejects.toThrow('already has a workplace');
    expect(tx.profile.delete).not.toHaveBeenCalled();
    expect(tx.profile.update).not.toHaveBeenCalled();
    expect(tx.profile.findFirst).toHaveBeenLastCalledWith(expect.objectContaining({ where: { userId: 'user-1', venueId: { not: null } } }));
  });
});

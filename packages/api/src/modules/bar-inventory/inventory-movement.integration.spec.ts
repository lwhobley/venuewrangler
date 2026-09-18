import { randomUUID } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it, vi } from 'vitest';
import type { PrismaClient } from '@prisma/client';
import { setupTestDb } from '../../test/setup-test-db';
import { InventoryMovementService } from './inventory-movement.service';

describe('inventory operation idempotency (PostgreSQL)', () => {
  let prisma: PrismaClient;
  let teardown = async () => {};
  let venueId: string;
  let itemId: string;
  beforeAll(async () => {
    ({ prisma, teardown } = await setupTestDb());
    const venue = await prisma.venue.create({ data: { name: 'Inventory Test', code: randomUUID(), latitude: 0, longitude: 0, geofenceRadiusM: 100 } });
    venueId = venue.id;
    const item = await prisma.barInventoryItem.create({ data: { venueId, name: 'Vodka', normalizedName: 'vodka', category: 'spirit', unit: 'bottle', onHand: 10, parLevel: 2 } });
    itemId = item.id;
  });
  afterAll(async () => {
    if (venueId) await prisma.venue.delete({ where: { id: venueId } });
    await teardown();
  });

  it('concurrent duplicate requests create one ledger entry and one stock update', async () => {
    const service = new InventoryMovementService(prisma as never, { notifyManagers: vi.fn() } as never);
    const request = { venueId, itemId, createdBy: 'test-manager', movementType: 'received' as const, quantity: 5, operationId: randomUUID() };
    const results = await Promise.all([service.record(request), service.record(request), service.record(request)]);
    expect(new Set(results.map((r) => r.movement.id)).size).toBe(1);
    expect(await prisma.barInventoryMovement.count({ where: { venueId, operationId: request.operationId } })).toBe(1);
    expect((await prisma.barInventoryItem.findUniqueOrThrow({ where: { id: itemId } })).onHand).toBe(15);
    await expect(service.record({ ...request, quantity: 6 })).rejects.toThrow('different request');
  });
});

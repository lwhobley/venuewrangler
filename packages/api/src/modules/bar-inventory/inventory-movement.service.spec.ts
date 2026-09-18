import { describe, expect, it, vi } from 'vitest';
import { InventoryMovementService } from './inventory-movement.service';

function fixture() {
  const rows: any[] = [];
  const item = { id: 'i1', name: 'Vodka', onHand: 10, parLevel: 5, unitCostCents: 2500, lastCountedAt: null };
  const tx = {
    $executeRaw: vi.fn(),
    barInventoryItem: { findFirst: vi.fn(async () => ({ ...item })), update: vi.fn(async ({ data }) => Object.assign(item, data)) },
    barInventoryMovement: {
      findFirst: vi.fn(async ({ where }) => rows.find((row) => row.venueId === where.venueId && row.operationId === where.operationId)),
      create: vi.fn(async ({ data }) => { const row = { id: 'm1', ...data }; rows.push(row); return row; }),
    },
  };
  const notifications = { notifyManagers: vi.fn(async () => undefined) };
  const prisma = { $transaction: vi.fn(async (fn) => fn(tx)) };
  return { service: new InventoryMovementService(prisma as never, notifications as never), tx, item, notifications };
}
const input = { venueId: 'v1', itemId: 'i1', createdBy: 'p1', movementType: 'received' as const, quantity: 5, operationId: 'queued_1' };

describe('inventory movement transactions', () => {
  it('replays a committed operation without applying stock twice', async () => {
    const { service, item, tx } = fixture();
    const first = await service.record(input);
    const retry = await service.record(input);
    expect(item.onHand).toBe(15);
    expect(retry.replayed).toBe(true);
    expect(retry.movement.id).toBe(first.movement.id);
    expect(tx.barInventoryMovement.create).toHaveBeenCalledTimes(1);
  });

  it('rejects a reused key with different payload or actor', async () => {
    const { service } = fixture();
    await service.record(input);
    await expect(service.record({ ...input, quantity: 6 })).rejects.toThrow('different request');
    await expect(service.record({ ...input, createdBy: 'p2' })).rejects.toThrow('different request');
  });

  it('records exact counts, frozen valuation and one low-stock alert', async () => {
    const { service, notifications, tx } = fixture();
    await service.record({ ...input, movementType: 'count', quantity: 3 });
    await service.record({ ...input, movementType: 'count', quantity: 3 });
    expect(tx.barInventoryMovement.create).toHaveBeenCalledWith({ data: expect.objectContaining({ previousOnHand: 10, nextOnHand: 3, unitCostCents: 2500 }) });
    expect(notifications.notifyManagers).toHaveBeenCalledTimes(1);
  });
});

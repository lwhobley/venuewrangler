import { beforeEach, describe, expect, it, vi } from 'vitest';
import {
  calculateOptimisticOnHand,
  clearOfflineQueue,
  enqueueOfflineMovement,
  getOfflineQueue,
  removeOfflineMovement,
  syncOfflineInventoryQueue,
  type QueuedMovement,
} from '../../lib/offline-inventory-queue';

describe('offline-inventory-queue (walk-in cooler resilience)', () => {
  beforeEach(async () => {
    await clearOfflineQueue();
  });

  it('enqueues a bottle count when in walk-in cooler with zero reception', async () => {
    const item = await enqueueOfflineMovement({
      venueId: 'v1',
      itemId: 'vodka-1',
      itemName: 'Well Vodka',
      movementType: 'count',
      quantity: 14,
    });

    expect(item).toBeDefined();
    expect(item.venueId).toBe('v1');
    expect(item.itemId).toBe('vodka-1');
    expect(item.itemName).toBe('Well Vodka');
    expect(item.movementType).toBe('count');
    expect(item.quantity).toBe(14);
    expect(item.retryCount).toBe(0);

    const queue = await getOfflineQueue('v1');
    expect(queue).toHaveLength(1);
    expect(queue[0].id).toBe(item.id);
  });

  it('calculates optimistic on-hand count across multiple queued movements', () => {
    const queue: QueuedMovement[] = [
      {
        id: '1',
        venueId: 'v1',
        itemId: 'tequila-1',
        movementType: 'received',
        quantity: 5,
        createdAt: new Date().toISOString(),
        retryCount: 0,
      },
      {
        id: '2',
        venueId: 'v1',
        itemId: 'tequila-1',
        movementType: 'waste',
        quantity: -2,
        createdAt: new Date().toISOString(),
        retryCount: 0,
      },
    ];

    // Base on hand is 10. Received +5, Waste -2 => 13
    const optimistic = calculateOptimisticOnHand('tequila-1', 10, queue);
    expect(optimistic).toBe(13);
  });

  it('replaces on-hand with exact count when a count movement is queued', () => {
    const queue: QueuedMovement[] = [
      {
        id: '1',
        venueId: 'v1',
        itemId: 'gin-1',
        movementType: 'count',
        quantity: 8,
        createdAt: new Date().toISOString(),
        retryCount: 0,
      },
    ];

    // Base was 3, but inventory taker counted 8 in the cooler
    const optimistic = calculateOptimisticOnHand('gin-1', 3, queue);
    expect(optimistic).toBe(8);
  });

  it('removes a specific queued movement by ID', async () => {
    const item1 = await enqueueOfflineMovement({
      venueId: 'v1',
      itemId: 'rum-1',
      movementType: 'count',
      quantity: 5,
    });
    const item2 = await enqueueOfflineMovement({
      venueId: 'v1',
      itemId: 'rum-2',
      movementType: 'count',
      quantity: 10,
    });

    let queue = await getOfflineQueue('v1');
    expect(queue).toHaveLength(2);

    await removeOfflineMovement(item1.id);
    queue = await getOfflineQueue('v1');
    expect(queue).toHaveLength(1);
    expect(queue[0].id).toBe(item2.id);
  });

  it('synchronizes queued movements sequentially upon reconnecting', async () => {
    await enqueueOfflineMovement({
      venueId: 'v1',
      itemId: 'whiskey-1',
      movementType: 'count',
      quantity: 12,
    });
    await enqueueOfflineMovement({
      venueId: 'v1',
      itemId: 'whiskey-2',
      movementType: 'received',
      quantity: 6,
    });

    const mockRecord = vi.fn().mockResolvedValue({ ok: true });

    const result = await syncOfflineInventoryQueue({
      venueId: 'v1',
      recordMovement: mockRecord,
    });

    expect(result.synced).toBe(2);
    expect(result.failed).toBe(0);
    expect(mockRecord).toHaveBeenCalledTimes(2);

    const remaining = await getOfflineQueue('v1');
    expect(remaining).toHaveLength(0);
  });

  it('preserves failed items in queue with incremented retryCount on partial sync failure', async () => {
    await enqueueOfflineMovement({
      venueId: 'v1',
      itemId: 'beer-1',
      itemName: 'IPA Keg',
      movementType: 'count',
      quantity: 2,
    });
    await enqueueOfflineMovement({
      venueId: 'v1',
      itemId: 'beer-2',
      itemName: 'Stout Keg',
      movementType: 'count',
      quantity: 4,
    });

    const mockRecord = vi.fn().mockImplementation((args: { itemId: string }) => {
      if (args.itemId === 'beer-2') {
        return Promise.reject(new Error('503 Service Unavailable'));
      }
      return Promise.resolve({ ok: true });
    });

    const result = await syncOfflineInventoryQueue({
      venueId: 'v1',
      recordMovement: mockRecord,
    });

    expect(result.synced).toBe(1);
    expect(result.failed).toBe(1);
    expect(result.errors).toContain('Stout Keg: 503 Service Unavailable');

    const remaining = await getOfflineQueue('v1');
    expect(remaining).toHaveLength(1);
    expect(remaining[0].itemId).toBe('beer-2');
    expect(remaining[0].retryCount).toBe(1);
    expect(remaining[0].lastError).toBe('503 Service Unavailable');
  });
});

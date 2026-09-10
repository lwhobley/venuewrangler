import { beforeEach, describe, expect, it, vi } from 'vitest';
const storage = new Map<string, string>();
vi.stubGlobal('localStorage', {
  getItem: (key: string) => storage.get(key) ?? null,
  setItem: (key: string, value: string) => { storage.set(key, value); },
});
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

  it('preserves entries enqueued while a sync request is pending', async () => {
    await enqueueOfflineMovement({ venueId: 'v1', itemId: 'first', movementType: 'count', quantity: 1 });
    let release!: () => void;
    let started!: () => void;
    const ready = new Promise<void>((resolve) => { started = resolve; });
    const recordMovement = vi.fn(() => { started(); return new Promise<void>((resolve) => { release = resolve; }); });
    const syncing = syncOfflineInventoryQueue({ venueId: 'v1', recordMovement });
    await ready;
    const second = await enqueueOfflineMovement({ venueId: 'v1', itemId: 'second', movementType: 'count', quantity: 2 });
    release();
    await syncing;
    expect((await getOfflineQueue()).map((item) => item.id)).toEqual([second.id]);
  });

  it('serializes concurrent enqueues', async () => {
    await Promise.all(['first', 'second'].map((itemId) => enqueueOfflineMovement({ venueId: 'v1', itemId, movementType: 'count', quantity: 1 })));
    expect(await getOfflineQueue()).toHaveLength(2);
  });

  it('does not automatically retry permanent failures, but allows explicit retry', async () => {
    await enqueueOfflineMovement({ venueId: 'v1', itemId: 'i1', movementType: 'count', quantity: 1 });
    const recordMovement = vi.fn().mockRejectedValueOnce(Object.assign(new Error('Forbidden'), { status: 403 })).mockResolvedValue({});
    await syncOfflineInventoryQueue({ venueId: 'v1', recordMovement });
    await syncOfflineInventoryQueue({ venueId: 'v1', recordMovement, automatic: true });
    expect(recordMovement).toHaveBeenCalledTimes(1);
    await syncOfflineInventoryQueue({ venueId: 'v1', recordMovement });
    expect(recordMovement).toHaveBeenCalledTimes(2);
  });

  it('coalesces overlapping sync requests in one runtime', async () => {
    await enqueueOfflineMovement({ venueId: 'v1', itemId: 'i1', movementType: 'count', quantity: 1 });
    const recordMovement = vi.fn().mockResolvedValue({});
    await Promise.all([syncOfflineInventoryQueue({ venueId: 'v1', recordMovement }), syncOfflineInventoryQueue({ venueId: 'v1', recordMovement })]);
    expect(recordMovement).toHaveBeenCalledTimes(1);
  });

  it('reuses the operation ID after a lost response and holds later counts for that item', async () => {
    const first = await enqueueOfflineMovement({ venueId: 'v1', itemId: 'same', movementType: 'received', quantity: 5 });
    await enqueueOfflineMovement({ venueId: 'v1', itemId: 'same', movementType: 'count', quantity: 8 });
    const recordMovement = vi.fn().mockRejectedValueOnce(new Error('Response lost')).mockResolvedValue({});
    await syncOfflineInventoryQueue({ venueId: 'v1', recordMovement });
    expect(recordMovement).toHaveBeenCalledTimes(1);
    await syncOfflineInventoryQueue({ venueId: 'v1', recordMovement });
    expect(recordMovement.mock.calls[0][0].operationId).toBe(first.id);
    expect(recordMovement.mock.calls[1][0].operationId).toBe(first.id);
    expect(await getOfflineQueue()).toHaveLength(0);
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

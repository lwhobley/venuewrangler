import { useCallback, useEffect, useState } from 'react';
import { Platform } from 'react-native';
import * as FileSystem from 'expo-file-system/legacy';

export type MovementType = 'count' | 'received' | 'waste' | 'transfer';

export type QueuedMovement = {
  id: string;
  venueId: string;
  itemId: string;
  itemName?: string;
  movementType: MovementType;
  quantity: number;
  notes?: string;
  createdAt: string;
  retryCount: number;
  lastError?: string;
};

const QUEUE_STORAGE_KEY = 'venuewrangler.bar_inventory.offline_queue';
const QUEUE_FILENAME = 'bar_inventory_offline_queue.json';

type QueueListener = (queue: QueuedMovement[]) => void;
const listeners = new Set<QueueListener>();

// In-memory cache for fast synchronous access
let memoryQueue: QueuedMovement[] | null = null;
let isLoaded = false;

function getNativeFileUri(): string | null {
  const dir = FileSystem.documentDirectory;
  if (!dir) return null;
  return `${dir}${QUEUE_FILENAME}`;
}

async function readRawQueue(): Promise<QueuedMovement[]> {
  try {
    if (Platform.OS === 'web' || typeof window !== 'undefined') {
      if (typeof localStorage !== 'undefined') {
        const raw = localStorage.getItem(QUEUE_STORAGE_KEY);
        if (!raw) return [];
        const parsed = JSON.parse(raw);
        return Array.isArray(parsed) ? parsed : [];
      }
      return [];
    }

    const uri = getNativeFileUri();
    if (!uri) return [];
    const info = await FileSystem.getInfoAsync(uri).catch(() => ({ exists: false }));
    if (!info.exists) return [];
    const content = await FileSystem.readAsStringAsync(uri);
    if (!content) return [];
    const parsed = JSON.parse(content);
    return Array.isArray(parsed) ? parsed : [];
  } catch (err) {
    console.warn('[OfflineInventoryQueue] Error reading stored queue:', err);
    return [];
  }
}

async function writeRawQueue(queue: QueuedMovement[]): Promise<void> {
  memoryQueue = queue;
  try {
    const serialized = JSON.stringify(queue);
    if (Platform.OS === 'web' || typeof window !== 'undefined') {
      if (typeof localStorage !== 'undefined') {
        localStorage.setItem(QUEUE_STORAGE_KEY, serialized);
      }
      return;
    }

    const uri = getNativeFileUri();
    if (uri) {
      await FileSystem.writeAsStringAsync(uri, serialized);
    }
  } catch (err) {
    console.warn('[OfflineInventoryQueue] Error writing stored queue:', err);
  }
}

function notifyListeners() {
  const current = memoryQueue ?? [];
  for (const listener of listeners) {
    try {
      listener(current);
    } catch {
      // Ignore listener errors
    }
  }
}

export async function getOfflineQueue(venueId?: string): Promise<QueuedMovement[]> {
  if (!isLoaded || memoryQueue === null) {
    memoryQueue = await readRawQueue();
    isLoaded = true;
  }
  if (!venueId) return [...memoryQueue];
  return memoryQueue.filter((m) => m.venueId === venueId);
}

export async function enqueueOfflineMovement(params: {
  venueId: string;
  itemId: string;
  itemName?: string;
  movementType: MovementType;
  quantity: number;
  notes?: string;
}): Promise<QueuedMovement> {
  const current = await getOfflineQueue();
  const newEntry: QueuedMovement = {
    id: `queue_${Date.now()}_${Math.random().toString(36).slice(2, 8)}`,
    venueId: params.venueId,
    itemId: params.itemId,
    itemName: params.itemName,
    movementType: params.movementType,
    quantity: params.quantity,
    notes: params.notes,
    createdAt: new Date().toISOString(),
    retryCount: 0,
  };

  const nextQueue = [...current, newEntry];
  await writeRawQueue(nextQueue);
  notifyListeners();
  return newEntry;
}

export async function removeOfflineMovement(id: string): Promise<void> {
  const current = await getOfflineQueue();
  const nextQueue = current.filter((m) => m.id !== id);
  await writeRawQueue(nextQueue);
  notifyListeners();
}

export async function clearOfflineQueue(venueId?: string): Promise<void> {
  if (!venueId) {
    await writeRawQueue([]);
  } else {
    const current = await getOfflineQueue();
    const nextQueue = current.filter((m) => m.venueId !== venueId);
    await writeRawQueue(nextQueue);
  }
  notifyListeners();
}

/**
 * Calculates optimistic on-hand amount for an item by replaying any pending offline movements.
 */
export function calculateOptimisticOnHand(
  itemId: string,
  baseOnHand: number,
  queue: QueuedMovement[],
): number {
  let onHand = baseOnHand;
  const itemMovements = queue.filter((m) => m.itemId === itemId);

  for (const movement of itemMovements) {
    if (movement.movementType === 'count') {
      onHand = Math.max(0, movement.quantity);
    } else {
      onHand = Math.max(0, onHand + movement.quantity);
    }
  }

  return onHand;
}

export type SyncResult = {
  synced: number;
  failed: number;
  errors: string[];
};

export async function syncOfflineInventoryQueue(options: {
  venueId: string;
  recordMovement: (args: {
    venueId: string;
    itemId: string;
    movementType: string;
    quantity: number;
    notes?: string;
  }) => Promise<any>;
}): Promise<SyncResult> {
  const allQueued = await getOfflineQueue();
  const venueMovements = allQueued.filter((m) => m.venueId === options.venueId);

  if (venueMovements.length === 0) {
    return { synced: 0, failed: 0, errors: [] };
  }

  let synced = 0;
  let failed = 0;
  const errors: string[] = [];
  const remainingIds = new Set(allQueued.map((m) => m.id));

  for (const item of venueMovements) {
    try {
      await options.recordMovement({
        venueId: item.venueId,
        itemId: item.itemId,
        movementType: item.movementType,
        quantity: item.quantity,
        notes: item.notes,
      });
      synced++;
      remainingIds.delete(item.id);
    } catch (err: any) {
      failed++;
      const message = err?.message || 'Sync failed';
      errors.push(`${item.itemName ?? item.itemId}: ${message}`);
      // Keep in queue, increment retry
      const target = allQueued.find((m) => m.id === item.id);
      if (target) {
        target.retryCount = (target.retryCount || 0) + 1;
        target.lastError = message;
      }
    }
  }

  const updatedQueue = allQueued.filter((m) => remainingIds.has(m.id));
  await writeRawQueue(updatedQueue);
  notifyListeners();

  return { synced, failed, errors };
}

/**
 * React hook for consuming and synchronizing offline movements in UI components.
 */
export function useOfflineInventoryQueue(venueId?: string) {
  const [queue, setQueue] = useState<QueuedMovement[]>(() => {
    if (memoryQueue !== null) {
      return venueId ? memoryQueue.filter((m) => m.venueId === venueId) : memoryQueue;
    }
    return [];
  });
  const [isSyncing, setIsSyncing] = useState(false);
  const [syncStatus, setSyncStatus] = useState<string | null>(null);

  useEffect(() => {
    let mounted = true;

    const updateState = (fullQueue: QueuedMovement[]) => {
      if (!mounted) return;
      setQueue(venueId ? fullQueue.filter((m) => m.venueId === venueId) : fullQueue);
    };

    listeners.add(updateState);

    void getOfflineQueue(venueId).then((items) => {
      if (mounted) setQueue(items);
    });

    return () => {
      mounted = false;
      listeners.delete(updateState);
    };
  }, [venueId]);

  const enqueue = useCallback(
    async (params: {
      itemId: string;
      itemName?: string;
      movementType: MovementType;
      quantity: number;
      notes?: string;
    }) => {
      if (!venueId) return null;
      return await enqueueOfflineMovement({
        venueId,
        ...params,
      });
    },
    [venueId],
  );

  const syncNow = useCallback(
    async (recordMovement: (args: any) => Promise<any>): Promise<SyncResult> => {
      if (!venueId || isSyncing) {
        return { synced: 0, failed: 0, errors: [] };
      }
      setIsSyncing(true);
      setSyncStatus(null);
      try {
        const result = await syncOfflineInventoryQueue({
          venueId,
          recordMovement,
        });
        if (result.synced > 0) {
          setSyncStatus(`Synced ${result.synced} item${result.synced > 1 ? 's' : ''}`);
        } else if (result.failed > 0) {
          setSyncStatus(`Failed to sync ${result.failed} item${result.failed > 1 ? 's' : ''}`);
        }
        return result;
      } finally {
        setIsSyncing(false);
      }
    },
    [venueId, isSyncing],
  );

  const getOptimisticOnHand = useCallback(
    (itemId: string, baseOnHand: number) => {
      return calculateOptimisticOnHand(itemId, baseOnHand, queue);
    },
    [queue],
  );

  return {
    queue,
    pendingCount: queue.length,
    isSyncing,
    syncStatus,
    enqueue,
    syncNow,
    getOptimisticOnHand,
    clearAll: useCallback(() => clearOfflineQueue(venueId), [venueId]),
  };
}

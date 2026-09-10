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
  retryable?: boolean;
};

const QUEUE_STORAGE_KEY = 'venuewrangler.bar_inventory.offline_queue';
const QUEUE_FILENAME = 'bar_inventory_offline_queue.json';

type QueueListener = (queue: QueuedMovement[]) => void;
const listeners = new Set<QueueListener>();

// In-memory cache for fast synchronous access
let memoryQueue: QueuedMovement[] | null = null;
let isLoaded = false;
let mutationTail: Promise<unknown> = Promise.resolve();
const activeSyncs = new Map<string, Promise<SyncResult>>();

function mutateQueue(update: (queue: QueuedMovement[]) => QueuedMovement[]): Promise<void> {
  const run = async () => {
    // Re-read inside the lock so another browser tab cannot be overwritten.
    const current = await readRawQueue();
    await writeRawQueue(update(current));
    notifyListeners();
  };
  const next = mutationTail.then(() =>
    Platform.OS === 'web' && typeof navigator !== 'undefined' && navigator.locks
      ? navigator.locks.request(QUEUE_STORAGE_KEY, run)
      : run(),
  );
  mutationTail = next.catch(() => undefined);
  return next;
}

function getNativeFileUri(): string | null {
  const dir = FileSystem.documentDirectory;
  if (!dir) return null;
  return `${dir}${QUEUE_FILENAME}`;
}

async function readRawQueue(): Promise<QueuedMovement[]> {
  try {
    if (Platform.OS === 'web') {
      if (typeof localStorage !== 'undefined') {
        const raw = localStorage.getItem(QUEUE_STORAGE_KEY);
        if (!raw) return [];
        const parsed = JSON.parse(raw);
        return Array.isArray(parsed) ? parsed : [];
      }
      throw new Error('Offline storage is unavailable');
    }

    const uri = getNativeFileUri();
    if (!uri) throw new Error('Offline storage is unavailable');
    const info = await FileSystem.getInfoAsync(uri);
    if (!info.exists) return [];
    const content = await FileSystem.readAsStringAsync(uri);
    if (!content) return [];
    const parsed = JSON.parse(content);
    return Array.isArray(parsed) ? parsed : [];
  } catch (err) {
    throw new Error('Unable to read saved inventory. Do not clear app storage.', { cause: err });
  }
}

async function writeRawQueue(queue: QueuedMovement[]): Promise<void> {
    const serialized = JSON.stringify(queue);
    if (Platform.OS === 'web') {
      if (typeof localStorage === 'undefined') throw new Error('Offline storage is unavailable');
      localStorage.setItem(QUEUE_STORAGE_KEY, serialized);
    } else {
      const uri = getNativeFileUri();
      if (!uri) throw new Error('Offline storage is unavailable');
      await FileSystem.writeAsStringAsync(uri, serialized);
    }
    memoryQueue = queue;
    isLoaded = true;
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

  await mutateQueue((current) => [...current, newEntry]);
  return newEntry;
}

export async function removeOfflineMovement(id: string): Promise<void> {
  await mutateQueue((current) => current.filter((m) => m.id !== id));
}

export async function clearOfflineQueue(venueId?: string): Promise<void> {
  await mutateQueue((current) => venueId ? current.filter((m) => m.venueId !== venueId) : []);
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

type SyncOptions = {
  venueId: string;
  automatic?: boolean;
  recordMovement: (args: {
    venueId: string;
    itemId: string;
    movementType: string;
    quantity: number;
    notes?: string;
    operationId: string;
  }) => Promise<any>;
};

export function syncOfflineInventoryQueue(options: SyncOptions): Promise<SyncResult> {
  const active = activeSyncs.get(options.venueId);
  if (active) return active;
  const syncing = runSync(options).finally(() => { activeSyncs.delete(options.venueId); });
  activeSyncs.set(options.venueId, syncing);
  return syncing;
}

async function runSync(options: SyncOptions): Promise<SyncResult> {
  await mutationTail;
  const allQueued = await readRawQueue();
  const venueMovements = allQueued.filter((m) => m.venueId === options.venueId);

  if (venueMovements.length === 0) {
    return { synced: 0, failed: 0, errors: [] };
  }

  let synced = 0;
  let failed = 0;
  const errors: string[] = [];
  const blockedItems = new Set<string>();

  for (const item of venueMovements) {
    if (blockedItems.has(item.itemId)) continue;
    if (options.automatic && (item.retryable === false || item.retryCount >= 3)) {
      blockedItems.add(item.itemId);
      continue;
    }
    try {
      await options.recordMovement({
        venueId: item.venueId,
        itemId: item.itemId,
        movementType: item.movementType,
        quantity: item.quantity,
        notes: item.notes,
        operationId: item.id,
      });
      await removeOfflineMovement(item.id);
      synced++;
    } catch (err: any) {
      failed++;
      const message = err?.message || 'Sync failed';
      const status = Number(err?.status);
      const retryable = !status || status >= 500 || status === 408 || status === 429;
      errors.push(`${item.itemName ?? item.itemId}: ${message}`);
      blockedItems.add(item.itemId);
      await mutateQueue((current) => current.map((entry) => entry.id === item.id
        ? { ...entry, retryCount: entry.retryCount + 1, lastError: message, retryable } : entry));
    }
  }

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
    }).catch(() => {
      if (mounted) setSyncStatus('Unable to read saved inventory. Do not clear app storage.');
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
    async (recordMovement: (args: any) => Promise<any>, automatic = false): Promise<SyncResult> => {
      if (!venueId || isSyncing) {
        return { synced: 0, failed: 0, errors: [] };
      }
      setIsSyncing(true);
      setSyncStatus(null);
      try {
        const result = await syncOfflineInventoryQueue({
          venueId,
          automatic,
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

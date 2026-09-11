import { beforeEach, describe, expect, it, vi } from 'vitest';

const disk = vi.hoisted(() => ({ content: '', fail: false, writes: 0 }));
vi.mock('react-native', () => ({ Platform: { OS: 'ios' } }));
vi.mock('expo-file-system/legacy', () => ({
  documentDirectory: '/documents/',
  getInfoAsync: async () => ({ exists: !!disk.content }),
  readAsStringAsync: async () => disk.content,
  writeAsStringAsync: async (_uri: string, value: string) => {
    if (disk.fail) throw new Error('Disk full');
    disk.content = value;
    disk.writes++;
  },
}));

describe('native inventory persistence', () => {
  beforeEach(() => {
    vi.stubGlobal('window', globalThis);
    vi.resetModules();
    disk.content = ''; disk.fail = false; disk.writes = 0;
  });

  it('persists with native window globals and restores after a module restart', async () => {
    expect(typeof window).toBe('object');
    const queue = await import('../../lib/offline-inventory-queue');
    const item = await queue.enqueueOfflineMovement({ ownerId: 'owner-1', venueId: 'v1', itemId: 'i1', movementType: 'count', quantity: 4 });
    expect(disk.writes).toBe(1);
    vi.resetModules();
    const restarted = await import('../../lib/offline-inventory-queue');
    expect((await restarted.getOfflineQueue())[0].id).toBe(item.id);
  });

  it('rejects a failed durable write instead of reporting an in-memory success', async () => {
    const queue = await import('../../lib/offline-inventory-queue');
    await queue.getOfflineQueue();
    disk.fail = true;
    await expect(queue.enqueueOfflineMovement({ ownerId: 'owner-1', venueId: 'v1', itemId: 'i1', movementType: 'count', quantity: 4 })).rejects.toThrow('Disk full');
    expect(await queue.getOfflineQueue()).toEqual([]);
  });

  it('does not overwrite unreadable saved inventory', async () => {
    disk.content = '{invalid';
    const queue = await import('../../lib/offline-inventory-queue');
    await expect(queue.enqueueOfflineMovement({ ownerId: 'owner-1', venueId: 'v1', itemId: 'i1', movementType: 'count', quantity: 4 })).rejects.toThrow('Unable to read');
    expect(disk.content).toBe('{invalid');
  });
});

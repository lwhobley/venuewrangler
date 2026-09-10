import React, { act } from 'react';
import { createRoot } from 'test-renderer';
import { beforeEach, describe, expect, it, vi } from 'vitest';

function item(overrides: Record<string, unknown> = {}) {
  return {
    _id: 'i1', name: 'Well Vodka', category: 'spirit', area: 'Well', unit: 'bottle',
    parLevel: 6, onHand: 4, unitCostCents: 1500, supplier: null, notes: null,
    ...overrides,
  };
}

const state = vi.hoisted(() => ({
  savedQueue: '',
  venue: { id: 'venue-1' } as any,
  canManage: true,
  profileLoading: false,
  stock: undefined as any,
  upsertBarItem: vi.fn(),
  recordMovement: vi.fn(),
}));

vi.mock('expo-file-system/legacy', () => ({
  documentDirectory: '/mock/documents/',
  getInfoAsync: async () => ({ exists: !!state.savedQueue }),
  readAsStringAsync: async () => state.savedQueue,
  writeAsStringAsync: async (_uri: string, value: string) => { state.savedQueue = value; },
}));

vi.mock('react-native', () => ({
  Modal: 'Modal', Platform: { OS: 'ios' }, ScrollView: 'ScrollView', StyleSheet: { create: (s: unknown) => s }, TouchableOpacity: 'TouchableOpacity', View: 'View',
}));
vi.mock('expo-router', () => ({ useFocusEffect: () => undefined }));
vi.mock('react-native-paper', async () => {
  const R = await import('react');
  const element = (type: string) => ({ children, ...props }: any) => R.createElement(type, props, children);
  const Card = Object.assign(element('Card'), { Content: element('Card.Content') });
  return { Button: element('Button'), Card, Chip: element('Chip'), Text: element('Text'), TextInput: element('TextInput') };
});
vi.mock('expo-camera', () => ({ CameraView: 'CameraView', useCameraPermissions: () => [{ granted: false }, vi.fn()] }));
vi.mock('@expo/vector-icons', () => ({ MaterialCommunityIcons: 'MaterialCommunityIcons' }));
vi.mock('expo-document-picker', () => ({ getDocumentAsync: vi.fn() }));
vi.mock('expo-image-picker', () => ({ requestMediaLibraryPermissionsAsync: vi.fn(), launchImageLibraryAsync: vi.fn(), MediaTypeOptions: { Images: 'Images' } }));
vi.mock('../../components/ErrorBoundary', () => ({ ScreenErrorBoundary: ({ children }: any) => children }));
vi.mock('../../components/ManagerGate', () => ({
  ManagerGate: ({ children, canManage }: any) => (canManage === false ? 'ManagerGateBlocked' : children),
}));
vi.mock('../../components/InlineMessage', () => ({ InlineMessage: ({ message }: any) => message }));
vi.mock('../../components/AppCard', () => ({ SectionHeader: ({ title }: any) => title }));
vi.mock('../../components/bar-stock/InventoryCards', () => ({
  VelocityCard: () => null, ShrinkageCard: () => null, PurchaseOrderCard: () => null, AgingCard: () => null, MovementTimeline: () => null,
}));
vi.mock('../../lib/picked-file', () => ({ readPickedFileText: vi.fn() }));
vi.mock('../../lib/useVenueAuth', () => ({
  useVenueAuth: () => ({ venue: state.venue, isReady: true, canManage: state.canManage, profileLoading: state.profileLoading, profileError: null, refetchProfile: vi.fn() }),
}));
vi.mock('../../lib/railway-api', () => ({
  api: {
    barInventory: {
      getBarStock: 'getBarStock', getUsageVelocity: 'getUsageVelocity', listPrepBoard: 'listPrepBoard',
      upsertBarItem: 'upsertBarItem', recordBarStockMovement: 'recordBarStockMovement', importParsedBarItems: 'importParsedBarItems',
      parseBarInventoryInput: 'parseBarInventoryInput', updateItemCost: 'updateItemCost', lookupBySku: 'lookupBySku',
      sendPurchaseOrderEmail: 'sendPurchaseOrderEmail', sendInventoryDigest: 'sendInventoryDigest',
      upsertPrepBoardItem: 'upsertPrepBoardItem', updatePrepBoardItemStatus: 'updatePrepBoardItemStatus',
      exportStockCsv: 'exportStockCsv', exportMovementsCsv: 'exportMovementsCsv', getShrinkageReport: 'getShrinkageReport',
      getPurchaseOrder: 'getPurchaseOrder', exportPurchaseOrderCsv: 'exportPurchaseOrderCsv', getCostHistory: 'getCostHistory',
      getAgingReport: 'getAgingReport',
    },
  },
}));
vi.mock('../../lib/railway-hooks', () => ({
  useQuery: (ref: string) => (ref === 'getBarStock' ? state.stock : undefined),
  useMutation: (ref: string) => (ref === 'upsertBarItem' ? state.upsertBarItem : ref === 'recordBarStockMovement' ? state.recordMovement : vi.fn()),
  useAction: () => vi.fn(),
}));
vi.mock('../../lib/theme', () => ({
  accents: Array.from({ length: 6 }, (_, i) => ({ bg: `#bg${i}`, fg: `#fg${i}`, icon: `#ic${i}` })),
  colors: { background: '#000', border: '#333', charcoal: '#222', danger: '#f00', muted: '#777', primary: '#0f0', surface: '#111' },
  radius: { sharp: 4 },
  spacing: { lg: 24, md: 16, sm: 8 },
}));
vi.mock('../../lib/i18n', () => ({
  useI18n: () => ({
    t: (key: string, vars?: Record<string, unknown>) =>
      vars ? `${key}(${Object.entries(vars).map(([k, v]) => `${k}=${String(v)}`).join('|')})` : key,
  }),
}));

import BarStockScreenWrapper from '../../app/(tabs)/bar-stock';
import { clearOfflineQueue } from '../../lib/offline-inventory-queue';

function render() {
  return createRoot();
}
function output(r: ReturnType<typeof createRoot>) {
  return JSON.stringify(r.container.toJSON());
}
function buttonByLabel(r: ReturnType<typeof createRoot>, label: string) {
  return r.container.queryAll((n) => n.type === 'Button').find((n) => JSON.stringify(n.toJSON()).includes(label));
}
function inputByLabel(r: ReturnType<typeof createRoot>, label: string) {
  return r.container.queryAll((n) => n.type === 'TextInput').find((n) => n.props.label === label);
}

describe('Bar stock screen', () => {
  beforeEach(async () => {
    vi.clearAllMocks();
    state.venue = { id: 'venue-1' };
    state.canManage = true;
    state.profileLoading = false;
    state.stock = { items: [], lowStockCount: 0, totalValueCents: 0 };
    await clearOfflineQueue();
  });

  it('gives non-managers a read-only stock view with no edit or movement actions', async () => {
    state.canManage = false;
    state.stock = { items: [item()], lowStockCount: 1, totalValueCents: 6000 };
    const r = render();
    await act(async () => r.render(<BarStockScreenWrapper />));
    const out = output(r);
    expect(out).toContain('barStock.metrics.items');
    expect(out).not.toContain('barStock.form.saveItem');
    expect(out).not.toContain('barStock.list.plusOne');
  });

  it('saves a new item with parsed numeric fields and cents-converted cost', async () => {
    state.upsertBarItem.mockResolvedValueOnce({});
    const r = render();
    await act(async () => r.render(<BarStockScreenWrapper />));
    await act(async () => inputByLabel(r, 'barStock.form.nameLabel')?.props.onChangeText('Well Vodka'));
    await act(async () => inputByLabel(r, 'barStock.form.parLabel')?.props.onChangeText('6'));
    await act(async () => inputByLabel(r, 'barStock.form.onHandLabel')?.props.onChangeText('4'));
    await act(async () => inputByLabel(r, 'barStock.form.unitCostLabel')?.props.onChangeText('15.00'));
    await act(async () => buttonByLabel(r, 'barStock.form.saveItem')?.props.onPress());

    expect(state.upsertBarItem).toHaveBeenCalledWith(expect.objectContaining({
      venueId: 'venue-1', name: 'Well Vodka', parLevel: 6, onHand: 4, unitCostCents: 1500,
    }));
  });

  it('surfaces a failed item save', async () => {
    state.upsertBarItem.mockRejectedValueOnce(new Error('Duplicate item name'));
    const r = render();
    await act(async () => r.render(<BarStockScreenWrapper />));
    await act(async () => inputByLabel(r, 'barStock.form.nameLabel')?.props.onChangeText('Well Vodka'));
    await act(async () => buttonByLabel(r, 'barStock.form.saveItem')?.props.onPress());
    expect(output(r)).toContain('Duplicate item name');
  });

  it('records a +1 received movement for an item', async () => {
    state.stock = { items: [item()], lowStockCount: 1, totalValueCents: 6000 };
    state.recordMovement.mockResolvedValueOnce({});
    const r = render();
    await act(async () => r.render(<BarStockScreenWrapper />));
    await act(async () => buttonByLabel(r, 'barStock.list.plusOne')?.props.onPress());
    expect(state.recordMovement).toHaveBeenCalledWith(expect.objectContaining({ venueId: 'venue-1', itemId: 'i1', movementType: 'received', quantity: 1, operationId: expect.any(String) }));
  });

  it('records a -1 waste movement for an item', async () => {
    state.stock = { items: [item()], lowStockCount: 1, totalValueCents: 6000 };
    state.recordMovement.mockResolvedValueOnce({});
    const r = render();
    await act(async () => r.render(<BarStockScreenWrapper />));
    await act(async () => buttonByLabel(r, 'barStock.list.minusOne')?.props.onPress());
    expect(state.recordMovement).toHaveBeenCalledWith(expect.objectContaining({ venueId: 'venue-1', itemId: 'i1', movementType: 'waste', quantity: -1, operationId: expect.any(String) }));
  });

  it('flags an item below par level in the reorder list', async () => {
    state.stock = { items: [item({ onHand: 2, parLevel: 6 })], lowStockCount: 1, totalValueCents: 3000 };
    const r = render();
    await act(async () => r.render(<BarStockScreenWrapper />));
    expect(output(r)).toContain('barStock.list.reorderListTitle');
  });

  it('separates beverage and food items by tab', async () => {
    state.stock = {
      items: [item({ _id: 'bev1', name: 'Well Vodka', category: 'spirit' }), item({ _id: 'food1', name: 'Chicken Breast', category: 'protein' })],
      lowStockCount: 0, totalValueCents: 0,
    };
    const r = render();
    await act(async () => r.render(<BarStockScreenWrapper />));
    expect(output(r)).toContain('Well Vodka');
    expect(output(r)).not.toContain('Chicken Breast');

    const foodTab = buttonByLabel(r, 'Food');
    await act(async () => foodTab?.props.onPress());
    const out = output(r);
    expect(out).toContain('Chicken Breast');
    expect(out).not.toContain('Well Vodka');
  });

  it('enqueues movement offline and displays pending sync banner when walk-in cooler drops connection', async () => {
    state.stock = { items: [item()], lowStockCount: 1, totalValueCents: 6000 };
    state.recordMovement.mockRejectedValueOnce(new Error('Network request failed'));
    const r = render();
    await act(async () => r.render(<BarStockScreenWrapper />));
    await act(async () => buttonByLabel(r, 'barStock.list.plusOne')?.props.onPress());

    const out = output(r);
    expect(out).toContain('barStock.messages.offlineMovementQueued');
    expect(out).toContain('barStock.messages.offlinePendingBanner(count=1)');
  });

  it('syncs queued walk-in cooler movements when sync now button is pressed', async () => {
    state.stock = { items: [item()], lowStockCount: 1, totalValueCents: 6000 };
    state.recordMovement
      .mockRejectedValueOnce(new Error('Network request failed'))
      .mockResolvedValueOnce({ ok: true });

    const r = render();
    await act(async () => r.render(<BarStockScreenWrapper />));
    await act(async () => buttonByLabel(r, 'barStock.list.plusOne')?.props.onPress());
    expect(output(r)).toContain('barStock.messages.offlinePendingBanner(count=1)');

    const syncBtn = buttonByLabel(r, 'barStock.messages.syncNow');
    expect(syncBtn).toBeDefined();
    await act(async () => syncBtn?.props.onPress());

    expect(output(r)).toContain('barStock.messages.offlineSyncSuccess(count=1)');
  });
});

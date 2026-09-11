import React, { act } from 'react';
import { createRoot } from 'test-renderer';
import { beforeEach, describe, expect, it, vi } from 'vitest';

function item(overrides: Record<string, unknown> = {}) {
  return {
    _id: 'i1', title: 'Wipe down bar', requiresPhoto: false, sortOrder: 1, completionId: 'c1',
    status: 'pending', completedByName: null, completedAt: null, hasPhoto: false, photoUrl: null,
    ...overrides,
  };
}

const state = vi.hoisted(() => ({
  venue: { id: 'venue-1' } as any,
  canManage: true,
  checklist: undefined as any,
  addItem: vi.fn(),
  removeItem: vi.fn(),
  completeItem: vi.fn(),
  requestCameraPermissionsAsync: vi.fn(),
  launchCameraAsync: vi.fn(),
  back: vi.fn(),
}));

vi.mock('react-native', () => ({ Image: 'Image', View: 'View' }));
vi.mock('../../components/FormScreen', () => ({ FormScreen: ({ children }: any) => children }));
vi.mock('expo-router', () => ({ router: { back: state.back } }));
vi.mock('expo-image-picker', () => ({
  requestCameraPermissionsAsync: state.requestCameraPermissionsAsync,
  launchCameraAsync: state.launchCameraAsync,
}));
vi.mock('react-native-paper', async () => {
  const R = await import('react');
  const element = (type: string) => ({ children, ...props }: any) => R.createElement(type, props, children);
  return { Button: element('Button'), Chip: element('Chip'), IconButton: element('IconButton'), Text: element('Text'), TextInput: element('TextInput') };
});
vi.mock('../../components/AppCard', () => ({ AppCard: ({ children }: any) => children, SectionHeader: ({ title }: any) => title }));
vi.mock('../../components/ErrorBoundary', () => ({ ScreenErrorBoundary: ({ children }: any) => children }));
vi.mock('../../lib/api-client', () => ({ resolveMediaUrl: (url: string) => url }));
vi.mock('../../lib/useVenueAuth', () => ({ useVenueAuth: () => ({ venue: state.venue, isReady: true, canManage: state.canManage }) }));
vi.mock('../../lib/railway-api', () => ({
  api: { operations: { getChecklist: 'getChecklist', addChecklistItem: 'addChecklistItem', removeChecklistItem: 'removeChecklistItem', completeChecklistItem: 'completeChecklistItem' } },
}));
vi.mock('../../lib/railway-hooks', () => ({
  useQuery: (ref: string) => (ref === 'getChecklist' ? state.checklist : undefined),
  useMutation: (ref: string) => {
    if (ref === 'addChecklistItem') return state.addItem;
    if (ref === 'removeChecklistItem') return state.removeItem;
    if (ref === 'completeChecklistItem') return state.completeItem;
    return vi.fn();
  },
}));
vi.mock('../../lib/theme', () => ({
  colors: { background: '#000', charcoal: '#222', danger: '#f00', muted: '#777', primary: '#0f0', secondary: '#0af', surface: '#111' },
  radius: { sharp: 4 }, spacing: { lg: 24, md: 16, xxl: 48 }, type: { title: {} },
}));
vi.mock('../../lib/i18n', () => ({
  useI18n: () => ({
    t: (key: string, vars?: Record<string, unknown>) =>
      vars ? `${key}(${Object.entries(vars).map(([k, v]) => `${k}=${String(v)}`).join('|')})` : key,
  }),
}));

import ChecklistScreenWrapper from '../../app/checklist';

function render() {
  return createRoot();
}
function output(r: ReturnType<typeof createRoot>) {
  return JSON.stringify(r.container.toJSON());
}
function buttonByLabel(r: ReturnType<typeof createRoot>, label: string) {
  return r.container.queryAll((n) => n.type === 'Button').find((n) => JSON.stringify(n.toJSON()).includes(label));
}

describe('Checklist screen', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    state.venue = { id: 'venue-1' };
    state.canManage = true;
    state.checklist = { date: '2026-09-08', kind: 'opening', items: [] };
  });

  it('does not add a blank task', async () => {
    const r = render();
    await act(async () => r.render(<ChecklistScreenWrapper />));
    expect(buttonByLabel(r, 'checklist.addTask')?.props.disabled).toBe(true);
  });

  it('adds a task for the active checklist kind and clears the composer', async () => {
    state.addItem.mockResolvedValueOnce({});
    const r = render();
    await act(async () => r.render(<ChecklistScreenWrapper />));
    const input = r.container.queryAll((n) => n.type === 'TextInput')[0];
    await act(async () => input?.props.onChangeText('Restock napkins'));
    await act(async () => buttonByLabel(r, 'checklist.addTask')?.props.onPress());
    expect(state.addItem).toHaveBeenCalledWith({ kind: 'opening', title: 'Restock napkins', requiresPhoto: false });
    expect(input?.props.value).toBe('');
  });

  it('adds a task to the closing checklist after switching tabs', async () => {
    state.addItem.mockResolvedValueOnce({});
    const r = render();
    await act(async () => r.render(<ChecklistScreenWrapper />));
    const closingChip = r.container.queryAll((n) => n.type === 'Chip').find((n) => JSON.stringify(n.toJSON()).includes('checklist.closing'));
    await act(async () => closingChip?.props.onPress());
    const input = r.container.queryAll((n) => n.type === 'TextInput')[0];
    await act(async () => input?.props.onChangeText('Lock the safe'));
    await act(async () => buttonByLabel(r, 'checklist.addTask')?.props.onPress());
    expect(state.addItem).toHaveBeenCalledWith({ kind: 'closing', title: 'Lock the safe', requiresPhoto: false });
  });

  it('marks a plain task done using its completion id', async () => {
    state.checklist = { date: '2026-09-08', kind: 'opening', items: [item()] };
    state.completeItem.mockResolvedValueOnce({});
    const r = render();
    await act(async () => r.render(<ChecklistScreenWrapper />));
    await act(async () => buttonByLabel(r, 'checklist.markDone')?.props.onPress());
    expect(state.completeItem).toHaveBeenCalledWith({ completionId: 'c1' });
  });

  it('requires camera permission before completing a photo task, and stops if denied', async () => {
    state.checklist = { date: '2026-09-08', kind: 'opening', items: [item({ requiresPhoto: true })] };
    state.requestCameraPermissionsAsync.mockResolvedValueOnce({ status: 'denied' });
    const r = render();
    await act(async () => r.render(<ChecklistScreenWrapper />));
    await act(async () => buttonByLabel(r, 'checklist.takePhotoAndComplete')?.props.onPress());
    expect(output(r)).toContain('checklist.cameraPermissionRequired');
    expect(state.completeItem).not.toHaveBeenCalled();
  });

  it('completes a photo task with the captured base64 image', async () => {
    state.checklist = { date: '2026-09-08', kind: 'opening', items: [item({ requiresPhoto: true })] };
    state.requestCameraPermissionsAsync.mockResolvedValueOnce({ status: 'granted' });
    state.launchCameraAsync.mockResolvedValueOnce({ canceled: false, assets: [{ base64: 'imgdata', mimeType: 'image/jpeg' }] });
    state.completeItem.mockResolvedValueOnce({});
    const r = render();
    await act(async () => r.render(<ChecklistScreenWrapper />));
    await act(async () => buttonByLabel(r, 'checklist.takePhotoAndComplete')?.props.onPress());
    expect(state.completeItem).toHaveBeenCalledWith({ completionId: 'c1', photoBase64: 'imgdata', photoMimeType: 'image/jpeg' });
  });

  it('removes a task for managers only', async () => {
    state.checklist = { date: '2026-09-08', kind: 'opening', items: [item()] };
    state.removeItem.mockResolvedValueOnce({});
    const r = render();
    await act(async () => r.render(<ChecklistScreenWrapper />));
    const deleteIcon = r.container.queryAll((n) => n.type === 'IconButton').find((n) => n.props.icon === 'delete-outline');
    await act(async () => deleteIcon?.props.onPress());
    expect(state.removeItem).toHaveBeenCalledWith('i1');
  });

  it('hides task removal and the add-task composer from staff without manage permission', async () => {
    state.canManage = false;
    state.checklist = { date: '2026-09-08', kind: 'opening', items: [item()] };
    const r = render();
    await act(async () => r.render(<ChecklistScreenWrapper />));
    expect(output(r)).not.toContain('checklist.addTaskTitle');
    const deleteIcon = r.container.queryAll((n) => n.type === 'IconButton').find((n) => n.props.icon === 'delete-outline');
    expect(deleteIcon).toBeUndefined();
  });
});

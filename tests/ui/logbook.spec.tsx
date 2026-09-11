import React, { act } from 'react';
import { createRoot } from 'test-renderer';
import { beforeEach, describe, expect, it, vi } from 'vitest';

function entry(overrides: Record<string, unknown> = {}) {
  return {
    _id: 'e1', authorProfileId: 'p1', authorName: 'Casey Nguyen', category: 'handoff',
    body: 'Walk-in cooler is running warm, called for service.', pinned: false, createdAt: Date.UTC(2026, 8, 1, 20, 0),
    ...overrides,
  };
}

const state = vi.hoisted(() => ({
  venue: { id: 'venue-1' } as any,
  canManage: true,
  me: { profile: { _id: 'p1' } } as any,
  entries: undefined as any,
  addEntry: vi.fn(),
  deleteEntry: vi.fn(),
  back: vi.fn(),
}));

vi.mock('react-native', () => ({ View: 'View' }));
vi.mock('../../components/FormScreen', () => ({ FormScreen: ({ children }: any) => children }));
vi.mock('expo-router', () => ({ router: { back: state.back } }));
vi.mock('react-native-paper', async () => {
  const R = await import('react');
  const element = (type: string) => ({ children, ...props }: any) => R.createElement(type, props, children);
  return { Button: element('Button'), Chip: element('Chip'), IconButton: element('IconButton'), Text: element('Text'), TextInput: element('TextInput') };
});
vi.mock('../../components/AppCard', () => ({ AppCard: ({ children }: any) => children }));
vi.mock('../../components/ErrorBoundary', () => ({ ScreenErrorBoundary: ({ children }: any) => children }));
vi.mock('../../lib/useVenueAuth', () => ({ useVenueAuth: () => ({ venue: state.venue, isReady: true, canManage: state.canManage, me: state.me }) }));
vi.mock('../../lib/railway-api', () => ({
  api: { operations: { listLogbook: 'listLogbook', addLogbookEntry: 'addLogbookEntry', deleteLogbookEntry: 'deleteLogbookEntry' } },
}));
vi.mock('../../lib/railway-hooks', () => ({
  useQuery: (ref: string) => (ref === 'listLogbook' ? state.entries : undefined),
  useMutation: (ref: string) => (ref === 'addLogbookEntry' ? state.addEntry : ref === 'deleteLogbookEntry' ? state.deleteEntry : vi.fn()),
}));
vi.mock('../../lib/theme', () => ({
  colors: { background: '#000', charcoal: '#222', danger: '#f00', muted: '#777', primary: '#0f0', surface: '#111' },
  spacing: { lg: 24, md: 16, xxl: 48 },
  type: { title: {} },
}));
vi.mock('../../lib/i18n', () => ({ useI18n: () => ({ t: (key: string) => key }) }));

import LogbookScreenWrapper from '../../app/logbook';

function render() {
  return createRoot();
}
function output(r: ReturnType<typeof createRoot>) {
  return JSON.stringify(r.container.toJSON());
}
function buttonByLabel(r: ReturnType<typeof createRoot>, label: string) {
  return r.container.queryAll((n) => n.type === 'Button').find((n) => JSON.stringify(n.toJSON()).includes(label));
}

describe('Logbook screen', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    state.venue = { id: 'venue-1' };
    state.canManage = true;
    state.me = { profile: { _id: 'p1' } };
    state.entries = { entries: [] };
  });

  it('does not post a blank entry', async () => {
    const r = render();
    await act(async () => r.render(<LogbookScreenWrapper />));
    expect(buttonByLabel(r, 'logbook.postEntry')?.props.disabled).toBe(true);
  });

  it('posts a trimmed entry in the selected category and clears the composer', async () => {
    state.addEntry.mockResolvedValueOnce({});
    const r = render();
    await act(async () => r.render(<LogbookScreenWrapper />));
    const composer = r.container.queryAll((n) => n.type === 'TextInput')[0];
    await act(async () => composer?.props.onChangeText('Walk-in cooler running warm'));
    const incidentChip = r.container.queryAll((n) => n.type === 'Chip').find((n) => JSON.stringify(n.toJSON()).includes('logbook.categoryIncident'));
    await act(async () => incidentChip?.props.onPress());
    await act(async () => buttonByLabel(r, 'logbook.postEntry')?.props.onPress());
    expect(state.addEntry).toHaveBeenCalledWith({ category: 'incident', body: 'Walk-in cooler running warm', pinned: false });
    expect(composer?.props.value).toBe('');
  });

  it('surfaces a failed post', async () => {
    state.addEntry.mockRejectedValueOnce(new Error('Network unavailable'));
    const r = render();
    await act(async () => r.render(<LogbookScreenWrapper />));
    const composer = r.container.queryAll((n) => n.type === 'TextInput')[0];
    await act(async () => composer?.props.onChangeText('Test entry'));
    await act(async () => buttonByLabel(r, 'logbook.postEntry')?.props.onPress());
    expect(output(r)).toContain('Network unavailable');
  });

  it('lets the author delete their own entry even without manage permission', async () => {
    state.canManage = false;
    state.entries = { entries: [entry({ authorProfileId: 'p1' })] };
    state.deleteEntry.mockResolvedValueOnce({});
    const r = render();
    await act(async () => r.render(<LogbookScreenWrapper />));
    const deleteIcon = r.container.queryAll((n) => n.type === 'IconButton').find((n) => n.props.icon === 'close');
    expect(deleteIcon).toBeDefined();
    await act(async () => deleteIcon?.props.onPress());
    expect(state.deleteEntry).toHaveBeenCalledWith('e1');
  });

  it('hides the delete action from staff who did not author the entry', async () => {
    state.canManage = false;
    state.entries = { entries: [entry({ authorProfileId: 'someone-else' })] };
    const r = render();
    await act(async () => r.render(<LogbookScreenWrapper />));
    const deleteIcon = r.container.queryAll((n) => n.type === 'IconButton').find((n) => n.props.icon === 'close');
    expect(deleteIcon).toBeUndefined();
  });

  it('hides pin-to-top from staff without manage permission', async () => {
    state.canManage = false;
    const r = render();
    await act(async () => r.render(<LogbookScreenWrapper />));
    expect(output(r)).not.toContain('logbook.pinToTop');
  });
});

import React, { act } from 'react';
import { createRoot } from 'test-renderer';
import { beforeEach, describe, expect, it, vi } from 'vitest';

const state = vi.hoisted(() => ({
  venue: { id: 'venue-1' } as any,
  canManage: true,
  conversations: undefined as any,
  directory: undefined as any,
  ensureSetup: vi.fn(),
  openDm: vi.fn(),
  createGroup: vi.fn(),
  deleteConversation: vi.fn(),
  push: vi.fn(),
  alert: vi.fn(),
}));

vi.mock('react-native', () => ({
  Alert: { alert: state.alert }, Pressable: 'Pressable', ScrollView: 'ScrollView', View: 'View',
}));
vi.mock('expo-router', () => ({ router: { push: state.push } }));
vi.mock('react-native-paper', async () => {
  const R = await import('react');
  const element = (type: string) => ({ children, ...props }: any) => R.createElement(type, props, children);
  return { Button: element('Button'), HelperText: element('HelperText'), IconButton: element('IconButton'), Text: element('Text'), TextInput: element('TextInput') };
});
vi.mock('@expo/vector-icons', () => ({ MaterialCommunityIcons: 'MaterialCommunityIcons' }));
vi.mock('../../components/ErrorBoundary', () => ({ ScreenErrorBoundary: ({ children }: any) => children }));
vi.mock('../../components/AppCard', () => ({ SectionHeader: ({ title }: any) => title }));
vi.mock('../../lib/useVenueAuth', () => ({ useVenueAuth: () => ({ venue: state.venue, isReady: true, me: { id: 'me1' }, canManage: state.canManage }) }));
vi.mock('../../lib/railway-api', () => ({
  api: { chat: { ensureChatSetup: 'ensureChatSetup', openDm: 'openDm', createGroup: 'createGroup', deleteConversation: 'deleteConversation', listConversations: 'listConversations', listDirectory: 'listDirectory' } },
}));
vi.mock('../../lib/railway-hooks', () => ({
  useQuery: (ref: string) => (ref === 'listConversations' ? state.conversations : ref === 'listDirectory' ? state.directory : undefined),
  useMutation: (ref: string) => {
    if (ref === 'ensureChatSetup') return state.ensureSetup;
    if (ref === 'openDm') return state.openDm;
    if (ref === 'createGroup') return state.createGroup;
    if (ref === 'deleteConversation') return state.deleteConversation;
    return vi.fn();
  },
}));
vi.mock('../../lib/theme', () => ({
  accents: Array.from({ length: 6 }, (_, i) => ({ bg: `#bg${i}`, fg: `#fg${i}`, icon: `#ic${i}` })),
  colors: { background: '#000', border: '#333', charcoal: '#222', danger: '#f00', divider: '#333', muted: '#777', primary: '#0f0', surface: '#111', surfaceSoft: '#191919' },
  radius: { md: 8, sm: 4 },
  spacing: { lg: 24, md: 16, sm: 8, xs: 4, xxl: 48 },
}));
vi.mock('../../lib/format', () => ({ formatRelativeTime: (ts: number) => `t${ts}`, errorMessage: (e: any, fallback: string) => e?.message ?? fallback }));
vi.mock('../../lib/i18n', () => ({
  useI18n: () => ({
    t: (key: string, vars?: Record<string, unknown>) =>
      vars ? `${key}(${Object.entries(vars).map(([k, v]) => `${k}=${String(v)}`).join('|')})` : key,
  }),
}));

import ChatScreenWrapper from '../../app/(tabs)/chat';

function render() {
  return createRoot();
}
function output(r: ReturnType<typeof createRoot>) {
  return JSON.stringify(r.container.toJSON());
}
function buttonByLabel(r: ReturnType<typeof createRoot>, type: string, label: string) {
  return r.container.queryAll((n) => n.type === type).find((n) => JSON.stringify(n.toJSON()).includes(label));
}

describe('Chat screen', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    state.venue = { id: 'venue-1' };
    state.canManage = true;
    state.conversations = { groups: [], dms: [], roles: [], shifts: [] };
    state.directory = [];
    state.ensureSetup.mockResolvedValue({});
  });

  it('shows an unlock message with no active venue instead of an empty chat list', async () => {
    state.venue = null;
    const r = render();
    await act(async () => r.render(<ChatScreenWrapper />));
    expect(output(r)).toContain('chat.unlockTitle');
  });

  it('ensures chat setup runs for the active venue on mount', async () => {
    const r = render();
    await act(async () => r.render(<ChatScreenWrapper />));
    expect(state.ensureSetup).toHaveBeenCalledWith({ venueId: 'venue-1' });
  });

  it('creates a group chat with the trimmed name and navigates to it', async () => {
    state.createGroup.mockResolvedValueOnce({ conversationId: 'conv-1' });
    const r = render();
    await act(async () => r.render(<ChatScreenWrapper />));
    await act(async () => buttonByLabel(r, 'Button', 'chat.newButton')?.props.onPress());
    const input = r.container.queryAll((n) => n.type === 'TextInput')[0];
    await act(async () => input?.props.onChangeText('  Kitchen Crew  '));
    await act(async () => buttonByLabel(r, 'IconButton', '')?.props.onPress());
    expect(state.createGroup).toHaveBeenCalledWith({ venueId: 'venue-1', name: 'Kitchen Crew' });
    expect(state.push).toHaveBeenCalledWith('/chat/conv-1');
  });

  it('does not create a group with a blank name', async () => {
    const r = render();
    await act(async () => r.render(<ChatScreenWrapper />));
    await act(async () => buttonByLabel(r, 'Button', 'chat.newButton')?.props.onPress());
    const confirmButton = r.container.queryAll((n) => n.type === 'IconButton')[0];
    expect(confirmButton?.props.disabled).toBe(true);
  });

  it('confirms before deleting a conversation and only deletes after confirmation', async () => {
    state.conversations = { groups: [{ _id: 'g1', title: 'Kitchen Crew', unread: false }], dms: [], roles: [], shifts: [] };
    state.deleteConversation.mockResolvedValueOnce({});
    const r = render();
    await act(async () => r.render(<ChatScreenWrapper />));
    const deleteIcon = r.container.queryAll((n) => n.type === 'IconButton').find((n) => n.props.icon === 'delete-outline');
    await act(async () => deleteIcon?.props.onPress());

    expect(state.alert).toHaveBeenCalled();
    expect(state.deleteConversation).not.toHaveBeenCalled();

    const [, , buttons] = state.alert.mock.calls[0];
    const confirm = buttons.find((b: any) => b.style === 'destructive');
    await act(async () => confirm.onPress());
    expect(state.deleteConversation).toHaveBeenCalledWith({ conversationId: 'g1' });
  });

  it('hides delete actions from staff without manage permission', async () => {
    state.canManage = false;
    state.conversations = { groups: [{ _id: 'g1', title: 'Kitchen Crew', unread: false }], dms: [], roles: [], shifts: [] };
    const r = render();
    await act(async () => r.render(<ChatScreenWrapper />));
    const deleteIcon = r.container.queryAll((n) => n.type === 'IconButton').find((n) => n.props.icon === 'delete-outline');
    expect(deleteIcon).toBeUndefined();
  });

  it('opens an existing DM instead of starting a new one from the directory', async () => {
    state.conversations = { groups: [], dms: [{ _id: 'dm1', title: 'Sam Rivera', unread: false }], roles: [], shifts: [] };
    state.directory = [{ _id: 'p1', fullName: 'Sam Rivera', role: 'server', jobTitle: 'Server' }];
    const r = render();
    await act(async () => r.render(<ChatScreenWrapper />));
    const teammateRow = r.container.queryAll((n) => n.type === 'Pressable').find((n) => JSON.stringify(n.toJSON()).includes('Sam Rivera') && JSON.stringify(n.toJSON()).includes('server'));
    await act(async () => teammateRow?.props.onPress());
    expect(state.push).toHaveBeenCalledWith('/chat/dm1');
    expect(state.openDm).not.toHaveBeenCalled();
  });

  it('starts a new DM for a teammate with no existing conversation', async () => {
    state.directory = [{ _id: 'p2', fullName: 'Jordan Lee', role: 'bartender', jobTitle: 'Bartender' }];
    state.openDm.mockResolvedValueOnce({ conversationId: 'dm-new' });
    const r = render();
    await act(async () => r.render(<ChatScreenWrapper />));
    const teammateRow = r.container.queryAll((n) => n.type === 'Pressable').find((n) => JSON.stringify(n.toJSON()).includes('Jordan Lee'));
    await act(async () => teammateRow?.props.onPress());
    expect(state.openDm).toHaveBeenCalledWith({ venueId: 'venue-1', targetProfileId: 'p2' });
    expect(state.push).toHaveBeenCalledWith('/chat/dm-new');
  });

  it('filters the group-chats section out when the direct filter is active', async () => {
    state.conversations = { groups: [{ _id: 'g1', title: 'Kitchen Crew', unread: false }], dms: [{ _id: 'dm1', title: 'Sam Rivera', unread: false }], roles: [], shifts: [] };
    const r = render();
    await act(async () => r.render(<ChatScreenWrapper />));
    expect(output(r)).toContain('Kitchen Crew');

    const directTab = r.container.queryAll((n) => n.type === 'Pressable').find((n) => JSON.stringify(n.toJSON()).includes('chat.filterDirect'));
    await act(async () => directTab?.props.onPress());
    const out = output(r);
    expect(out).not.toContain('Kitchen Crew');
    expect(out).toContain('Sam Rivera');
  });
});

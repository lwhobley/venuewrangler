import React, { act } from 'react';
import { createRoot } from 'test-renderer';
import { beforeEach, describe, expect, it, vi } from 'vitest';

function request(overrides: Record<string, unknown> = {}) {
  return {
    id: 'r1', venueId: 'venue-1', venueName: 'The Fox & Vine', userId: 'u1',
    userName: 'Jordan Lee', userEmail: 'jordan@example.com', status: 'pending', createdAt: Date.UTC(2026, 8, 1),
    ...overrides,
  };
}

const state = vi.hoisted(() => ({
  token: 'session-token' as string | null,
  canManage: true,
  profileLoading: false,
  data: undefined as any,
  isLoading: false,
  error: null as unknown,
  refetch: vi.fn(),
  approveJoinRequest: vi.fn(),
  rejectJoinRequest: vi.fn(),
  listManagerJoinRequests: vi.fn(),
  invalidateQueries: vi.fn(),
  back: vi.fn(),
  alert: vi.fn(),
}));

vi.mock('react-native', () => ({
  Alert: { alert: state.alert }, FlatList: ({ data, renderItem, keyExtractor }: any) =>
    React.createElement(
      React.Fragment,
      null,
      ...(data ?? []).map((item: any, index: number) =>
        React.createElement(React.Fragment, { key: keyExtractor ? keyExtractor(item) : index }, renderItem({ item, index }))),
    ),
  SafeAreaView: 'SafeAreaView', StyleSheet: { create: (s: unknown) => s }, View: 'View',
}));
vi.mock('expo-router', () => ({ router: { back: state.back } }));
vi.mock('react-native-paper', async () => {
  const R = await import('react');
  const element = (type: string) => ({ children, ...props }: any) => R.createElement(type, props, children);
  return { ActivityIndicator: element('ActivityIndicator'), Button: element('Button'), Text: element('Text') };
});
// A stable queryClient reference; a fresh object every call would destabilize
// the handleApprove/handleReject useCallback identities.
const queryClientStub = { invalidateQueries: state.invalidateQueries };
vi.mock('@tanstack/react-query', () => ({
  useQuery: () => ({ data: state.data, isLoading: state.isLoading, error: state.error, refetch: state.refetch }),
  useQueryClient: () => queryClientStub,
}));
vi.mock('../../lib/api-client', () => ({
  appApi: { listManagerJoinRequests: state.listManagerJoinRequests, approveJoinRequest: state.approveJoinRequest, rejectJoinRequest: state.rejectJoinRequest },
}));
vi.mock('../../components/AppCard', () => ({ AppCard: ({ children }: any) => children }));
vi.mock('../../lib/auth-store', () => ({ useAuthStore: (select: (s: any) => unknown) => select({ token: state.token }) }));
vi.mock('../../lib/useVenueAuth', () => ({ useVenueAuth: () => ({ profileLoading: state.profileLoading, canManage: state.canManage }) }));
vi.mock('../../lib/theme', () => ({
  spacing: { md: 16, sm: 8 }, type: { heading: {} },
  useDesignTheme: () => ({ background: '#000', backgroundAlt: '#111', charcoal: '#222', danger: '#f00', divider: '#333', muted: '#777', primary: '#0f0' }),
}));
vi.mock('../../lib/i18n', () => ({
  useI18n: () => ({
    t: (key: string, vars?: Record<string, unknown>) =>
      vars ? `${key}(${Object.entries(vars).map(([k, v]) => `${k}=${String(v)}`).join('|')})` : key,
  }),
}));

import JoinRequestsScreen from '../../app/join-requests';

function render() {
  return createRoot();
}
function output(r: ReturnType<typeof createRoot>) {
  return JSON.stringify(r.container.toJSON());
}
function buttonByLabel(r: ReturnType<typeof createRoot>, label: string) {
  return r.container.queryAll((n) => n.type === 'Button').find((n) => JSON.stringify(n.toJSON()).includes(label));
}

describe('Join requests screen', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    state.token = 'session-token';
    state.canManage = true;
    state.profileLoading = false;
    state.data = { requests: [] };
    state.isLoading = false;
    state.error = null;
  });

  it('restricts the screen to managers even when reached by deep link', async () => {
    state.canManage = false;
    const r = render();
    await act(async () => r.render(<JoinRequestsScreen />));
    expect(output(r)).toContain('managers and admins');
  });

  it('shows an empty state when there are no pending requests', async () => {
    const r = render();
    await act(async () => r.render(<JoinRequestsScreen />));
    expect(output(r)).toContain('joinRequests.noPendingTitle');
  });

  it('shows a retry action when the list fails to load', async () => {
    state.error = new Error('network');
    const r = render();
    await act(async () => r.render(<JoinRequestsScreen />));
    expect(output(r)).toContain('joinRequests.failedToLoad');
    await act(async () => buttonByLabel(r, 'joinRequests.retry')?.props.onPress());
    expect(state.refetch).toHaveBeenCalled();
  });

  it('approves a join request and refreshes the list', async () => {
    state.data = { requests: [request()] };
    state.approveJoinRequest.mockResolvedValueOnce({});
    const r = render();
    await act(async () => r.render(<JoinRequestsScreen />));
    await act(async () => buttonByLabel(r, 'joinRequests.approve')?.props.onPress());
    expect(state.approveJoinRequest).toHaveBeenCalledWith('r1');
    expect(state.invalidateQueries).toHaveBeenCalledWith({ queryKey: ['manager-join-requests'] });
  });

  it('confirms before declining a request and only rejects after confirmation', async () => {
    state.data = { requests: [request()] };
    state.rejectJoinRequest.mockResolvedValueOnce({});
    const r = render();
    await act(async () => r.render(<JoinRequestsScreen />));
    await act(async () => buttonByLabel(r, 'joinRequests.decline')?.props.onPress());

    expect(state.alert).toHaveBeenCalled();
    expect(state.rejectJoinRequest).not.toHaveBeenCalled();
    const buttons = state.alert.mock.calls[0][2];
    const confirm = buttons.find((b: any) => b.style === 'destructive');
    await act(async () => confirm.onPress());
    expect(state.rejectJoinRequest).toHaveBeenCalledWith('r1');
  });

  it('surfaces a failed approval', async () => {
    state.data = { requests: [request()] };
    state.approveJoinRequest.mockRejectedValueOnce(new Error('Request already resolved'));
    const r = render();
    await act(async () => r.render(<JoinRequestsScreen />));
    await act(async () => buttonByLabel(r, 'joinRequests.approve')?.props.onPress());
    expect(state.alert).toHaveBeenCalledWith('joinRequests.approveError', 'Request already resolved');
  });
});

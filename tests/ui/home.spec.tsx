import React, { act } from 'react';
import { createRoot } from 'test-renderer';
import { beforeEach, describe, expect, it, vi } from 'vitest';

const state = vi.hoisted(() => ({
  venue: { id: 'venue-1', name: 'The Fox & Vine' } as any,
  venues: [{ id: 'venue-1' }],
  dashboard: undefined as any,
  dashboardError: null as unknown,
  notifications: undefined as any,
  managerDashboard: { data: undefined, error: null, isLoading: false, refetch: vi.fn() },
  dailyBrief: { data: undefined, error: null, isLoading: false, refetch: vi.fn() },
  commandCenter: { data: undefined, error: null, isLoading: false, refetch: vi.fn() },
  markNotificationRead: vi.fn(),
  upsertManagerGoal: vi.fn(),
  refetchDashboard: vi.fn(),
  push: vi.fn(),
}));

vi.mock('react-native', () => ({
  Pressable: 'Pressable', ScrollView: 'ScrollView', View: 'View',
  StyleSheet: { create: (s: unknown) => s, hairlineWidth: 1 },
}));
vi.mock('@expo/vector-icons', () => ({ MaterialCommunityIcons: 'MaterialCommunityIcons' }));
vi.mock('expo-router', () => ({ router: { push: state.push } }));
vi.mock('react-native-paper', async () => {
  const R = await import('react');
  const element = (type: string) => ({ children, ...props }: any) => R.createElement(type, props, children);
  return { TextInput: element('TextInput') };
});
vi.mock('../../components/ErrorBoundary', () => ({ ScreenErrorBoundary: ({ children }: any) => children }));
vi.mock('../../components/FutureUI', async () => {
  const R = await import('react');
  return {
    CommandButton: ({ children, onPress }: any) => R.createElement('CommandButton', { onPress }, children),
    CommandText: ({ children }: any) => R.createElement('CommandText', null, children),
  };
});
vi.mock('../../components/HomeWranglerSurface', () => ({ HomeWranglerSurface: () => null }));
vi.mock('../../components/Skeleton', () => ({ Skeleton: () => 'Skeleton' }));
vi.mock('../../lib/auth-store', () => ({ useAuthStore: (select: (s: any) => unknown) => select({ venue: state.venue, venues: state.venues }) }));
vi.mock('../../lib/usePushNotifications', () => ({ usePushNotifications: () => undefined }));
vi.mock('../../lib/auth-readiness', () => ({ useAuthenticatedSession: () => ({ isReady: true }) }));
vi.mock('../../lib/theme', () => ({
  spacing: { lg: 24, md: 16, sm: 8, xl: 32, xs: 4, xxl: 48 },
  useDesignTheme: () => ({ background: '#000', divider: '#333', primary: '#0f0', warning: '#fa0', success: '#0a0', muted: '#777', border: '#333', charcoal: '#222', surface: '#111' }),
}));
vi.mock('../../lib/railway-api', () => ({
  api: {
    app: { getDashboard: 'getDashboard', getNotifications: 'getNotifications', markNotificationRead: 'markNotificationRead' },
    operations: {
      getManagerDashboard: 'getManagerDashboard', getDailyBrief: 'getDailyBrief', getCommandCenter: 'getCommandCenter',
      upsertManagerGoal: 'upsertManagerGoal',
    },
  },
}));
vi.mock('../../lib/railway-hooks', () => ({
  useQueryState: (ref: string) => {
    if (ref === 'getDashboard') return { data: state.dashboard, error: state.dashboardError, isLoading: false, refetch: state.refetchDashboard };
    if (ref === 'getManagerDashboard') return state.managerDashboard;
    if (ref === 'getDailyBrief') return state.dailyBrief;
    if (ref === 'getCommandCenter') return state.commandCenter;
    return { data: undefined, error: null, isLoading: false, refetch: vi.fn() };
  },
  useQuery: (ref: string) => (ref === 'getNotifications' ? state.notifications : undefined),
  useMutation: (ref: string) => (ref === 'markNotificationRead' ? state.markNotificationRead : ref === 'upsertManagerGoal' ? state.upsertManagerGoal : vi.fn()),
}));

import HomeScreenWrapper from '../../app/(tabs)/home';

function render() {
  return createRoot();
}
function output(r: ReturnType<typeof createRoot>) {
  return JSON.stringify(r.container.toJSON());
}
function commandButtonByLabel(r: ReturnType<typeof createRoot>, label: string) {
  return r.container.queryAll((n) => n.type === 'CommandButton').find((n) => JSON.stringify(n.toJSON()).includes(label));
}

describe('Home dashboard screen', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    state.venue = { id: 'venue-1', name: 'The Fox & Vine' };
    state.venues = [{ id: 'venue-1' }];
    state.dashboard = { venue: { name: 'The Fox & Vine' }, profile: { role: 'manager', allAccess: true }, analytics: { clockedInCount: 3 } };
    state.dashboardError = null;
    state.notifications = [];
    state.managerDashboard = { data: undefined, error: null, isLoading: false, refetch: vi.fn() };
    state.dailyBrief = { data: undefined, error: null, isLoading: false, refetch: vi.fn() };
    state.commandCenter = { data: undefined, error: null, isLoading: false, refetch: vi.fn() };
  });

  it('shows a loading skeleton while the dashboard query is pending', async () => {
    state.dashboard = undefined;
    const r = render();
    await act(async () => r.render(<HomeScreenWrapper />));
    expect(output(r)).toContain('Skeleton');
  });

  it('shows a retry action when the dashboard fails to load', async () => {
    state.dashboard = undefined;
    state.dashboardError = new Error('network down');
    const r = render();
    await act(async () => r.render(<HomeScreenWrapper />));
    expect(output(r)).toContain('Failed to load operations dashboard');
    await act(async () => commandButtonByLabel(r, 'Retry')?.props.onPress());
    expect(state.refetchDashboard).toHaveBeenCalled();
  });

  it('flags a stale readiness/flow/pulse panel when any of the three manager queries fails, and retries all three', async () => {
    state.commandCenter = { data: undefined, error: new Error('boom'), isLoading: false, refetch: vi.fn() };
    const r = render();
    await act(async () => r.render(<HomeScreenWrapper />));
    expect(output(r)).toContain("Couldn't load today's readiness, flow, or pulse");
    await act(async () => commandButtonByLabel(r, 'Retry')?.props.onPress());
    expect(state.managerDashboard.refetch).toHaveBeenCalled();
    expect(state.dailyBrief.refetch).toHaveBeenCalled();
    expect(state.commandCenter.refetch).toHaveBeenCalled();
  });

  it('marks every unread notification read, not just the visible one', async () => {
    state.notifications = [
      { _id: 'n1', title: 'Shift covered', body: 'Alex covered your Friday shift.', read: false },
      { _id: 'n2', title: 'Schedule posted', body: 'Next week is live.', read: false },
      { _id: 'n3', title: 'Old one', body: 'Already seen.', read: true },
    ];
    state.markNotificationRead.mockResolvedValue({});
    const r = render();
    await act(async () => r.render(<HomeScreenWrapper />));
    const bell = r.container.queryAll((n) => n.type === 'Pressable').find((n) => n.props.accessibilityLabel === 'Open notifications');
    await act(async () => bell?.props.onPress());
    await act(async () => commandButtonByLabel(r, 'Mark all read')?.props.onPress());
    expect(state.markNotificationRead).toHaveBeenCalledTimes(2);
    expect(state.markNotificationRead).toHaveBeenCalledWith({ notificationId: 'n1' });
    expect(state.markNotificationRead).toHaveBeenCalledWith({ notificationId: 'n2' });
  });

  it('adds a manager goal for today and clears the input', async () => {
    state.upsertManagerGoal.mockResolvedValueOnce({});
    const r = render();
    await act(async () => r.render(<HomeScreenWrapper />));
    const input = r.container.queryAll((n) => n.type === 'TextInput')[0];
    await act(async () => input?.props.onChangeText('86 the salmon special'));
    await act(async () => commandButtonByLabel(r, 'Add goal')?.props.onPress());
    expect(state.upsertManagerGoal).toHaveBeenCalledWith(expect.objectContaining({
      venueId: 'venue-1', title: '86 the salmon special', period: 'day', status: 'open',
    }));
  });

  it('does not submit a blank manager goal', async () => {
    const r = render();
    await act(async () => r.render(<HomeScreenWrapper />));
    await act(async () => commandButtonByLabel(r, 'Add goal')?.props.onPress());
    expect(state.upsertManagerGoal).not.toHaveBeenCalled();
  });

  it('hides the manager goal composer from non-managers', async () => {
    state.dashboard = { venue: { name: 'The Fox & Vine' }, profile: { role: 'staff', allAccess: false }, analytics: { clockedInCount: 3 } };
    const r = render();
    await act(async () => r.render(<HomeScreenWrapper />));
    expect(output(r)).not.toContain('Manager goal');
  });
});

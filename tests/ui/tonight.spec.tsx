import React, { act } from 'react';
import { createRoot } from 'test-renderer';
import { beforeEach, describe, expect, it, vi } from 'vitest';

const state = vi.hoisted(() => ({
  ready: true,
  dashboard: { data: undefined as any, error: null as Error | null, isLoading: false, refetch: vi.fn() },
  brief: { data: undefined as any, error: null as Error | null, isLoading: false, subscriptionRequired: false, refetch: vi.fn() },
  board: { data: undefined as any, error: null as Error | null, isLoading: false, refetch: vi.fn() },
  query: vi.fn(),
  push: vi.fn(),
}));

vi.mock('../../lib/config', () => ({ config: { restaurantCoreOnly: true } }));
vi.mock('../../components/FullVenueHome', () => ({ default: () => null }));
vi.mock('../../components/ErrorBoundary', () => ({ ScreenErrorBoundary: ({ children }: any) => children }));
vi.mock('../../components/Skeleton', () => ({ Skeleton: () => 'Skeleton' }));
vi.mock('expo-router', () => ({ router: { push: state.push } }));
vi.mock('react-native', () => ({
  ScrollView: 'ScrollView', View: 'View', Pressable: 'Pressable',
  StyleSheet: { create: (styles: unknown) => styles, hairlineWidth: 1 },
}));
vi.mock('react-native-paper', async () => {
  const R = await import('react');
  const element = (type: string) => ({ children, ...props }: any) => R.createElement(type, props, children);
  return { Card: Object.assign(element('Card'), { Title: element('Card.Title'), Content: element('Card.Content') }), Text: element('Text'), ActivityIndicator: element('ActivityIndicator') };
});
vi.mock('../../lib/theme', () => ({
  colors: { background: '#fff', primary: '#080', charcoal: '#222', muted: '#777', surface: '#fff', border: '#ddd', danger: '#f00' },
  spacing: { lg: 24, md: 16, sm: 8, xxl: 48 }, radius: { sharp: 4 },
}));
vi.mock('../../lib/i18n', () => ({ useI18n: () => ({ t: (key: string) => key }) }));
vi.mock('../../lib/auth-store', () => ({ useAuthStore: (select: (s: any) => unknown) => select({ venue: { id: 'venue-1', name: 'Fox & Vine' } }) }));
vi.mock('../../lib/auth-readiness', () => ({ useAuthenticatedSession: () => ({ isReady: state.ready }) }));
vi.mock('../../lib/usePushNotifications', () => ({ usePushNotifications: () => undefined }));
vi.mock('../../lib/railway-api', () => ({ api: { app: { getDashboard: 'dashboard', getClockBoard: 'board' }, operations: { getDailyBrief: 'brief' } } }));
vi.mock('../../lib/railway-hooks', () => ({
  useQueryState: (ref: string, args: unknown) => {
    state.query(ref, args);
    return ref === 'dashboard' ? state.dashboard : ref === 'brief' ? state.brief : state.board;
  },
}));

import Home from '../../app/(tabs)/home';

async function render() {
  const root = createRoot();
  await act(async () => root.render(<Home />));
  return root;
}
const output = (root: ReturnType<typeof createRoot>) => JSON.stringify(root.container.toJSON());

describe('Restaurant Tonight dashboard', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    state.ready = true;
    state.dashboard = { data: { profile: { role: 'manager', allAccess: false } }, error: null, isLoading: false, refetch: vi.fn() };
    state.brief = { data: { date: '2026-09-18', scheduledCount: 1, clockedInCount: 2, pendingRequestCount: 3, shifts: [{ id: 'shift-1', staffName: 'Alex', jobTitle: 'Server', startMinutes: 1020, endMinutes: 1560 }] }, error: null, isLoading: false, subscriptionRequired: false, refetch: vi.fn() };
    state.board = { data: { managerAlerts: [] }, error: null, isLoading: false, refetch: vi.fn() };
  });

  it('renders the daily-brief roster, venue date, and overnight times', async () => {
    const root = await render();
    expect(output(root)).toContain('Alex');
    expect(output(root)).toContain('2026-09-18');
    expect(output(root)).toContain('5:00 PM');
    expect(output(root)).toContain('2:00 AM');
    expect(output(root)).not.toContain('No shifts scheduled tonight.');
    expect(state.query).toHaveBeenCalledWith('brief', {});
  });

  it('shows a genuine empty roster only after a successful response', async () => {
    state.brief.data.shifts = [];
    expect(output(await render())).toContain('No shifts scheduled tonight.');
  });

  it('handles an older API during rollout without inventing an empty roster', async () => {
    delete state.brief.data.shifts;
    const root = await render();
    expect(output(root)).toContain('Team details are unavailable');
    expect(output(root)).not.toContain('No shifts scheduled tonight.');
  });

  it('shows loading rather than an empty roster', async () => {
    state.brief.data = undefined;
    state.brief.isLoading = true;
    const root = await render();
    expect(output(root)).toContain('Skeleton');
    expect(output(root)).not.toContain('No shifts scheduled tonight.');
  });

  it('reports a failed roster and retries it without inventing zero counts', async () => {
    state.brief.data = undefined;
    state.brief.error = new Error('network down');
    const root = await render();
    expect(output(root)).toContain('network down');
    expect(output(root)).not.toContain('Scheduled');
    await act(async () => root.container.queryAll((n) => n.type === 'Pressable')[0]?.props.onPress());
    expect(state.brief.refetch).toHaveBeenCalledOnce();
  });

  it('flags stale data when a background refresh fails', async () => {
    state.brief.error = new Error('network down');
    const root = await render();
    expect(output(root)).toContain('Alex');
    expect(output(root)).toContain('queryBoundary.stale');
  });

  it('shows the upgrade action for a settled subscription denial', async () => {
    state.brief.data = undefined;
    state.brief.subscriptionRequired = true;
    const root = await render();
    expect(output(root)).toContain('queryBoundary.viewPlans');
    await act(async () => root.container.queryAll((n) => n.type === 'Pressable')[0]?.props.onPress());
    expect(state.push).toHaveBeenCalledWith('/billing');
  });

  it('does not request manager-only data for staff or before identity is resolved', async () => {
    state.dashboard.data.profile.role = 'staff';
    expect(output(await render())).toContain('Your shifts');
    expect(state.query).toHaveBeenCalledWith('brief', 'skip');
    expect(state.query).toHaveBeenCalledWith('board', 'skip');
    vi.clearAllMocks();
    state.dashboard.data = undefined;
    state.dashboard.isLoading = true;
    expect(output(await render())).toContain('Skeleton');
    expect(state.query).toHaveBeenCalledWith('brief', 'skip');
  });

  it('reports dashboard and clock-board failures instead of pretending they are empty', async () => {
    state.board.data = undefined;
    state.board.error = new Error('clock board unavailable');
    expect(output(await render())).toContain('clock board unavailable');
    state.dashboard.data = undefined;
    state.dashboard.error = new Error('profile unavailable');
    expect(output(await render())).toContain('profile unavailable');
  });

  it('holds the screen and disables queries before auth hydration', async () => {
    state.ready = false;
    const root = await render();
    expect(output(root)).toContain('ActivityIndicator');
    expect(state.query).toHaveBeenCalledWith('dashboard', 'skip');
    expect(state.query).toHaveBeenCalledWith('brief', 'skip');
  });
});

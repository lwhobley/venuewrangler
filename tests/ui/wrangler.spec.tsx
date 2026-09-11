import React, { act } from 'react';
import { createRoot } from 'test-renderer';
import { beforeEach, describe, expect, it, vi } from 'vitest';

function snapshot(overrides: Record<string, unknown> = {}) {
  return {
    venue: { name: 'The Fox & Vine' },
    servicePhaseLabel: 'dinner',
    status: 'attention',
    summary: { covers: 40, reservations: 12, vipArrivals: 2, seatedTables: 8, openShifts: 1, lowStockItems: 3, eightySixItems: 0, pendingStaffRequests: 2 },
    priorities: [],
    ...overrides,
  };
}

const state = vi.hoisted(() => ({
  params: {} as Record<string, string>,
  wrangler: { data: undefined as any, isLoading: false, isError: false },
  mutateAsync: vi.fn(),
  isPending: false,
  push: vi.fn(),
  back: vi.fn(),
  alert: vi.fn(),
}));

vi.mock('react-native', () => ({ Alert: { alert: state.alert }, ScrollView: 'ScrollView', StyleSheet: { create: (s: unknown) => s, hairlineWidth: 1 }, View: 'View' }));
vi.mock('expo-router', () => ({ router: { push: state.push, back: state.back }, useLocalSearchParams: () => state.params }));
vi.mock('@expo/vector-icons', () => ({ MaterialCommunityIcons: 'MaterialCommunityIcons' }));
vi.mock('../../components/FutureUI', () => {
  const React = require('react');
  return {
    CommandButton: ({ children, onPress, disabled }: any) => React.createElement('CommandButton', { onPress, disabled }, children),
    CommandText: ({ children }: any) => React.createElement('CommandText', null, children),
  };
});
vi.mock('../../components/Skeleton', () => ({ Skeleton: () => 'Skeleton' }));
vi.mock('../../components/WranglerAiUsagePanel', () => ({ WranglerAiUsagePanel: () => null }));
vi.mock('../../components/WranglerIntelligencePanel', () => ({ WranglerIntelligencePanel: () => null }));
vi.mock('../../components/WranglerShiftStory', () => ({ WranglerShiftStory: () => null }));
vi.mock('../../lib/theme', () => ({
  spacing: { lg: 24, md: 16, sm: 8, xl: 32, xxl: 48 },
  radius: { sharp: 6, soft: 12, sm: 4, md: 8, lg: 12, xl: 16, pill: 9999 },
  useDesignTheme: () => ({ background: '#000', divider: '#333', warning: '#fa0', success: '#0a0', muted: '#777', surface: '#111', border: '#333' }),
}));
vi.mock('../../lib/useWrangler', () => ({
  useWrangler: () => state.wrangler,
  useExecuteWranglerAction: () => ({ mutateAsync: state.mutateAsync, isPending: state.isPending }),
}));

import WranglerScreen from '../../app/wrangler';

function render() {
  return createRoot();
}
function output(r: ReturnType<typeof createRoot>) {
  return JSON.stringify(r.container.toJSON());
}
function commandButtonByLabel(r: ReturnType<typeof createRoot>, label: string) {
  return r.container.queryAll((n) => n.type === 'CommandButton').find((n) => JSON.stringify(n.toJSON()).includes(label));
}

describe('Wrangler screen', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    state.params = {};
    state.wrangler = { data: undefined, isLoading: false, isError: false };
    state.isPending = false;
  });

  it('shows a loading skeleton while the snapshot loads', async () => {
    state.wrangler = { data: undefined, isLoading: true, isError: false };
    const r = render();
    await act(async () => r.render(<WranglerScreen />));
    expect(output(r)).toContain('Skeleton');
  });

  it('shows an error state with a way back when the snapshot fails to load', async () => {
    state.wrangler = { data: undefined, isLoading: false, isError: true };
    const r = render();
    await act(async () => r.render(<WranglerScreen />));
    expect(output(r)).toContain('The Wrangler could not load');
    await act(async () => commandButtonByLabel(r, 'Go back')?.props.onPress());
    expect(state.back).toHaveBeenCalled();
  });

  it('renders prioritized items with their severity label', async () => {
    state.wrangler = {
      data: snapshot({ priorities: [{ id: 'p1', kind: 'coverage', severity: 'critical', title: 'Short-staffed tonight', body: 'Two servers called out.', reason: 'Below minimum coverage.', actions: [] }] }),
      isLoading: false, isError: false,
    };
    const r = render();
    await act(async () => r.render(<WranglerScreen />));
    const out = output(r);
    expect(out).toContain('Short-staffed tonight');
    expect(out).toContain('CRITICAL');
  });

  it('only navigates to an allow-listed route from a server-supplied NAVIGATE action', async () => {
    state.wrangler = {
      data: snapshot({
        priorities: [{
          id: 'p1', kind: 'floor', severity: 'warning', title: 'Table conflict', body: 'x', reason: 'y',
          actions: [{ type: 'NAVIGATE', label: 'View floor', route: '/floor', requiresConfirmation: false }],
        }],
      }),
      isLoading: false, isError: false,
    };
    const r = render();
    await act(async () => r.render(<WranglerScreen />));
    await act(async () => commandButtonByLabel(r, 'View floor')?.props.onPress());
    expect(state.push).toHaveBeenCalledWith('/floor');
  });

  it('refuses to navigate to a route outside the allowlist', async () => {
    state.wrangler = {
      data: snapshot({
        priorities: [{
          id: 'p1', kind: 'floor', severity: 'warning', title: 'Suspicious link', body: 'x', reason: 'y',
          actions: [{ type: 'NAVIGATE', label: 'Go', route: 'https://evil.example.com', requiresConfirmation: false }],
        }],
      }),
      isLoading: false, isError: false,
    };
    const r = render();
    await act(async () => r.render(<WranglerScreen />));
    await act(async () => commandButtonByLabel(r, 'Go')?.props.onPress());
    expect(state.push).not.toHaveBeenCalled();
  });

  it('confirms before notifying staff, then sends the alert', async () => {
    state.wrangler = {
      data: snapshot({
        priorities: [{
          id: 'p1', kind: 'coverage', severity: 'critical', title: 'Open shift', body: 'x', reason: 'y',
          actions: [{ type: 'NOTIFY_STAFF', label: 'Notify staff', requiresConfirmation: true }],
        }],
      }),
      isLoading: false, isError: false,
    };
    state.mutateAsync.mockResolvedValueOnce({ openShifts: 2 });
    const r = render();
    await act(async () => r.render(<WranglerScreen />));
    await act(async () => commandButtonByLabel(r, 'Notify staff')?.props.onPress());

    expect(state.mutateAsync).not.toHaveBeenCalled();
    const confirmButtons = state.alert.mock.calls[0][2];
    const confirm = confirmButtons.find((b: any) => b.text === 'Notify staff');
    await act(async () => confirm.onPress());
    expect(state.mutateAsync).toHaveBeenCalledWith({ type: 'NOTIFY_STAFF' });
  });

  it('creates a follow-up for a priority after confirmation', async () => {
    state.wrangler = {
      data: snapshot({
        priorities: [{ id: 'p1', kind: 'coverage', severity: 'watch', title: 'Check the walk-in', body: 'x', reason: 'y', actions: [] }],
      }),
      isLoading: false, isError: false,
    };
    state.mutateAsync.mockResolvedValueOnce({ existing: false, title: 'Check the walk-in' });
    const r = render();
    await act(async () => r.render(<WranglerScreen />));
    await act(async () => commandButtonByLabel(r, 'Create follow-up')?.props.onPress());
    const confirmButtons = state.alert.mock.calls[0][2];
    const confirm = confirmButtons.find((b: any) => b.text === 'Create follow-up');
    await act(async () => confirm.onPress());
    expect(state.mutateAsync).toHaveBeenCalledWith({ type: 'CREATE_FOLLOW_UP', priorityId: 'p1' });
  });
});

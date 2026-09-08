import React, { act } from 'react';
import { createRoot } from 'test-renderer';
import { beforeEach, describe, expect, it, vi } from 'vitest';

const state = vi.hoisted(() => ({
  venue: { id: 'venue-1', timezone: 'America/New_York' } as any,
  canManage: true,
  requests: [] as any[],
  swaps: [] as any[],
  reviewRequest: vi.fn(),
  reviewSwap: vi.fn(),
}));

vi.mock('react-native', () => ({ ScrollView: 'ScrollView', View: 'View' }));
vi.mock('react-native-paper', async () => {
  const R = await import('react');
  const element = (type: string) => ({ children, ...props }: any) => R.createElement(type, props, children);
  const Card = Object.assign(element('Card'), { Content: element('Card.Content') });
  return {
    Button: element('Button'), Card, SegmentedButtons: element('SegmentedButtons'),
    Snackbar: ({ visible, children }: any) => (visible ? R.createElement('Snackbar', null, children) : null),
    Text: element('Text'),
  };
});
vi.mock('../../components/ErrorBoundary', () => ({ ScreenErrorBoundary: ({ children }: any) => children }));
vi.mock('../../components/AppCard', () => ({ AnimatedTab: ({ children }: any) => children, SectionHeader: ({ title }: any) => title }));
vi.mock('../../lib/responsive', () => ({ useDesktopContentStyle: (base: unknown) => base }));
vi.mock('../../lib/useVenueAuth', () => ({ useVenueAuth: () => ({ venue: state.venue, canManage: state.canManage }) }));
vi.mock('../../lib/staff-request-summary', () => ({ correctionSummary: () => null }));
vi.mock('../../components/schedule/ManagerCalendar', () => ({ ManagerCalendar: () => 'ManagerCalendar' }));
vi.mock('../../components/schedule/MyShifts', () => ({ MyShifts: () => 'MyShifts' }));
vi.mock('../../components/schedule/BlackoutManager', () => ({ BlackoutManager: () => 'BlackoutManager' }));
vi.mock('../../components/schedule/LaborForecastPanel', () => ({ LaborForecastPanel: () => 'LaborForecastPanel' }));
vi.mock('../../lib/railway-api', () => ({
  api: {
    app: { listStaffRequests: 'listStaffRequests', reviewStaffRequest: 'reviewStaffRequest' },
    scheduling: { listShiftSwaps: 'listShiftSwaps', reviewShiftSwap: 'reviewShiftSwap' },
  },
}));
vi.mock('../../lib/railway-hooks', () => ({
  useQuery: (ref: string) => (ref === 'listStaffRequests' ? state.requests : ref === 'listShiftSwaps' ? state.swaps : undefined),
  useMutation: (ref: string) => (ref === 'reviewStaffRequest' ? state.reviewRequest : ref === 'reviewShiftSwap' ? state.reviewSwap : vi.fn()),
}));
vi.mock('../../lib/format', () => ({ errorMessage: (e: any, fallback: string) => e?.message ?? fallback }));
vi.mock('../../lib/theme', () => ({
  colors: { background: '#000', border: '#333', charcoal: '#222', danger: '#f00', muted: '#777', primary: '#0f0', surface: '#111' },
  radius: { sharp: 4 },
  spacing: { lg: 24, md: 16, sm: 8, xxl: 48 },
}));
vi.mock('../../lib/i18n', () => ({ useI18n: () => ({ t: (key: string) => key }) }));

import ScheduleScreen from '../../app/(tabs)/schedule';

function render() {
  return createRoot();
}
function output(r: ReturnType<typeof createRoot>) {
  return JSON.stringify(r.container.toJSON());
}
function buttonByLabel(r: ReturnType<typeof createRoot>, label: string) {
  return r.container.queryAll((n) => n.type === 'Button').find((n) => JSON.stringify(n.toJSON()).includes(label));
}

describe('Schedule screen', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    state.venue = { id: 'venue-1', timezone: 'America/New_York' };
    state.canManage = true;
    state.requests = [];
    state.swaps = [];
  });

  it('shows a no-venue message when there is no active venue', async () => {
    state.venue = null;
    const r = render();
    await act(async () => r.render(<ScheduleScreen />));
    expect(output(r)).toContain('schedule.noVenue');
  });

  it('shows the staff my-shifts view for non-managers', async () => {
    state.canManage = false;
    const r = render();
    await act(async () => r.render(<ScheduleScreen />));
    expect(output(r)).toContain('MyShifts');
    expect(output(r)).not.toContain('schedule.tabCalendar');
  });

  it('switches manager tabs between calendar, forecast, requests, and blackouts', async () => {
    const r = render();
    await act(async () => r.render(<ScheduleScreen />));
    expect(output(r)).toContain('ManagerCalendar');

    const buttons = r.container.queryAll((n) => n.type === 'SegmentedButtons');
    await act(async () => buttons[0]?.props.onValueChange('forecast'));
    expect(output(r)).toContain('LaborForecastPanel');

    await act(async () => buttons[0]?.props.onValueChange('blackouts'));
    expect(output(r)).toContain('BlackoutManager');
  });

  it('approves a pending staff request and shows a confirmation toast', async () => {
    state.requests = [{ _id: 'req1', title: 'Time off', kind: 'time_off', status: 'pending', details: 'Next Friday' }];
    state.reviewRequest.mockResolvedValueOnce({});
    const r = render();
    await act(async () => r.render(<ScheduleScreen />));
    const buttons = r.container.queryAll((n) => n.type === 'SegmentedButtons');
    await act(async () => buttons[0]?.props.onValueChange('requests'));

    await act(async () => buttonByLabel(r, 'schedule.approve')?.props.onPress());
    expect(state.reviewRequest).toHaveBeenCalledWith({ requestId: 'req1', status: 'approved' });
    expect(output(r)).toContain('schedule.requestApproved');
  });

  it('denies a shift swap and reports a failure without approving anyway', async () => {
    state.swaps = [{ _id: 'swap1', status: 'pending', requesterName: 'Alex', targetName: 'Sam', requesterShift: 'Fri 5-close', targetShift: null }];
    state.reviewSwap.mockRejectedValueOnce(new Error('Swap already resolved'));
    const r = render();
    await act(async () => r.render(<ScheduleScreen />));
    const buttons = r.container.queryAll((n) => n.type === 'SegmentedButtons');
    await act(async () => buttons[0]?.props.onValueChange('requests'));

    await act(async () => buttonByLabel(r, 'schedule.deny')?.props.onPress());
    expect(state.reviewSwap).toHaveBeenCalledWith({ swapId: 'swap1', approve: false });
    expect(output(r)).toContain('Swap already resolved');
  });
});

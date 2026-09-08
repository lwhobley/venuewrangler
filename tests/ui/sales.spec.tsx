import React, { act } from 'react';
import { createRoot } from 'test-renderer';
import { beforeEach, describe, expect, it, vi } from 'vitest';

const state = vi.hoisted(() => ({
  venue: { id: 'venue-1', name: 'The Fox & Vine', timezone: 'America/New_York' } as any,
  canManage: true,
  profileLoading: false,
  profileError: null as unknown,
  summary: undefined as any,
  servers: undefined as any,
  items: undefined as any,
  labor: undefined as any,
}));

vi.mock('react-native', () => ({ ScrollView: 'ScrollView', View: 'View' }));
vi.mock('react-native-paper', async () => {
  const R = await import('react');
  const element = (type: string) => ({ children, ...props }: any) => R.createElement(type, props, children);
  const Card = Object.assign(element('Card'), { Content: element('Card.Content') });
  return { Card, Chip: element('Chip'), SegmentedButtons: element('SegmentedButtons'), Text: element('Text') };
});
vi.mock('../../components/ErrorBoundary', () => ({ ScreenErrorBoundary: ({ children }: any) => children }));
vi.mock('../../components/AppCard', () => ({
  AnimatedTab: ({ children }: any) => children,
  SectionHeader: ({ title }: any) => title,
}));
vi.mock('../../components/schedule/ScheduleSkeleton', () => ({ ScheduleSkeleton: () => 'Skeleton' }));
vi.mock('../../components/PremiumFeatureGate', () => ({ PremiumFeatureGate: ({ children }: any) => children }));
vi.mock('../../components/ManagerGate', () => ({
  ManagerGate: ({ children, canManage }: any) => (canManage === false ? 'ManagerGateBlocked' : children),
}));
vi.mock('../../components/DateRangeBar', () => ({
  DateRangeBar: () => null,
  useDateRange: () => ({
    selected: { shortLabel: 'Today', days: 1, startTs: 1000, endTs: 2000 },
    setSelected: vi.fn(),
    presets: [],
  }),
}));
vi.mock('../../lib/useVenueAuth', () => ({
  useVenueAuth: () => ({
    venue: state.venue,
    isReady: true,
    profileLoading: state.profileLoading,
    profileError: state.profileError,
    refetchProfile: vi.fn(),
    canManage: state.canManage,
  }),
}));
vi.mock('../../lib/railway-api', () => ({
  api: {
    pos: {
      getSalesSummaryDashboard: 'getSalesSummaryDashboard',
      getSalesByServer: 'getSalesByServer',
      getTopMenuItems: 'getTopMenuItems',
      getLaborSummary: 'getLaborSummary',
    },
  },
}));
vi.mock('../../lib/railway-hooks', () => ({
  useQuery: (ref: string) => {
    if (ref === 'getSalesSummaryDashboard') return state.summary;
    if (ref === 'getSalesByServer') return state.servers;
    if (ref === 'getTopMenuItems') return state.items;
    if (ref === 'getLaborSummary') return state.labor;
    return undefined;
  },
}));
vi.mock('../../lib/i18n', () => ({
  useI18n: () => ({
    t: (key: string, vars?: Record<string, unknown>) =>
      vars ? `${key}(${Object.entries(vars).map(([k, v]) => `${k}=${String(v)}`).join('|')})` : key,
  }),
}));
vi.mock('../../lib/theme', () => ({
  accents: Array.from({ length: 6 }, (_, i) => ({ bg: `#bg${i}`, fg: `#fg${i}`, icon: `#ic${i}` })),
  colors: { background: '#000', border: '#333', charcoal: '#222', danger: '#f00', muted: '#777', primary: '#0f0', surface: '#111' },
  radius: { sharp: 4 },
  spacing: { lg: 24, md: 16, sm: 8, xs: 4 },
}));

import SalesScreen from '../../app/(tabs)/sales';

function render() {
  const r = createRoot();
  return r;
}
function output(r: ReturnType<typeof createRoot>) {
  return JSON.stringify(r.container.toJSON());
}

describe('Sales screen', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    state.venue = { id: 'venue-1', name: 'The Fox & Vine', timezone: 'America/New_York' };
    state.canManage = true;
    state.profileLoading = false;
    state.profileError = null;
    state.summary = undefined;
    state.servers = undefined;
    state.items = undefined;
    state.labor = undefined;
  });

  it('shows a no-venue message when the operator has no active venue', async () => {
    state.venue = null;
    const r = render();
    await act(async () => r.render(<SalesScreen />));
    expect(output(r)).toContain('sales.noVenue');
  });

  it('blocks non-managers from the sales dashboard', async () => {
    state.canManage = false;
    const r = render();
    await act(async () => r.render(<SalesScreen />));
    expect(output(r)).toContain('ManagerGateBlocked');
  });

  it('shows a loading skeleton while the summary query is pending', async () => {
    const r = render();
    await act(async () => r.render(<SalesScreen />));
    expect(output(r)).toContain('Skeleton');
  });

  it('shows an empty state when there were no checks in the window', async () => {
    state.summary = { summary: { checkCount: 0 }, byDay: [], byTender: [], byRevenueCenter: [] };
    const r = render();
    await act(async () => r.render(<SalesScreen />));
    expect(output(r)).toContain('sales.summary.empty');
  });

  it('computes net sales as gross minus discounts, comps, and promos', async () => {
    state.summary = {
      summary: {
        checkCount: 12, salesCents: 100000, discountCents: 2000, compCents: 1000, promoCents: 500,
        tipCents: 15000, taxCents: 8000, avgCheckCents: 8333, coverCount: 30, avgCheckTimeMins: 45,
      },
      byDay: [{ date: '2026-09-01', salesCents: 100000 }],
      byTender: [{ tenderType: 'card', salesCents: 90000 }],
      byRevenueCenter: [],
    };
    const r = render();
    await act(async () => r.render(<SalesScreen />));
    const out = output(r);
    // netSales = 100000 - (2000 + 1000 + 500) = 96500 cents = $965.00
    expect(out).toContain('$965.00');
    expect(out).not.toContain('undefined');
  });

  it('renders per-server sales when the servers tab is selected', async () => {
    state.summary = { summary: { checkCount: 1, salesCents: 100, discountCents: 0, compCents: 0, promoCents: 0, tipCents: 0, taxCents: 0, avgCheckCents: 100, coverCount: 1 }, byDay: [], byTender: [], byRevenueCenter: [] };
    state.servers = [{ serverName: 'Renée Söderberg', salesCents: 50000, checkCount: 10, coverCount: 20, avgCheckCents: 5000, tipCents: 8000, compCents: 0, discountCents: 0 }];
    const r = render();
    await act(async () => r.render(<SalesScreen />));
    const buttons = r.container.queryAll((n) => n.type === 'SegmentedButtons');
    await act(async () => buttons[0]?.props.onValueChange('servers'));
    expect(output(r)).toContain('Renée Söderberg');
  });

  it('renders labor totals when the labor tab is selected', async () => {
    state.summary = { summary: { checkCount: 1, salesCents: 100, discountCents: 0, compCents: 0, promoCents: 0, tipCents: 0, taxCents: 0, avgCheckCents: 100, coverCount: 1 }, byDay: [], byTender: [], byRevenueCenter: [] };
    state.labor = {
      totalRegularMins: 480, totalOvertimeMins: 60, totalPayCents: 120000, totalTipsCents: 30000,
      byEmployee: [{ employeeName: 'Marcus Delacroix', jobTitle: 'Bartender', payCents: 40000, regularMins: 240, overtimeMins: 0, tipsCents: 10000 }],
    };
    const r = render();
    await act(async () => r.render(<SalesScreen />));
    const buttons = r.container.queryAll((n) => n.type === 'SegmentedButtons');
    await act(async () => buttons[0]?.props.onValueChange('labor'));
    expect(output(r)).toContain('Marcus Delacroix');
    expect(output(r)).not.toContain('undefined');
  });
});

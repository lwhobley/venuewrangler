import React, { act } from 'react';
import { createRoot } from 'test-renderer';
import { beforeEach, describe, expect, it, vi } from 'vitest';

/**
 * Regression cover for the Reports screen's two shipped contract bugs:
 *
 *   1. Six of seven KPI tiles read fields GET /v1/app/manager-insights never
 *      returned, so `?? 0` rendered a confident zero for real venues.
 *   2. The payroll card read `payroll.totalHours` / `payroll.openEntryCount`
 *      off a response that nests everything under `totals`, rendering
 *      "undefinedh · undefined employees", and posted `periodStart: undefined`
 *      into a DTO that requires a string — a guaranteed 400 that the UI
 *      swallowed as an unhandled rejection.
 *
 * The static guard lives in lib/railway-response-parity.spec.ts; this asserts
 * what a manager actually sees.
 */

const state = vi.hoisted(() => ({
  recordExport: vi.fn(),
  insights: {
    laborHours: 132.5,
    scheduledShifts: 24,
    openShifts: 3,
    activeClocks: 7,
    lateOrMissedAlerts: 2,
    activeReservations: 15,
    upcomingReservations: 9,
    pendingRequests: 4,
    openRequests: 4,
  } as Record<string, number> | null,
  payroll: {
    data: {
      byEmployee: [
        { profileId: 'p1', employeeName: 'Renée Söderberg', role: 'server', jobTitle: 'Server', regularHours: 31.5, totalHours: 31.5 },
        { profileId: 'p2', employeeName: 'Marcus Delacroix', role: 'staff', jobTitle: 'Bartender', regularHours: 28, totalHours: 28 },
      ],
      totals: { totalHours: 59.5, employeeCount: 2, periodStart: Date.UTC(2026, 7, 16), periodEnd: Date.UTC(2026, 7, 30) },
    } as unknown,
    isLoading: false,
    subscriptionRequired: false,
  },
}));

vi.mock('expo-router', () => ({ router: { push: vi.fn(), replace: vi.fn() } }));
vi.mock('react-native', () => ({ ScrollView: 'ScrollView', View: 'View' }));
vi.mock('react-native-paper', async () => {
  const ReactModule = await import('react');
  const element = (type: string) => ({ children, ...props }: any) =>
    ReactModule.createElement(type, props, children);
  const Card = Object.assign(element('Card'), { Content: element('Card.Content') });
  return { Button: element('Button'), Card, Text: element('Text') };
});
vi.mock('../../lib/railway-hooks', () => ({
  useMutation: () => state.recordExport,
  useQuery: (ref: string) => (ref === 'getManagerInsights' ? state.insights : undefined),
  useQueryState: (ref: string) =>
    ref === 'getPayrollSummary'
      ? state.payroll
      : { data: undefined, isLoading: false, subscriptionRequired: false, error: null, refetch: vi.fn() },
}));
vi.mock('../../lib/railway-api', () => ({
  api: {
    app: { getManagerInsights: 'getManagerInsights', exportTimeEntriesCsv: 'exportTimeEntriesCsv' },
    scheduling: { getLaborForecast: 'getLaborForecast' },
    reservations: { exportReservationsCsv: 'exportReservationsCsv' },
    payroll: {
      getPayrollSummary: 'getPayrollSummary',
      exportPayrollCsv: 'exportPayrollCsv',
      recordPayrollExport: 'recordPayrollExport',
    },
  },
}));
vi.mock('../../lib/useVenueAuth', () => ({
  useVenueAuth: () => ({
    venue: { id: 'venue-1', name: 'The Fox & Vine' },
    isReady: true,
    profileLoading: false,
    profileError: null,
    refetchProfile: vi.fn(),
    canManage: true,
  }),
}));
vi.mock('../../lib/format', () => ({ errorMessage: (error: any, fallback: string) => error?.message ?? fallback }));
vi.mock('../../lib/theme', () => ({
  accents: Array.from({ length: 5 }, (_, i) => ({ bg: `#bg${i}`, fg: `#fg${i}`, icon: `#ic${i}` })),
  colors: { background: '#000', charcoal: '#222', danger: '#f00', muted: '#777', primary: '#0f0', surface: '#111' },
  radius: { sharp: 4 },
  spacing: { lg: 24, md: 16, sm: 8, xxl: 48 },
}));
vi.mock('../../lib/i18n', () => ({
  // Echo the key plus its interpolations so assertions can see both.
  useI18n: () => ({
    t: (key: string, vars?: Record<string, unknown>) =>
      vars ? `${key}(${Object.entries(vars).map(([k, v]) => `${k}=${String(v)}`).join('|')})` : key,
  }),
}));
vi.mock('../../components/ErrorBoundary', () => ({ ScreenErrorBoundary: ({ children }: any) => children }));
vi.mock('../../components/ManagerGate', () => ({ ManagerGate: ({ children }: any) => children }));
vi.mock('../../components/AppCard', () => ({ SectionHeader: () => null }));
vi.mock('../../components/DateRangeBar', () => ({
  DateRangeBar: () => null,
  useDateRange: () => ({
    selected: { shortLabel: 'Today' },
    setSelected: vi.fn(),
    presets: [],
  }),
}));
vi.mock('../../components/ProviderDropdown', () => ({ ProviderDropdown: () => null }));

import ReportsScreen from '../../app/(tabs)/reports';

function render() {
  const renderer = createRoot();
  return renderer;
}

function output(renderer: ReturnType<typeof createRoot>) {
  return JSON.stringify(renderer.container.toJSON());
}

function button(renderer: ReturnType<typeof createRoot>, label: string) {
  return renderer.container.queryAll((node) => node.type === 'Button')
    .find((node) => JSON.stringify(node.toJSON()).includes(label));
}

describe('Reports screen', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    state.payroll.isLoading = false;
    state.payroll.subscriptionRequired = false;
    state.payroll.data = {
      byEmployee: [
        { profileId: 'p1', employeeName: 'Renée Söderberg', role: 'server', jobTitle: 'Server', regularHours: 31.5, totalHours: 31.5 },
        { profileId: 'p2', employeeName: 'Marcus Delacroix', role: 'staff', jobTitle: 'Bartender', regularHours: 28, totalHours: 28 },
      ],
      totals: { totalHours: 59.5, employeeCount: 2, periodStart: Date.UTC(2026, 7, 16), periodEnd: Date.UTC(2026, 7, 30) },
    };
  });

  it('renders every manager KPI from the live response, not a zero fallback', async () => {
    const renderer = render();
    await act(async () => renderer.render(<ReportsScreen />));
    const json = output(renderer);

    // The KPI tiles are the only Text nodes whose whole content is a number.
    const tileValues = renderer.container
      .queryAll((node) => node.type === 'Text')
      .map((node) => node.toJSON() as any)
      .filter((node) => node.children?.length === 1 && /^\d+(\.\d+)?$/.test(String(node.children[0])))
      .map((node) => String(node.children[0]));

    // Every value the endpoint reported must actually appear. Before
    // getManagerInsights was extended, six of these rendered 0.
    expect(tileValues).toEqual(expect.arrayContaining(['24', '3', '7', '2', '15', '9', '4']));
    // And nothing may fall back to zero while the endpoint reports otherwise.
    expect(tileValues).not.toContain('0');
    expect(json).not.toContain('undefined');
  });

  it('renders the payroll summary from totals instead of undefined', async () => {
    const renderer = render();
    await act(async () => renderer.render(<ReportsScreen />));
    const json = output(renderer);

    expect(json).not.toContain('undefined');
    expect(json).toContain('hours=59.5');
    expect(json).toContain('count=2');
    // The period range comes from totals.periodStart/periodEnd; reading them
    // off the root left periodLabel null and the range invisible.
    expect(json).toMatch(/period=[^"]*Aug/);
  });

  it('labels the period from the venue-timezone ISO days the API resolved', async () => {
    // periodStart/periodEnd are epoch bounds that render in the device's
    // timezone, so a venue-midnight boundary can print the previous day. The
    // API also returns the ISO days it resolved; prefer those.
    state.payroll.data = {
      byEmployee: [],
      totals: {
        totalHours: 0,
        employeeCount: 0,
        // 2026-09-01T00:00 in a UTC+13 venue is still Aug 31 for a UTC reader.
        periodStart: Date.UTC(2026, 7, 31, 11, 0),
        periodEnd: Date.UTC(2026, 8, 30, 10, 59),
        startDate: '2026-09-01',
        endDate: '2026-09-30',
      },
    };
    const renderer = render();
    await act(async () => renderer.render(<ReportsScreen />));

    expect(output(renderer)).toMatch(/period=[^"]*Sep 1 – Sep 30/);
  });

  it('falls back to the epoch bounds when the API sends no ISO days', async () => {
    state.payroll.data = {
      byEmployee: [],
      totals: { totalHours: 0, employeeCount: 0, periodStart: Date.UTC(2026, 7, 16, 12), periodEnd: Date.UTC(2026, 7, 30, 12) },
    };
    const renderer = render();
    await act(async () => renderer.render(<ReportsScreen />));

    expect(output(renderer)).toMatch(/period=[^"]*Aug/);
  });

  it('sends ISO period strings so the export DTO accepts the request', async () => {
    state.recordExport.mockResolvedValueOnce({ id: 'export-1' });
    const renderer = render();
    await act(async () => renderer.render(<ReportsScreen />));

    await act(async () => button(renderer, 'reports.payroll.recordExport')?.props.onPress());

    expect(state.recordExport).toHaveBeenCalledTimes(1);
    const body = state.recordExport.mock.calls[0][0];
    expect(typeof body.periodStart).toBe('string');
    expect(typeof body.periodEnd).toBe('string');
    expect(body.periodStart).toBe(new Date(Date.UTC(2026, 7, 16)).toISOString());
    expect(body.periodEnd).toBe(new Date(Date.UTC(2026, 7, 30)).toISOString());
    expect(body).toMatchObject({ venueId: 'venue-1', provider: 'gusto', rowCount: 2, totalHours: 59.5 });
    expect(output(renderer)).toContain('reports.payroll.recordExportOk');
  });

  it('surfaces a failed export instead of swallowing the rejection', async () => {
    state.recordExport.mockRejectedValueOnce(new Error('periodStart must be a string'));
    const renderer = render();
    await act(async () => renderer.render(<ReportsScreen />));

    await act(async () => button(renderer, 'reports.payroll.recordExport')?.props.onPress());

    expect(output(renderer)).toContain('periodStart must be a string');
  });

  it('shows an upgrade prompt rather than a permanent spinner on 402', async () => {
    state.payroll.data = undefined;
    state.payroll.subscriptionRequired = true;
    const renderer = render();
    await act(async () => renderer.render(<ReportsScreen />));
    const json = output(renderer);

    expect(json).toContain('reports.payroll.upgradeRequired');
    expect(json).not.toContain('reports.payroll.loadingSummary');
    // With no summary there is no period to export, so the action is disabled
    // rather than firing a request that cannot succeed.
    expect(button(renderer, 'reports.payroll.recordExport')?.props.disabled).toBe(true);
  });

  it('still distinguishes a genuine load from the 402 case', async () => {
    state.payroll.data = undefined;
    state.payroll.isLoading = true;
    const renderer = render();
    await act(async () => renderer.render(<ReportsScreen />));

    expect(output(renderer)).toContain('reports.payroll.loadingSummary');
  });
});

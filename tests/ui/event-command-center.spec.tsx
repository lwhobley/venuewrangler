import React, { act } from 'react';
import { createRoot } from 'test-renderer';
import { beforeEach, describe, expect, it, vi } from 'vitest';

function workspace(overrides: Record<string, unknown> = {}) {
  return {
    workspaceId: 'ws1',
    event: { title: 'Smith Wedding', startsAt: Date.UTC(2026, 8, 10, 18), endsAt: null, expectedGuests: 80, space: 'Grand Hall', setupStyle: 'Banquet' },
    readiness: { score: 72, status: 'on-track', categories: { staffing: 80, floor: 60 } },
    blockers: [],
    tasks: [],
    staffing: { scheduled: 10, open: 1, covered: 9 },
    floor: { assigned: true, tableIds: ['t1'] },
    timeline: [],
    vendors: [],
    incidents: [],
    ...overrides,
  };
}

const state = vi.hoisted(() => ({
  params: { eventId: 'event-1' } as Record<string, string>,
  generateWorkspace: vi.fn(),
  workspaceQuery: { data: undefined as any, error: null as unknown, isLoading: false },
  updateTask: vi.fn(),
  updateTimeline: vi.fn(),
  updateVendor: vi.fn(),
  createIncident: vi.fn(),
  resolveIncident: vi.fn(),
  back: vi.fn(),
  push: vi.fn(),
}));

vi.mock('react-native', () => ({ ScrollView: 'ScrollView', View: 'View' }));
vi.mock('expo-router', () => ({ router: { back: state.back, push: state.push }, useLocalSearchParams: () => state.params }));
vi.mock('react-native-paper', async () => {
  const R = await import('react');
  const element = (type: string) => ({ children, ...props }: any) => R.createElement(type, props, children);
  return { Button: element('Button'), TextInput: element('TextInput') };
});
vi.mock('../../components/FutureUI', () => {
  const R = require('react');
  const el = (type: string) => ({ children, ...props }: any) => R.createElement(type, props, children);
  return { CommandButton: el('CommandButton'), CommandSurface: el('CommandSurface'), CommandText: el('CommandText'), StatusPill: el('StatusPill') };
});
vi.mock('../../lib/theme', () => ({
  colors: { surface: '#111' },
  spacing: { lg: 24, md: 16, sm: 8, xs: 4, xxl: 48 },
  useDesignTheme: () => ({ background: '#000', border: '#333', divider: '#333', muted: '#777', primary: '#0f0', surfaceSoft: '#191919', warning: '#fa0' }),
}));
vi.mock('../../lib/railway-api', () => ({
  api: {
    operations: {
      generateExecutionWorkspace: 'generateExecutionWorkspace', getCommandCenterEvent: 'getCommandCenterEvent',
      updateExecutionTask: 'updateExecutionTask', updateExecutionTimeline: 'updateExecutionTimeline',
      updateExecutionVendor: 'updateExecutionVendor', createExecutionIncident: 'createExecutionIncident',
      resolveExecutionIncident: 'resolveExecutionIncident',
    },
  },
}));
vi.mock('../../lib/railway-hooks', () => ({
  useQueryState: () => state.workspaceQuery,
  useMutation: (ref: string) => {
    if (ref === 'generateExecutionWorkspace') return state.generateWorkspace;
    if (ref === 'updateExecutionTask') return state.updateTask;
    if (ref === 'updateExecutionTimeline') return state.updateTimeline;
    if (ref === 'updateExecutionVendor') return state.updateVendor;
    if (ref === 'createExecutionIncident') return state.createIncident;
    if (ref === 'resolveExecutionIncident') return state.resolveIncident;
    return vi.fn();
  },
}));

import EventCommandCenterScreen from '../../app/event-command-center';

function render() {
  return createRoot();
}
function output(r: ReturnType<typeof createRoot>) {
  return JSON.stringify(r.container.toJSON());
}
function buttonByLabel(r: ReturnType<typeof createRoot>, label: string) {
  return r.container.queryAll((n) => n.type === 'Button' || n.type === 'CommandButton').find((n) => JSON.stringify(n.toJSON()).includes(label));
}

describe('Event command center screen', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    state.params = { eventId: 'event-1' };
    state.generateWorkspace.mockResolvedValue({ workspaceId: 'ws1' });
    state.workspaceQuery = { data: undefined, error: null, isLoading: false };
  });

  it('shows the loading state while the workspace is being prepared', async () => {
    state.generateWorkspace.mockImplementation(() => new Promise(() => {}));
    const r = render();
    await act(async () => r.render(<EventCommandCenterScreen />));
    expect(output(r)).toContain('Loading event workspace');
  });

  it('shows an error state and retries workspace generation', async () => {
    state.generateWorkspace.mockRejectedValueOnce(new Error('boom'));
    const r = render();
    await act(async () => r.render(<EventCommandCenterScreen />));
    expect(output(r)).toContain('Event workspace unavailable');

    state.generateWorkspace.mockResolvedValueOnce({ workspaceId: 'ws1' });
    state.workspaceQuery = { data: workspace(), error: null, isLoading: false };
    await act(async () => buttonByLabel(r, 'Try again')?.props.onPress());
    expect(output(r)).toContain('Smith Wedding');
  });

  it('completes a task and reopens it', async () => {
    state.workspaceQuery = { data: workspace({ tasks: [{ _id: 'task1', title: 'Set up linens', station: 'FOH', status: 'open', completedAt: null }] }), error: null, isLoading: false };
    state.updateTask.mockResolvedValue({});
    const r = render();
    await act(async () => r.render(<EventCommandCenterScreen />));
    await act(async () => buttonByLabel(r, 'Complete')?.props.onPress());
    expect(state.updateTask).toHaveBeenCalledWith({ taskId: 'task1', status: 'done' });
  });

  it('marks a vendor arrived', async () => {
    state.workspaceQuery = { data: workspace({ vendors: [{ _id: 'v1', name: 'Ice Co.', status: 'unconfirmed', dueAt: null }] }), error: null, isLoading: false };
    state.updateVendor.mockResolvedValue({});
    const r = render();
    await act(async () => r.render(<EventCommandCenterScreen />));
    await act(async () => buttonByLabel(r, 'Mark arrived')?.props.onPress());
    expect(state.updateVendor).toHaveBeenCalledWith({ vendorId: 'v1', status: 'arrived' });
  });

  it('logs a blocking incident and clears the composer', async () => {
    state.workspaceQuery = { data: workspace(), error: null, isLoading: false };
    state.createIncident.mockResolvedValueOnce({});
    const r = render();
    await act(async () => r.render(<EventCommandCenterScreen />));
    const input = r.container.queryAll((n) => n.type === 'TextInput')[0];
    await act(async () => input?.props.onChangeText('Power outage in kitchen'));
    await act(async () => buttonByLabel(r, 'Log blocking incident')?.props.onPress());
    expect(state.createIncident).toHaveBeenCalledWith({ eventId: 'event-1', title: 'Power outage in kitchen', severity: 'high', blocksReadiness: true });
    expect(input?.props.value).toBe('');
  });

  it('does not log a blank incident', async () => {
    state.workspaceQuery = { data: workspace(), error: null, isLoading: false };
    const r = render();
    await act(async () => r.render(<EventCommandCenterScreen />));
    expect(buttonByLabel(r, 'Log blocking incident')?.props.disabled).toBe(true);
  });

  it('routes to the schedule from an open-shift blocker', async () => {
    state.workspaceQuery = {
      data: workspace({ blockers: [{ code: 'OPEN_SHIFT', title: 'Unfilled server shift', detail: 'One shift still open.' }] }),
      error: null, isLoading: false,
    };
    const r = render();
    await act(async () => r.render(<EventCommandCenterScreen />));
    await act(async () => buttonByLabel(r, 'Open schedule')?.props.onPress());
    expect(state.push).toHaveBeenCalledWith('/(tabs)/schedule');
  });

  it('surfaces a failed action instead of leaving it silently stuck', async () => {
    state.workspaceQuery = { data: workspace({ tasks: [{ _id: 'task1', title: 'Set up linens', station: null, status: 'open', completedAt: null }] }), error: null, isLoading: false };
    state.updateTask.mockRejectedValueOnce(new Error('Task already completed'));
    const r = render();
    await act(async () => r.render(<EventCommandCenterScreen />));
    await act(async () => buttonByLabel(r, 'Complete')?.props.onPress());
    expect(output(r)).toContain('Task already completed');
  });
});

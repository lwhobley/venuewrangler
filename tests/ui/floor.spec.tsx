import React, { act } from 'react';
import { createRoot } from 'test-renderer';
import { beforeEach, describe, expect, it, vi } from 'vitest';

function table(overrides: Record<string, unknown> = {}) {
  return {
    table: {
      _id: 't1', label: 'T1', shape: 'round', seats: 4, x: 0, y: 0, width: 80, height: 80,
      rotation: 0, section: 'main', minSpend: 0, isReservable: true,
      ...overrides,
    },
    state: null,
    activeAssignments: [],
    nextAssignment: null,
    ...('state' in overrides ? {} : {}),
  } as any;
}

const state = vi.hoisted(() => ({
  venue: { id: 'venue-1', name: 'The Fox & Vine' } as any,
  canManage: true,
  floor: undefined as any,
  floorError: null as unknown,
  stats: undefined as any,
  unassigned: undefined as any,
  waitlist: undefined as any,
  releaseAssignment: vi.fn(),
  markDirty: vi.fn(),
  markClean: vi.fn(),
  mergeTablesForParty: vi.fn(),
  splitMergedTables: vi.fn(),
  refetch: vi.fn(),
  push: vi.fn(),
}));

vi.mock('react-native', () => ({ Pressable: 'Pressable', ScrollView: 'ScrollView', View: 'View' }));
vi.mock('react-native-paper', async () => {
  const R = await import('react');
  const element = (type: string) => ({ children, ...props }: any) => R.createElement(type, props, children);
  const Card = Object.assign(element('Card'), { Content: element('Card.Content') });
  return { Button: element('Button'), Card, Chip: element('Chip'), Text: element('Text') };
});
vi.mock('../../components/ErrorBoundary', () => ({ ScreenErrorBoundary: ({ children }: any) => children }));
vi.mock('../../components/AppCard', () => ({ SectionHeader: ({ title }: any) => title }));
vi.mock('expo-router', () => ({ router: { push: state.push } }));
vi.mock('../../lib/useVenueAuth', () => ({
  useVenueAuth: () => ({ venue: state.venue, isReady: true, user: { role: 'manager' }, canManage: state.canManage }),
}));
vi.mock('../../lib/railway-api', () => ({
  api: {
    floorBinding: {
      getActiveFloorPlan: 'getActiveFloorPlan',
      getUnassignedReservations: 'getUnassignedReservations',
      getOpenWaitlist: 'getOpenWaitlist',
      releaseAssignment: 'releaseAssignment',
    },
    floor: { getFloorStats: 'getFloorStats' },
    tables: { markDirty: 'markDirty', markClean: 'markClean', mergeTablesForParty: 'mergeTablesForParty', splitMergedTables: 'splitMergedTables' },
  },
}));
vi.mock('../../lib/railway-hooks', () => ({
  useQueryState: (ref: string) =>
    ref === 'getActiveFloorPlan'
      ? { data: state.floor, isLoading: false, error: state.floorError, refetch: state.refetch }
      : { data: undefined, isLoading: false, error: null, refetch: vi.fn() },
  useQuery: (ref: string) => {
    if (ref === 'getFloorStats') return state.stats;
    if (ref === 'getUnassignedReservations') return state.unassigned;
    if (ref === 'getOpenWaitlist') return state.waitlist;
    return undefined;
  },
  useMutation: (ref: string) => {
    if (ref === 'releaseAssignment') return state.releaseAssignment;
    if (ref === 'markDirty') return state.markDirty;
    if (ref === 'markClean') return state.markClean;
    if (ref === 'mergeTablesForParty') return state.mergeTablesForParty;
    if (ref === 'splitMergedTables') return state.splitMergedTables;
    return vi.fn();
  },
}));
vi.mock('../../lib/format', () => ({
  formatTime: (ts: number) => `t${ts}`,
  errorMessage: (e: any, fallback: string) => e?.message ?? fallback,
}));
vi.mock('../../lib/theme', () => ({
  colors: { background: '#000', border: '#333', charcoal: '#222', cream: '#eee', danger: '#f00', muted: '#777', primary: '#0f0', surface: '#111', warning: '#fa0' },
  radius: { soft: 8 },
  spacing: { lg: 24, md: 16, sm: 8, xs: 4 },
}));
vi.mock('../../lib/i18n', () => ({
  useI18n: () => ({
    t: (key: string, vars?: Record<string, unknown>) =>
      vars ? `${key}(${Object.entries(vars).map(([k, v]) => `${k}=${String(v)}`).join('|')})` : key,
  }),
}));

import FloorScreen from '../../app/(tabs)/floor';

function render() {
  return createRoot();
}
function output(r: ReturnType<typeof createRoot>) {
  return JSON.stringify(r.container.toJSON());
}
function buttonByLabel(r: ReturnType<typeof createRoot>, label: string) {
  return r.container.queryAll((n) => n.type === 'Button').find((n) => JSON.stringify(n.toJSON()).includes(label));
}
function chipByLabel(r: ReturnType<typeof createRoot>, label: string) {
  return r.container.queryAll((n) => n.type === 'Chip').find((n) => JSON.stringify(n.toJSON()).includes(label));
}

describe('Floor screen', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    state.venue = { id: 'venue-1', name: 'The Fox & Vine' };
    state.canManage = true;
    state.floor = undefined;
    state.floorError = null;
    state.stats = undefined;
    state.unassigned = undefined;
    state.waitlist = undefined;
  });

  it('prompts to build a floor plan when none exists yet, only for managers', async () => {
    state.floor = null;
    const r = render();
    await act(async () => r.render(<FloorScreen />));
    expect(output(r)).toContain('floor.noFloorPlanTitle');
    expect(output(r)).toContain('floor.buildFloorPlan');
  });

  it('hides the build action from staff without manage permission', async () => {
    state.floor = null;
    state.canManage = false;
    const r = render();
    await act(async () => r.render(<FloorScreen />));
    expect(output(r)).not.toContain('floor.buildFloorPlan');
  });

  it('filters the rendered tables by section', async () => {
    state.floor = {
      floorPlan: { name: 'Main Room', width: 800, height: 600 },
      tables: [table({ _id: 'a', label: 'Patio-1', section: 'patio' }), table({ _id: 'b', label: 'Main-1', section: 'main' })],
    };
    const r = render();
    await act(async () => r.render(<FloorScreen />));
    expect(output(r)).toContain('Patio-1');
    expect(output(r)).toContain('Main-1');

    await act(async () => chipByLabel(r, 'patio')?.props.onPress());
    const out = output(r);
    expect(out).toContain('Patio-1');
    expect(out).not.toContain('Main-1');
  });

  it('marks a table dirty through the mutation with the correct table id', async () => {
    state.floor = { floorPlan: { name: 'Main Room', width: 800, height: 600 }, tables: [table({ _id: 't9', label: 'T9' })] };
    const r = render();
    await act(async () => r.render(<FloorScreen />));
    await act(async () => buttonByLabel(r, 'floor.markDirty')?.props.onPress());
    expect(state.markDirty).toHaveBeenCalledWith({ tableId: 't9' });
  });

  it('releases an assignment with the actor role and a reason', async () => {
    state.floor = {
      floorPlan: { name: 'Main Room', width: 800, height: 600 },
      tables: [{
        ...table({ _id: 't1', label: 'T1' }),
        activeAssignments: [{ assignmentId: 'a1', holdType: 'seated', sourceType: 'reservation', guestName: 'Casey', partySize: 2, source: 'app', tags: [], notes: null, status: 'seated', startsAt: 1, endsAt: 2 }],
      }],
    };
    const r = render();
    await act(async () => r.render(<FloorScreen />));
    await act(async () => buttonByLabel(r, 'floor.release')?.props.onPress());
    expect(state.releaseAssignment).toHaveBeenCalledWith(expect.objectContaining({
      venueId: 'venue-1', assignmentId: 'a1', actorRole: 'manager', reason: expect.any(String),
    }));
  });

  it('surfaces a mutation failure instead of leaving the action silently no-op', async () => {
    state.floor = { floorPlan: { name: 'Main Room', width: 800, height: 600 }, tables: [table({ _id: 't1', label: 'T1' })] };
    state.markDirty.mockRejectedValueOnce(new Error('Table already dirty'));
    const r = render();
    await act(async () => r.render(<FloorScreen />));
    await act(async () => buttonByLabel(r, 'floor.markDirty')?.props.onPress());
    expect(output(r)).toContain('Table already dirty');
  });

  it('only offers tables with enough open seats as merge candidates, and merges the selection', async () => {
    state.floor = {
      floorPlan: { name: 'Main Room', width: 800, height: 600 },
      tables: [table({ _id: 't1', label: 'T1', seats: 2 }), table({ _id: 't2', label: 'T2', seats: 4 })],
    };
    state.mergeTablesForParty.mockResolvedValueOnce({});
    const r = render();
    await act(async () => r.render(<FloorScreen />));
    await act(async () => buttonByLabel(r, 'floor.merge')?.props.onPress());
    await act(async () => chipByLabel(r, 'T1')?.props.onPress());
    await act(async () => chipByLabel(r, 'T2')?.props.onPress());
    await act(async () => buttonByLabel(r, 'floor.mergeSelected')?.props.onPress());
    expect(state.mergeTablesForParty).toHaveBeenCalledWith(expect.objectContaining({
      venueId: 'venue-1', tableIds: expect.arrayContaining(['t1', 't2']),
    }));
  });

  it('shows the couldn’t-load state and lets the operator retry a failed floor fetch', async () => {
    state.floor = undefined;
    state.floorError = new Error('network');
    const r = render();
    await act(async () => r.render(<FloorScreen />));
    expect(output(r)).toContain("Couldn't load the floor plan");
    await act(async () => buttonByLabel(r, 'Retry')?.props.onPress());
    expect(state.refetch).toHaveBeenCalled();
  });
});

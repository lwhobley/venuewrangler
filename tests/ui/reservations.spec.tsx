import React, { act } from 'react';
import { createRoot } from 'test-renderer';
import { beforeEach, describe, expect, it, vi } from 'vitest';

function reservation(overrides: Record<string, unknown> = {}) {
  return {
    id: 'r1', guestName: 'Casey Nguyen', partySize: 2, reservationTime: Date.now() + 3600_000,
    durationMinutes: 90, source: 'direct', status: 'confirmed', tags: [], specialRequests: null, notes: null,
    ...overrides,
  };
}

const state = vi.hoisted(() => ({
  venue: { id: 'venue-1', name: 'The Fox & Vine', timezone: 'America/New_York' } as any,
  me: { profile: { role: 'manager', allAccess: true }, venue: { timezone: 'America/New_York' } } as any,
  page: undefined as any,
  pageError: null as unknown,
  floor: undefined as any,
  waitlist: undefined as any,
  unassigned: undefined as any,
  holds: undefined as any,
  saveReservation: vi.fn(),
  removeReservation: vi.fn(),
  createHold: vi.fn(),
  addToWaitlist: vi.fn(),
  push: vi.fn(),
  refetch: vi.fn(),
}));

vi.mock('react-native', () => ({
  View: 'View',
  FlatList: ({ ListHeaderComponent, data, renderItem, keyExtractor }: any) =>
    React.createElement(
      React.Fragment,
      null,
      ListHeaderComponent,
      ...(data ?? []).map((item: any, index: number) =>
        React.createElement(React.Fragment, { key: keyExtractor ? keyExtractor(item) : index }, renderItem({ item, index }))),
    ),
}));
vi.mock('react-native-paper', async () => {
  const R = await import('react');
  const element = (type: string) => ({ children, ...props }: any) => R.createElement(type, props, children);
  const Card = Object.assign(element('Card'), { Content: element('Card.Content') });
  return {
    Button: element('Button'), Card, Chip: element('Chip'), IconButton: element('IconButton'),
    Menu: Object.assign(element('Menu'), { Item: element('Menu.Item') }), Text: element('Text'), TextInput: element('TextInput'),
  };
});
vi.mock('../../components/ErrorBoundary', () => ({ ScreenErrorBoundary: ({ children }: any) => children }));
vi.mock('../../components/AppCard', () => ({ AppCard: ({ children }: any) => children, SectionHeader: ({ title }: any) => title }));
vi.mock('../../components/DateRangeBar', () => ({
  DateRangeBar: () => null,
  useDateRange: () => ({
    selected: { shortLabel: 'Today', startTs: 0, endTs: Date.now() + 365 * 24 * 3600_000 },
    setSelected: vi.fn(),
    presets: [],
  }),
}));
vi.mock('expo-router', () => ({ router: { push: state.push } }));
vi.mock('../../lib/auth-store', () => ({ useAuthStore: (select: (s: any) => unknown) => select({ venue: state.venue }) }));
vi.mock('../../lib/auth-readiness', () => ({ useAuthenticatedSession: () => ({ isReady: true }) }));
vi.mock('../../lib/railway-api', () => ({
  api: {
    app: { getMe: 'getMe' },
    reservations: {
      getReservationsPage: 'getReservationsPage', listHolds: 'listHolds', saveReservation: 'saveReservation',
      removeReservation: 'removeReservation', createHold: 'createHold', deleteHold: 'deleteHold',
      getCoverPacing: 'getCoverPacing', guestAutofill: 'guestAutofill',
    },
    floorBinding: {
      getActiveFloorPlan: 'getActiveFloorPlan', getOpenWaitlist: 'getOpenWaitlist', getUnassignedReservations: 'getUnassignedReservations',
      assignReservationToTables: 'assignReservationToTables', addToWaitlist: 'addToWaitlist', markWaitlistReady: 'markWaitlistReady',
      removeFromWaitlist: 'removeFromWaitlist', assignWaitlistToTables: 'assignWaitlistToTables',
    },
  },
}));
vi.mock('../../lib/railway-hooks', () => ({
  useQuery: (ref: string) => {
    if (ref === 'getMe') return state.me;
    if (ref === 'getActiveFloorPlan') return state.floor;
    if (ref === 'getOpenWaitlist') return state.waitlist;
    if (ref === 'getUnassignedReservations') return state.unassigned;
    if (ref === 'listHolds') return state.holds;
    return undefined;
  },
  useQueryState: (ref: string) =>
    ref === 'getReservationsPage'
      ? { data: state.page, error: state.pageError, isLoading: false, refetch: state.refetch }
      : { data: undefined, error: null, isLoading: false, refetch: vi.fn() },
  useMutation: (ref: string) => {
    if (ref === 'saveReservation') return state.saveReservation;
    if (ref === 'removeReservation') return state.removeReservation;
    if (ref === 'createHold') return state.createHold;
    if (ref === 'addToWaitlist') return state.addToWaitlist;
    return vi.fn();
  },
}));
vi.mock('../../lib/theme', () => ({
  accents: Array.from({ length: 6 }, (_, i) => ({ bg: `#bg${i}`, fg: `#fg${i}`, icon: `#ic${i}` })),
  colors: { background: '#000', border: '#333', charcoal: '#222', cream: '#eee', danger: '#f00', muted: '#777', primary: '#0f0', surface: '#111', warning: '#fa0' },
  spacing: { lg: 24, md: 16, sm: 8, xs: 4, xxl: 48 },
  radius: { sharp: 4 },
  type: { title: {}, heading: {} },
}));
vi.mock('../../lib/i18n', () => ({
  useI18n: () => ({
    t: (key: string, vars?: Record<string, unknown>) =>
      vars ? `${key}(${Object.entries(vars).map(([k, v]) => `${k}=${String(v)}`).join('|')})` : key,
  }),
}));

import ReservationsScreen from '../../app/reservations';

function render() {
  return createRoot();
}
function output(r: ReturnType<typeof createRoot>) {
  // Menu's `anchor` prop carries a raw (unrendered) React element, which has
  // a circular `_owner` fiber reference, even while the menu is closed.
  return JSON.stringify(r.container.toJSON(), (key, value) => (key === 'anchor' ? '[Anchor]' : value));
}
function buttonByLabel(r: ReturnType<typeof createRoot>, label: string) {
  return r.container.queryAll((n) => n.type === 'Button').find((n) => JSON.stringify(n.toJSON()).includes(label));
}
function inputByLabel(r: ReturnType<typeof createRoot>, label: string) {
  return r.container.queryAll((n) => n.type === 'TextInput').find((n) => n.props.label === label);
}

describe('Reservations screen', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    state.venue = { id: 'venue-1', name: 'The Fox & Vine', timezone: 'America/New_York' };
    state.me = { profile: { role: 'manager', allAccess: true }, venue: { timezone: 'America/New_York' } };
    state.page = { reservations: [] };
    state.pageError = null;
    state.floor = { tables: [] };
    state.waitlist = [];
    state.unassigned = [];
    state.holds = [];
  });

  it('blocks reservation creation without a first and last name', async () => {
    const r = render();
    await act(async () => r.render(<ReservationsScreen />));
    await act(async () => buttonByLabel(r, 'reservations.form.addButton')?.props.onPress());
    await act(async () => buttonByLabel(r, 'reservations.form.createButton')?.props.onPress());
    expect(state.saveReservation).not.toHaveBeenCalled();
    expect(output(r)).toContain('reservations.form.errors.nameRequired');
  });

  it('creates a reservation with the trimmed full name and confirmed status, then resets the form', async () => {
    state.saveReservation.mockResolvedValueOnce({ id: 'new-1' });
    const r = render();
    await act(async () => r.render(<ReservationsScreen />));
    await act(async () => buttonByLabel(r, 'reservations.form.addButton')?.props.onPress());
    await act(async () => {
      inputByLabel(r, 'reservations.form.firstName')?.props.onChangeText('  Casey ');
      inputByLabel(r, 'reservations.form.lastName')?.props.onChangeText(' Nguyen ');
    });
    await act(async () => buttonByLabel(r, 'reservations.form.createButton')?.props.onPress());

    expect(state.saveReservation).toHaveBeenCalledWith(expect.objectContaining({
      venueId: 'venue-1', guestName: 'Casey Nguyen', status: 'confirmed', partySize: 2, isPrivateEvent: false,
    }));
    // A successful save closes the form; reopening it must show a blank
    // slate rather than the guest just booked.
    await act(async () => buttonByLabel(r, 'reservations.form.addButton')?.props.onPress());
    expect(inputByLabel(r, 'reservations.form.firstName')?.props.value).toBe('');
  });

  it('surfaces a failed reservation save rather than silently resetting the form', async () => {
    state.saveReservation.mockRejectedValueOnce(new Error('Table conflict'));
    const r = render();
    await act(async () => r.render(<ReservationsScreen />));
    await act(async () => buttonByLabel(r, 'reservations.form.addButton')?.props.onPress());
    await act(async () => {
      inputByLabel(r, 'reservations.form.firstName')?.props.onChangeText('Casey');
      inputByLabel(r, 'reservations.form.lastName')?.props.onChangeText('Nguyen');
    });
    await act(async () => buttonByLabel(r, 'reservations.form.createButton')?.props.onPress());
    expect(output(r)).toContain('Table conflict');
    expect(inputByLabel(r, 'reservations.form.firstName')?.props.value).toBe('Casey');
  });

  it('deletes a reservation by id for the active venue', async () => {
    state.page = { reservations: [reservation()] };
    state.removeReservation.mockResolvedValueOnce({});
    const r = render();
    await act(async () => r.render(<ReservationsScreen />));
    await act(async () => buttonByLabel(r, 'reservations.item.deleteButton')?.props.onPress());
    expect(state.removeReservation).toHaveBeenCalledWith({ venueId: 'venue-1', reservationId: 'r1' });
  });

  it('hides manage actions from staff without manage permission', async () => {
    state.me = { profile: { role: 'staff', allAccess: false }, venue: { timezone: 'America/New_York' } };
    state.page = { reservations: [reservation()] };
    const r = render();
    await act(async () => r.render(<ReservationsScreen />));
    expect(output(r)).not.toContain('reservations.item.deleteButton');
  });

  it('filters the visible list to large parties only', async () => {
    state.page = { reservations: [reservation({ id: 'small', guestName: 'Small Party', partySize: 2 }), reservation({ id: 'big', guestName: 'Big Party', partySize: 10 })] };
    const r = render();
    await act(async () => r.render(<ReservationsScreen />));
    expect(output(r)).toContain('Small Party');
    expect(output(r)).toContain('Big Party');

    const largeChip = r.container.queryAll((n) => n.type === 'Chip').find((n) => JSON.stringify(n.toJSON()).includes('Large party'));
    await act(async () => largeChip?.props.onPress());
    const out = output(r);
    expect(out).toContain('reservations.item.partyOf(name=Big Party|size=10)');
    expect(out).not.toContain('reservations.item.partyOf(name=Small Party|size=2)');
  });

  it('adds a walk-in to the waitlist and clears the form', async () => {
    state.addToWaitlist.mockResolvedValueOnce({});
    const r = render();
    await act(async () => r.render(<ReservationsScreen />));
    await act(async () => inputByLabel(r, 'reservations.waitlist.nameLabel')?.props.onChangeText('Jordan Lee'));
    await act(async () => buttonByLabel(r, 'reservations.waitlist.addButton')?.props.onPress());
    expect(state.addToWaitlist).toHaveBeenCalledWith(expect.objectContaining({ venueId: 'venue-1', guestName: 'Jordan Lee', partySize: 2 }));
    expect(inputByLabel(r, 'reservations.waitlist.nameLabel')?.props.value).toBe('');
  });

  it('does not add a blank walk-in name to the waitlist', async () => {
    const r = render();
    await act(async () => r.render(<ReservationsScreen />));
    await act(async () => buttonByLabel(r, 'reservations.waitlist.addButton')?.props.onPress());
    expect(state.addToWaitlist).not.toHaveBeenCalled();
  });
});

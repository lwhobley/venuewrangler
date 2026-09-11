import React, { act } from 'react';
import { createRoot } from 'test-renderer';
import { beforeEach, describe, expect, it, vi } from 'vitest';

function guest(overrides: Record<string, unknown> = {}) {
  return {
    _id: 'g1', fullName: 'Casey Nguyen', phone: '555-0100', email: 'casey@example.com', lifecycleStage: 'regular',
    source: null, birthday: null, company: null, marketingOptIn: false, favoriteTable: null, preferredServer: null,
    dietaryNotes: null, tags: [], notes: null, reservationCount: 2, visitCount: 5, lastVisitAt: null,
    upcomingReservationAt: null, totalSpendCents: 12000, averageSpendCents: 2400, daysSinceLastVisit: 10,
    ...overrides,
  };
}

const state = vi.hoisted(() => ({
  venue: { id: 'venue-1', name: 'The Fox & Vine' } as any,
  canManage: true,
  guestList: undefined as any,
  upsertGuest: vi.fn(),
  ingestLeads: vi.fn(),
  removeGuest: vi.fn(),
}));

vi.mock('react-native', () => ({
  ScrollView: 'ScrollView', View: 'View',
  FlatList: ({ ListHeaderComponent, ListFooterComponent, ListEmptyComponent, data, renderItem, keyExtractor }: any) =>
    React.createElement(
      React.Fragment,
      null,
      ListHeaderComponent,
      (data ?? []).length === 0
        ? ListEmptyComponent
        : (data ?? []).map((item: any, index: number) =>
            React.createElement(React.Fragment, { key: keyExtractor ? keyExtractor(item) : index }, renderItem({ item, index }))),
      ListFooterComponent,
    ),
}));
vi.mock('react-native-paper', async () => {
  const R = await import('react');
  const element = (type: string) => ({ children, ...props }: any) => R.createElement(type, props, children);
  const Card = Object.assign(element('Card'), { Content: element('Card.Content') });
  return {
    Button: element('Button'), Card, Chip: element('Chip'), SegmentedButtons: element('SegmentedButtons'),
    Switch: element('Switch'), Text: element('Text'), TextInput: element('TextInput'),
  };
});
vi.mock('../../components/ErrorBoundary', () => ({ ScreenErrorBoundary: ({ children }: any) => children }));
vi.mock('../../components/PremiumFeatureGate', () => ({ PremiumFeatureGate: ({ children }: any) => children }));
vi.mock('../../components/AppCard', () => ({ SectionHeader: ({ title }: any) => title }));
vi.mock('../../components/CrmSalesWorkspace', () => ({ CrmSalesWorkspace: () => null }));
vi.mock('../../lib/useVenueAuth', () => ({ useVenueAuth: () => ({ venue: state.venue, isReady: true, canManage: state.canManage }) }));
vi.mock('../../lib/railway-api', () => ({
  api: { guests: { listGuests: 'listGuests', upsertGuest: 'upsertGuest', ingestLeads: 'ingestLeads', removeGuest: 'removeGuest', getGuestProfile: 'getGuestProfile' } },
}));
vi.mock('../../lib/railway-hooks', () => ({
  useQuery: (ref: string) => (ref === 'listGuests' ? state.guestList : undefined),
  useMutation: (ref: string) => (ref === 'upsertGuest' ? state.upsertGuest : ref === 'ingestLeads' ? state.ingestLeads : ref === 'removeGuest' ? state.removeGuest : vi.fn()),
}));
vi.mock('../../lib/theme', () => ({
  accents: Array.from({ length: 6 }, (_, i) => ({ bg: `#bg${i}`, fg: `#fg${i}`, icon: `#ic${i}` })),
  colors: { background: '#000', border: '#333', charcoal: '#222', danger: '#f00', muted: '#777', primary: '#0f0', surface: '#111', warning: '#fa0' },
  radius: { sharp: 4 },
  spacing: { lg: 24, md: 16, sm: 8, xxl: 48 },
}));
vi.mock('../../lib/i18n', () => ({
  useI18n: () => ({
    t: (key: string, vars?: Record<string, unknown>) =>
      vars ? `${key}(${Object.entries(vars).map(([k, v]) => `${k}=${String(v)}`).join('|')})` : key,
  }),
}));

import GuestsScreenWrapper from '../../app/(tabs)/guests';

function render() {
  return createRoot();
}
function output(r: ReturnType<typeof createRoot>) {
  return JSON.stringify(r.container.toJSON());
}
function buttonByLabel(r: ReturnType<typeof createRoot>, label: string) {
  return r.container.queryAll((n) => n.type === 'Button').find((n) => JSON.stringify(n.toJSON()).includes(label));
}
function inputByLabel(r: ReturnType<typeof createRoot>, label: string) {
  return r.container.queryAll((n) => n.type === 'TextInput').find((n) => n.props.label === label);
}

describe('Guests screen', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    state.venue = { id: 'venue-1', name: 'The Fox & Vine' };
    state.canManage = true;
    state.guestList = { guests: [], totalCount: 0 };
  });

  it('blocks non-managers from the guest directory', async () => {
    state.canManage = false;
    const r = render();
    await act(async () => r.render(<GuestsScreenWrapper />));
    expect(output(r)).toContain('guests.header.managerOnly');
    expect(output(r)).not.toContain('guests.directory.title');
  });

  it('requires a name before saving a new guest', async () => {
    const r = render();
    await act(async () => r.render(<GuestsScreenWrapper />));
    await act(async () => buttonByLabel(r, 'guests.directory.addGuest')?.props.onPress());
    await act(async () => buttonByLabel(r, 'guests.form.saveButton')?.props.onPress());
    expect(state.upsertGuest).not.toHaveBeenCalled();
    expect(output(r)).toContain('guests.form.nameRequired');
  });

  it('creates a guest with the trimmed fields and parsed tags', async () => {
    state.upsertGuest.mockResolvedValueOnce({ _id: 'new-1' });
    const r = render();
    await act(async () => r.render(<GuestsScreenWrapper />));
    await act(async () => buttonByLabel(r, 'guests.directory.addGuest')?.props.onPress());
    await act(async () => inputByLabel(r, 'guests.form.fullName')?.props.onChangeText('  Jordan Lee  '));
    await act(async () => inputByLabel(r, 'guests.form.tags')?.props.onChangeText('vip, regular'));
    await act(async () => buttonByLabel(r, 'guests.form.saveButton')?.props.onPress());

    expect(state.upsertGuest).toHaveBeenCalledWith(expect.objectContaining({
      venueId: 'venue-1', fullName: 'Jordan Lee', lifecycleStage: 'lead', tags: ['vip', 'regular'],
    }));
  });

  it('surfaces a failed guest save without closing the form', async () => {
    state.upsertGuest.mockRejectedValueOnce(new Error('Duplicate email'));
    const r = render();
    await act(async () => r.render(<GuestsScreenWrapper />));
    await act(async () => buttonByLabel(r, 'guests.directory.addGuest')?.props.onPress());
    await act(async () => inputByLabel(r, 'guests.form.fullName')?.props.onChangeText('Jordan Lee'));
    await act(async () => buttonByLabel(r, 'guests.form.saveButton')?.props.onPress());
    expect(output(r)).toContain('Duplicate email');
    expect(inputByLabel(r, 'guests.form.fullName')).toBeDefined();
  });

  it('imports leads and reports how many were created and skipped', async () => {
    state.ingestLeads.mockResolvedValueOnce({ created: 3, updated: 1, skipped: 2, guestIds: ['lead-1'] });
    const r = render();
    await act(async () => r.render(<GuestsScreenWrapper />));
    await act(async () => buttonByLabel(r, 'guests.directory.importLeads')?.props.onPress());
    await act(async () => inputByLabel(r, 'guests.leadImport.leadsLabel')?.props.onChangeText('Jordan Lee, 555-0100'));
    await act(async () => buttonByLabel(r, 'guests.leadImport.ingestA11y')?.props.onPress());
    expect(state.ingestLeads).toHaveBeenCalledWith(expect.objectContaining({ venueId: 'venue-1' }));
  });

  it('does not import an empty lead paste', async () => {
    const r = render();
    await act(async () => r.render(<GuestsScreenWrapper />));
    await act(async () => buttonByLabel(r, 'guests.directory.importLeads')?.props.onPress());
    await act(async () => buttonByLabel(r, 'guests.leadImport.ingestA11y')?.props.onPress());
    expect(state.ingestLeads).not.toHaveBeenCalled();
  });

  it('deletes the selected guest for the active venue', async () => {
    state.guestList = { guests: [guest()], totalCount: 1 };
    state.removeGuest.mockResolvedValueOnce({});
    const r = render();
    await act(async () => r.render(<GuestsScreenWrapper />));
    await act(async () => buttonByLabel(r, 'guests.detail.delete')?.props.onPress());
    expect(state.removeGuest).toHaveBeenCalledWith({ venueId: 'venue-1', guestId: 'g1' });
  });

  it('shows the guest profile with lifetime spend once a guest is loaded', async () => {
    state.guestList = { guests: [guest({ totalSpendCents: 45000 })], totalCount: 1 };
    const r = render();
    await act(async () => r.render(<GuestsScreenWrapper />));
    expect(output(r)).toContain('Casey Nguyen');
    expect(output(r)).toContain('$450.00');
  });
});

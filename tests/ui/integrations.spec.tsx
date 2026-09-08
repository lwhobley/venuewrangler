import React, { act } from 'react';
import { createRoot } from 'test-renderer';
import { beforeEach, describe, expect, it, vi } from 'vitest';

const state = vi.hoisted(() => ({
  venue: { id: 'venue-1', name: 'The Fox & Vine' } as any,
  canManage: true,
  profileLoading: false,
  profileError: null as unknown,
  overview: undefined as any,
  reservationOverview: undefined as any,
  upsertConnection: vi.fn(),
  rotatePosSecret: vi.fn(),
  upsertReservationConnection: vi.fn(),
  rotateLeadsSecret: vi.fn(),
}));

vi.mock('react-native', () => ({ ScrollView: 'ScrollView', View: 'View' }));
vi.mock('react-native-paper', async () => {
  const R = await import('react');
  const element = (type: string) => ({ children, ...props }: any) => R.createElement(type, props, children);
  const Card = Object.assign(element('Card'), { Content: element('Card.Content') });
  return { Button: element('Button'), Card, Text: element('Text'), TextInput: element('TextInput') };
});
vi.mock('../../lib/railway-hooks', () => ({
  useQuery: (ref: string) => (ref === 'getPosOverview' ? state.overview : ref === 'getReservationIntegrationOverview' ? state.reservationOverview : undefined),
  useMutation: (ref: string) => {
    if (ref === 'upsertPosConnection') return state.upsertConnection;
    if (ref === 'rotatePosConnectionSecret') return state.rotatePosSecret;
    if (ref === 'upsertReservationConnection') return state.upsertReservationConnection;
    if (ref === 'rotateLeadsWebhookSecret') return state.rotateLeadsSecret;
    return vi.fn();
  },
}));
vi.mock('../../lib/railway-api', () => ({
  api: {
    pos: { getPosOverview: 'getPosOverview', upsertPosConnection: 'upsertPosConnection', rotatePosConnectionSecret: 'rotatePosConnectionSecret' },
    reservationIntegrations: { getReservationIntegrationOverview: 'getReservationIntegrationOverview', upsertReservationConnection: 'upsertReservationConnection' },
    guests: { rotateLeadsWebhookSecret: 'rotateLeadsWebhookSecret' },
  },
}));
vi.mock('../../lib/theme', () => ({
  accents: Array.from({ length: 6 }, (_, i) => ({ bg: `#bg${i}`, fg: `#fg${i}`, icon: `#ic${i}` })),
  colors: { background: '#000', border: '#333', charcoal: '#222', muted: '#777', primary: '#0f0', surface: '#111', surfaceSoft: '#191919', warning: '#fa0' },
  radius: { sharp: 4 },
  spacing: { lg: 24, md: 16, sm: 8, xxl: 48 },
}));
vi.mock('../../lib/useVenueAuth', () => ({
  useVenueAuth: () => ({
    venue: state.venue, isReady: true, canManage: state.canManage, profileLoading: state.profileLoading,
    profileError: state.profileError, refetchProfile: vi.fn(),
  }),
}));
vi.mock('../../components/ErrorBoundary', () => ({ ScreenErrorBoundary: ({ children }: any) => children }));
vi.mock('../../components/PremiumFeatureGate', () => ({ PremiumFeatureGate: ({ children }: any) => children }));
vi.mock('../../components/ProviderDropdown', () => ({
  ProviderDropdown: ({ label, value, onChange, disabled }: any) => React.createElement('ProviderDropdown', { label, value, onChange, disabled }),
}));
vi.mock('../../components/InlineMessage', () => ({ InlineMessage: ({ message }: any) => message }));
vi.mock('../../components/ManagerGate', () => ({
  ManagerGate: ({ children, canManage }: any) => (canManage === false ? 'ManagerGateBlocked' : children),
}));
vi.mock('../../components/AppCard', () => ({ SectionHeader: ({ title }: any) => title }));
vi.mock('../../lib/i18n', () => ({
  useI18n: () => ({
    t: (key: string, vars?: Record<string, unknown>) =>
      vars ? `${key}(${Object.entries(vars).map(([k, v]) => `${k}=${String(v)}`).join('|')})` : key,
  }),
}));

import IntegrationsScreenWrapper from '../../app/(tabs)/integrations';

function render() {
  return createRoot();
}
function output(r: ReturnType<typeof createRoot>) {
  return JSON.stringify(r.container.toJSON());
}
function buttonByLabel(r: ReturnType<typeof createRoot>, label: string) {
  return r.container.queryAll((n) => n.type === 'Button').find((n) => JSON.stringify(n.toJSON()).includes(label));
}

describe('Integrations screen', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    state.venue = { id: 'venue-1', name: 'The Fox & Vine' };
    state.canManage = true;
    state.profileLoading = false;
    state.profileError = null;
    state.overview = { connections: [], recentChecks: [] };
    state.reservationOverview = { connections: [], recentEvents: [] };
  });

  it('blocks non-managers from the integrations screen', async () => {
    state.canManage = false;
    const r = render();
    await act(async () => r.render(<IntegrationsScreenWrapper />));
    expect(output(r)).toContain('ManagerGateBlocked');
  });

  it('saves a POS connection for the selected provider and shows the returned secret once', async () => {
    state.upsertConnection.mockResolvedValueOnce({ webhookSecret: 'whsec_abc123' });
    const r = render();
    await act(async () => r.render(<IntegrationsScreenWrapper />));
    const posDropdown = r.container.queryAll((n) => n.type === 'ProviderDropdown')[0];
    await act(async () => posDropdown?.props.onChange('square'));
    const locationInput = r.container.queryAll((n) => n.type === 'TextInput')[0];
    await act(async () => locationInput?.props.onChangeText('  loc-42  '));
    await act(async () => buttonByLabel(r, 'integrations.pos.save')?.props.onPress());

    expect(state.upsertConnection).toHaveBeenCalledWith({
      venueId: 'venue-1', provider: 'square', externalLocationId: 'loc-42', status: 'connected',
    });
    expect(output(r)).toContain('whsec_abc123');
  });

  it('rotates an existing POS connection secret', async () => {
    state.overview = { connections: [{ _id: 'conn-1', provider: 'toast', status: 'connected', externalLocationId: 'loc-1', lastSyncAt: null }], recentChecks: [] };
    state.rotatePosSecret.mockResolvedValueOnce({ webhookSecret: 'whsec_rotated' });
    const r = render();
    await act(async () => r.render(<IntegrationsScreenWrapper />));
    await act(async () => buttonByLabel(r, 'integrations.connections.rotateSecret')?.props.onPress());
    expect(state.rotatePosSecret).toHaveBeenCalledWith({ venueId: 'venue-1', connectionId: 'conn-1' });
    expect(output(r)).toContain('whsec_rotated');
  });

  it('surfaces a failed POS save instead of silently doing nothing', async () => {
    state.upsertConnection.mockRejectedValueOnce(new Error('Provider rejected credentials'));
    const r = render();
    await act(async () => r.render(<IntegrationsScreenWrapper />));
    await act(async () => buttonByLabel(r, 'integrations.pos.save')?.props.onPress());
    expect(output(r)).toContain('Provider rejected credentials');
  });

  it('generates a leads webhook secret', async () => {
    state.rotateLeadsSecret.mockResolvedValueOnce({ webhookSecret: 'whsec_leads' });
    const r = render();
    await act(async () => r.render(<IntegrationsScreenWrapper />));
    await act(async () => buttonByLabel(r, 'integrations.leads.generate')?.props.onPress());
    expect(state.rotateLeadsSecret).toHaveBeenCalledWith({ venueId: 'venue-1' });
    expect(output(r)).toContain('whsec_leads');
  });

  it('saves a reservation connection for the selected provider', async () => {
    state.upsertReservationConnection.mockResolvedValueOnce({});
    const r = render();
    await act(async () => r.render(<IntegrationsScreenWrapper />));
    const reservationDropdown = r.container.queryAll((n) => n.type === 'ProviderDropdown')[1];
    await act(async () => reservationDropdown?.props.onChange('resy'));
    await act(async () => buttonByLabel(r, 'integrations.reservation.save')?.props.onPress());
    expect(state.upsertReservationConnection).toHaveBeenCalledWith(expect.objectContaining({ venueId: 'venue-1', provider: 'resy', status: 'connected' }));
  });
});

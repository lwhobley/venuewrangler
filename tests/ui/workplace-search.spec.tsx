import React, { act } from 'react';
import { createRoot } from 'test-renderer';
import { beforeEach, describe, expect, it, vi } from 'vitest';

const state = vi.hoisted(() => ({
  token: 'session-token' as string | null,
  searchVenues: vi.fn(),
  submitJoinRequest: vi.fn(),
  replace: vi.fn(),
  alert: vi.fn(),
}));

vi.mock('react-native', () => ({
  Alert: { alert: state.alert }, KeyboardAvoidingView: 'KeyboardAvoidingView', Platform: { OS: 'ios' }, ScrollView: 'ScrollView', View: 'View',
}));
vi.mock('expo-router', () => ({ router: { replace: state.replace } }));
vi.mock('react-native-paper', async () => {
  const R = await import('react');
  const element = (type: string) => ({ children, ...props }: any) => R.createElement(type, props, children);
  const Card = Object.assign(element('Card'), { Content: element('Card.Content') });
  return { Button: element('Button'), Card, Text: element('Text'), TextInput: element('TextInput') };
});
vi.mock('../../components/AppCard', () => ({ Kicker: ({ children }: any) => children }));
vi.mock('../../lib/api-client', () => ({ appApi: { searchVenues: state.searchVenues, submitJoinRequest: state.submitJoinRequest } }));
vi.mock('../../lib/auth-store', () => ({ useAuthStore: (select: (s: any) => unknown) => select({ token: state.token }) }));
vi.mock('../../lib/theme', () => ({
  authCardStyle: {}, authColors: { background: '#000', text: '#fff', muted: '#777', primary: '#0f0', buttonText: '#fff' },
  authInputProps: {}, spacing: { lg: 24, md: 16 }, type: { title: {} },
}));

import WorkplaceSearchScreen from '../../app/(auth)/workplace-search';

function render() {
  return createRoot();
}
function buttonByLabel(r: ReturnType<typeof createRoot>, label: string) {
  return r.container.queryAll((n) => n.type === 'Button').find((n) => JSON.stringify(n.toJSON()).includes(label));
}

describe('Workplace search screen', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    state.token = 'session-token';
  });

  it('requires a join code before searching', async () => {
    const r = render();
    await act(async () => r.render(<WorkplaceSearchScreen />));
    await act(async () => buttonByLabel(r, 'Request to join')?.props.onPress());
    expect(state.searchVenues).not.toHaveBeenCalled();
    expect(state.alert).toHaveBeenCalledWith('Join code required', expect.any(String));
  });

  it('sends a join request for the matched venue and routes to join-pending', async () => {
    state.searchVenues.mockResolvedValueOnce({ venues: [{ id: 'venue-1' }] });
    state.submitJoinRequest.mockResolvedValueOnce({});
    const r = render();
    await act(async () => r.render(<WorkplaceSearchScreen />));
    const input = r.container.queryAll((n) => n.type === 'TextInput')[0];
    await act(async () => input?.props.onChangeText('ABCD'));
    await act(async () => buttonByLabel(r, 'Request to join')?.props.onPress());
    expect(state.searchVenues).toHaveBeenCalledWith('ABCD');
    expect(state.submitJoinRequest).toHaveBeenCalledWith({ venueId: 'venue-1', code: 'ABCD' });
    expect(state.replace).toHaveBeenCalledWith('/(auth)/join-pending');
  });

  it('alerts when no venue matches the code', async () => {
    state.searchVenues.mockResolvedValueOnce({ venues: [] });
    const r = render();
    await act(async () => r.render(<WorkplaceSearchScreen />));
    const input = r.container.queryAll((n) => n.type === 'TextInput')[0];
    await act(async () => input?.props.onChangeText('NOPE'));
    await act(async () => buttonByLabel(r, 'Request to join')?.props.onPress());
    expect(state.alert).toHaveBeenCalledWith('Not found', expect.any(String));
    expect(state.submitJoinRequest).not.toHaveBeenCalled();
  });

  it('redirects to sign-in when there is no session token', async () => {
    state.token = null;
    const r = render();
    await act(async () => r.render(<WorkplaceSearchScreen />));
    const input = r.container.queryAll((n) => n.type === 'TextInput')[0];
    await act(async () => input?.props.onChangeText('ABCD'));
    await act(async () => buttonByLabel(r, 'Request to join')?.props.onPress());
    expect(state.replace).toHaveBeenCalledWith('/(auth)/sign-in');
    expect(state.searchVenues).not.toHaveBeenCalled();
  });
});

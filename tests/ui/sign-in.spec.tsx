import React, { act } from 'react';
import { createRoot } from 'test-renderer';
import { beforeEach, describe, expect, it, vi } from 'vitest';

const state = vi.hoisted(() => ({
  params: {} as { invite?: string; phone?: string; tab?: string },
  passwordAuth: vi.fn(),
  previewInvite: vi.fn(),
  setSession: vi.fn(),
  clearSession: vi.fn(),
  replace: vi.fn(),
  push: vi.fn(),
  alert: vi.fn(),
  haptic: vi.fn().mockResolvedValue(undefined),
}));

vi.mock('expo-router', () => ({
  router: { replace: state.replace, push: state.push },
  useLocalSearchParams: () => state.params,
}));
vi.mock('../../assets/venue-wrangler-logo.jpg', () => ({ default: 'venue-wrangler-logo' }));
vi.mock('expo-haptics', () => ({
  NotificationFeedbackType: { Success: 'success' },
  notificationAsync: state.haptic,
}));
vi.mock('react-native', () => ({
  Alert: { alert: state.alert },
  Image: 'Image',
  KeyboardAvoidingView: 'KeyboardAvoidingView',
  Linking: { openURL: vi.fn() },
  Platform: { OS: 'ios' },
  ScrollView: 'ScrollView',
  StyleSheet: { create: (styles: unknown) => styles },
  View: 'View',
}));
vi.mock('react-native-paper', async () => {
  const ReactModule = await import('react');
  const element = (type: string) => ({ children, ...props }: any) =>
    ReactModule.createElement(type, props, children);
  const Card = Object.assign(element('Card'), { Content: element('Card.Content') });
  return {
    Button: element('Button'),
    Card,
    Checkbox: element('Checkbox'),
    Chip: element('Chip'),
    SegmentedButtons: element('SegmentedButtons'),
    Text: element('Text'),
    TextInput: element('TextInput'),
  };
});
vi.mock('../../components/AppCard', () => ({ Kicker: 'Kicker' }));
vi.mock('../../lib/api-client', () => ({
  appApi: { passwordAuth: state.passwordAuth, previewInvite: state.previewInvite },
}));
vi.mock('../../lib/session-from-auth', () => ({
  userFromProfile: (profile: unknown) => ({ mappedUser: profile }),
  venueFromAuth: (_profile: unknown, venue: unknown) => venue ? { mappedVenue: venue } : null,
}));
vi.mock('../../lib/auth-store', () => ({
  useAuthStore: (selector: (value: unknown) => unknown) => selector({
    setSession: state.setSession,
    clearSession: state.clearSession,
  }),
}));
vi.mock('../../lib/i18n', () => ({
  useI18n: () => ({ t: (key: string) => key }),
}));
vi.mock('../../lib/theme', () => ({
  authCardStyle: {},
  authColors: {
    background: '#fff', border: '#ddd', buttonText: '#fff', danger: '#f00',
    highlight: '#eee', muted: '#777', primary: '#123', surface: '#fff', text: '#000',
  },
  spacing: { lg: 24, md: 16, sm: 8 },
  type: { title: {} },
}));

import SignInScreen from '../../app/(auth)/sign-in';

function find(renderer: ReturnType<typeof createRoot>, type: string, label: string) {
  return renderer.container.queryAll((node) => node.type === type)
    .find((node) => node.props.label === label || JSON.stringify(node.toJSON()).includes(label));
}

async function enterCredentials(renderer: ReturnType<typeof createRoot>) {
  await act(async () => {
    find(renderer, 'TextInput', 'signIn.emailLabel')?.props.onChangeText('person@example.com');
    find(renderer, 'TextInput', 'signIn.passwordLabel')?.props.onChangeText('password123');
  });
}

describe('SignInScreen', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    state.haptic.mockReset().mockResolvedValue(undefined);
    state.params = {};
    state.passwordAuth.mockReset();
    state.previewInvite.mockReset();
  });

  it('validates credentials before clearing an existing session', async () => {
    const renderer = createRoot();
    await act(async () => renderer.render(<SignInScreen />));

    await act(async () => find(renderer, 'Button', 'signIn.signInButton')?.props.onPress());

    expect(state.alert).toHaveBeenCalledWith('signIn.invalidDetailsTitle', 'signIn.invalidDetailsMessage');
    expect(state.clearSession).not.toHaveBeenCalled();
    expect(state.passwordAuth).not.toHaveBeenCalled();
  });

  it('stores a verified session and routes a venue member home', async () => {
    state.passwordAuth.mockResolvedValue({
      profile: { id: 'profile-1', emailVerified: true },
      venue: { id: 'venue-1' },
      token: 'session-token',
    });
    const renderer = createRoot();
    await act(async () => renderer.render(<SignInScreen />));
    await enterCredentials(renderer);

    await act(async () => find(renderer, 'Button', 'signIn.signInButton')?.props.onPress());

    expect(state.clearSession).toHaveBeenCalledOnce();
    expect(state.passwordAuth).toHaveBeenCalledWith(expect.objectContaining({
      email: 'person@example.com', password: 'password123', flow: 'signIn',
    }));
    expect(state.setSession).toHaveBeenCalledWith(expect.objectContaining({ token: 'session-token' }));
    expect(state.replace).toHaveBeenCalledWith('/(tabs)/home');
  });

  it('routes an unverified account back through email verification', async () => {
    state.passwordAuth.mockResolvedValue({
      profile: { id: 'profile-1', emailVerified: false },
      venue: null,
      token: 'session-token',
    });
    const renderer = createRoot();
    await act(async () => renderer.render(<SignInScreen />));
    await enterCredentials(renderer);

    await act(async () => find(renderer, 'Button', 'signIn.signInButton')?.props.onPress());

    expect(state.replace).toHaveBeenCalledWith('/(auth)/verify-email');
  });

  it.each(['rejects', 'never settles'])('completes sign-in when haptic feedback %s', async (failure) => {
    state.haptic.mockImplementation(() => failure === 'rejects'
      ? Promise.reject(new Error('Haptics unavailable')) : new Promise(() => {}));
    state.passwordAuth.mockResolvedValue({ profile: { emailVerified: true }, venue: { id: 'v1' }, token: 'token' });
    const renderer = createRoot();
    await act(async () => renderer.render(<SignInScreen />));
    await enterCredentials(renderer);
    await act(async () => { void find(renderer, 'Button', 'signIn.signInButton')?.props.onPress(); });
    expect(state.replace).toHaveBeenCalledWith('/(tabs)/home');
    expect(state.alert).not.toHaveBeenCalled();
  });

  it('preserves the invite and reports verification email delivery failure', async () => {
    state.params = { invite: 'invite-1', tab: 'signIn' };
    state.previewInvite.mockResolvedValue({ venueName: 'Test Venue' });
    state.passwordAuth.mockResolvedValue({ profile: { emailVerified: false }, venue: null, token: 'token', verificationEmailSent: false });
    const renderer = createRoot();
    await act(async () => renderer.render(<SignInScreen />));
    await enterCredentials(renderer);
    await act(async () => find(renderer, 'Button', 'signIn.signInButton')?.props.onPress());
    expect(state.replace).toHaveBeenCalledWith({ pathname: '/(auth)/verify-email', params: { invite: 'invite-1', emailSendFailed: '1' } });
  });

  it('allows retry after a failed authentication request', async () => {
    state.passwordAuth.mockRejectedValueOnce(new Error('Network unavailable'))
      .mockResolvedValueOnce({ profile: { emailVerified: true }, venue: null, token: 'token' });
    const renderer = createRoot();
    await act(async () => renderer.render(<SignInScreen />));
    await enterCredentials(renderer);
    await act(async () => find(renderer, 'Button', 'signIn.signInButton')?.props.onPress());
    expect(state.setSession).not.toHaveBeenCalled();
    expect(state.alert).toHaveBeenCalledWith('signIn.signInFailedTitle', 'Network unavailable');
    await act(async () => find(renderer, 'Button', 'signIn.signInButton')?.props.onPress());
    expect(state.replace).toHaveBeenCalledWith('/(auth)/team-choice');
  });

  it('synchronously blocks a double-tap while authentication is pending', async () => {
    let resolveAuth!: (value: unknown) => void;
    state.passwordAuth.mockImplementation(() => new Promise((resolve) => { resolveAuth = resolve; }));
    const renderer = createRoot();
    await act(async () => renderer.render(<SignInScreen />));
    await enterCredentials(renderer);
    const submit = find(renderer, 'Button', 'signIn.signInButton');

    await act(async () => {
      submit?.props.onPress();
      submit?.props.onPress();
      await Promise.resolve();
    });

    expect(state.passwordAuth).toHaveBeenCalledOnce();
    await act(async () => resolveAuth({
      profile: { id: 'profile-1', emailVerified: true }, venue: null, token: 'token',
    }));
    expect(state.replace).toHaveBeenCalledWith('/(auth)/team-choice');
  });
});

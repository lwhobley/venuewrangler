import React, { act } from 'react';
import { createRoot } from 'test-renderer';
import { beforeEach, describe, expect, it, vi } from 'vitest';

const state = vi.hoisted(() => ({
  params: { email: 'invitee@example.com', venueName: 'The Fox & Vine', inviteFound: '1' } as Record<string, string>,
  passwordAuth: vi.fn(),
  setSession: vi.fn(),
  clearSession: vi.fn(),
  replace: vi.fn(),
  back: vi.fn(),
  alert: vi.fn(),
  haptic: vi.fn().mockResolvedValue(undefined),
}));

vi.mock('expo-router', () => ({
  Redirect: ({ href }: { href: unknown }) => React.createElement('Redirect', { href: JSON.stringify(href) }),
  router: { replace: state.replace, back: state.back },
  useLocalSearchParams: () => state.params,
}));
vi.mock('expo-haptics', () => ({ NotificationFeedbackType: { Success: 'success' }, notificationAsync: state.haptic }));
vi.mock('react-native', () => ({
  Alert: { alert: state.alert }, KeyboardAvoidingView: 'KeyboardAvoidingView', Linking: { openURL: vi.fn() },
  Platform: { OS: 'ios' }, ScrollView: 'ScrollView', StyleSheet: { create: (s: unknown) => s }, View: 'View',
}));
vi.mock('react-native-paper', async () => {
  const R = await import('react');
  const element = (type: string) => ({ children, ...props }: any) => R.createElement(type, props, children);
  const Card = Object.assign(element('Card'), { Content: element('Card.Content') });
  return { Button: element('Button'), Card, Checkbox: element('Checkbox'), Text: element('Text'), TextInput: element('TextInput') };
});
vi.mock('../../components/AppCard', () => ({ Kicker: ({ children }: any) => children }));
vi.mock('../../lib/api-client', () => ({ appApi: { passwordAuth: state.passwordAuth } }));
vi.mock('../../lib/session-from-auth', () => ({
  userFromProfile: (p: unknown) => p,
  venueFromAuth: (_p: unknown, v: unknown) => v,
}));
vi.mock('../../lib/auth-store', () => ({
  useAuthStore: (select: (s: any) => unknown) => select({ setSession: state.setSession, clearSession: state.clearSession }),
}));
vi.mock('../../lib/theme', () => ({
  authCardStyle: {}, authColors: { background: '#000', text: '#fff', muted: '#777', primary: '#0f0', buttonText: '#fff', border: '#333', danger: '#f00' },
  authInputProps: {}, spacing: { lg: 24, md: 16, sm: 8, xl: 32 }, type: { title: {} },
}));
vi.mock('../../lib/i18n', () => ({
  useI18n: () => ({
    t: (key: string, vars?: Record<string, unknown>) =>
      vars ? `${key}(${Object.entries(vars).map(([k, v]) => `${k}=${String(v)}`).join('|')})` : key,
  }),
}));

import RegisterScreen from '../../app/(auth)/register';

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

async function fillValidForm(r: ReturnType<typeof createRoot>) {
  await act(async () => {
    inputByLabel(r, 'register.firstNameLabel')?.props.onChangeText('Jordan');
    inputByLabel(r, 'register.lastNameLabel')?.props.onChangeText('Lee');
    inputByLabel(r, 'register.emailLabel')?.props.onChangeText('invitee@example.com');
    inputByLabel(r, 'register.passwordLabel')?.props.onChangeText('password123');
    inputByLabel(r, 'register.confirmPasswordLabel')?.props.onChangeText('password123');
  });
  const checkbox = r.container.queryAll((n) => n.type === 'Checkbox')[0];
  await act(async () => checkbox?.props.onPress());
}

describe('Register screen', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    state.params = { email: 'invitee@example.com', venueName: 'The Fox & Vine', inviteFound: '1' };
  });

  it('redirects to invite-check when there is no confirmed invite', async () => {
    state.params = {};
    const r = render();
    await act(async () => r.render(<RegisterScreen />));
    expect(output(r)).toContain('/(auth)/invite-check');
  });

  it('blocks submission with missing fields and a short password', async () => {
    const r = render();
    await act(async () => r.render(<RegisterScreen />));
    await act(async () => inputByLabel(r, 'register.passwordLabel')?.props.onChangeText('short'));
    await act(async () => buttonByLabel(r, 'register.createAccountButton')?.props.onPress());
    expect(state.passwordAuth).not.toHaveBeenCalled();
    expect(output(r)).toContain('register.errors.required');
    expect(output(r)).toContain('register.errors.passwordLength');
  });

  it('requires terms acceptance', async () => {
    const r = render();
    await act(async () => r.render(<RegisterScreen />));
    await act(async () => {
      inputByLabel(r, 'register.firstNameLabel')?.props.onChangeText('Jordan');
      inputByLabel(r, 'register.lastNameLabel')?.props.onChangeText('Lee');
      inputByLabel(r, 'register.emailLabel')?.props.onChangeText('invitee@example.com');
      inputByLabel(r, 'register.passwordLabel')?.props.onChangeText('password123');
      inputByLabel(r, 'register.confirmPasswordLabel')?.props.onChangeText('password123');
    });
    await act(async () => buttonByLabel(r, 'register.createAccountButton')?.props.onPress());
    expect(state.passwordAuth).not.toHaveBeenCalled();
    expect(output(r)).toContain('register.errors.termsRequired');
  });

  it('creates an account and routes to verify-email with the delivery-failure flag', async () => {
    state.passwordAuth.mockResolvedValueOnce({
      profile: { emailVerified: false }, venue: null, token: 'tok', verificationEmailSent: false,
    });
    const r = render();
    await act(async () => r.render(<RegisterScreen />));
    await fillValidForm(r);
    await act(async () => buttonByLabel(r, 'register.createAccountButton')?.props.onPress());

    expect(state.clearSession).toHaveBeenCalled();
    expect(state.passwordAuth).toHaveBeenCalledWith(expect.objectContaining({
      email: 'invitee@example.com', flow: 'signUp', fullName: 'Jordan Lee', termsAccepted: true,
    }));
    expect(state.replace).toHaveBeenCalledWith('/(auth)/verify-email?emailSendFailed=1');
  });

  it('routes a fully verified user with a venue straight home', async () => {
    state.passwordAuth.mockResolvedValueOnce({ profile: { emailVerified: true }, venue: { id: 'venue-1' }, token: 'tok' });
    const r = render();
    await act(async () => r.render(<RegisterScreen />));
    await fillValidForm(r);
    await act(async () => buttonByLabel(r, 'register.createAccountButton')?.props.onPress());
    expect(state.replace).toHaveBeenCalledWith('/(tabs)/home');
  });

  it('routes a verified user with no venue to team-choice', async () => {
    state.passwordAuth.mockResolvedValueOnce({ profile: { emailVerified: true }, venue: null, token: 'tok' });
    const r = render();
    await act(async () => r.render(<RegisterScreen />));
    await fillValidForm(r);
    await act(async () => buttonByLabel(r, 'register.createAccountButton')?.props.onPress());
    expect(state.replace).toHaveBeenCalledWith('/(auth)/team-choice');
  });

  it('shows an alert on a failed signup instead of navigating away', async () => {
    state.passwordAuth.mockRejectedValueOnce(new Error('Email already registered'));
    const r = render();
    await act(async () => r.render(<RegisterScreen />));
    await fillValidForm(r);
    await act(async () => buttonByLabel(r, 'register.createAccountButton')?.props.onPress());
    expect(state.alert).toHaveBeenCalledWith('register.createAccountFailedTitle', 'Email already registered');
    expect(state.replace).not.toHaveBeenCalled();
  });
});

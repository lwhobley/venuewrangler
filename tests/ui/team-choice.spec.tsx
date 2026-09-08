import React, { act } from 'react';
import { createRoot } from 'test-renderer';
import { beforeEach, describe, expect, it, vi } from 'vitest';

const state = vi.hoisted(() => ({
  user: { email_verified: true } as any,
  venue: null as any,
  clearSession: vi.fn(),
  push: vi.fn(),
  replace: vi.fn(),
}));

vi.mock('react-native', () => ({ KeyboardAvoidingView: 'KeyboardAvoidingView', Platform: { OS: 'ios' }, ScrollView: 'ScrollView', StyleSheet: { create: (s: unknown) => s }, View: 'View' }));
vi.mock('expo-router', () => ({
  Redirect: ({ href }: { href: unknown }) => React.createElement('Redirect', { href: JSON.stringify(href) }),
  router: { push: state.push, replace: state.replace },
}));
vi.mock('react-native-paper', async () => {
  const R = await import('react');
  const element = (type: string) => ({ children, ...props }: any) => R.createElement(type, props, children);
  const Card = Object.assign(element('Card'), { Content: element('Card.Content') });
  return { Button: element('Button'), Card, Text: element('Text') };
});
vi.mock('../../components/AppCard', () => ({ Kicker: ({ children }: any) => children }));
vi.mock('../../lib/auth-store', () => ({
  useAuthStore: (select: (s: any) => unknown) => select({ user: state.user, venue: state.venue, clearSession: state.clearSession }),
}));
vi.mock('../../lib/theme', () => ({
  authCardStyle: {}, authColors: { background: '#000', text: '#fff', muted: '#777', primary: '#0f0', buttonText: '#fff' },
  spacing: { lg: 24, md: 16, sm: 8 }, type: { title: {} },
}));
vi.mock('../../lib/i18n', () => ({ useI18n: () => ({ t: (key: string) => key }) }));

import TeamChoiceScreen from '../../app/(auth)/team-choice';

function render() {
  return createRoot();
}
function output(r: ReturnType<typeof createRoot>) {
  return JSON.stringify(r.container.toJSON());
}
function buttonByLabel(r: ReturnType<typeof createRoot>, label: string) {
  return r.container.queryAll((n) => n.type === 'Button').find((n) => JSON.stringify(n.toJSON()).includes(label));
}

describe('Team choice screen', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    state.user = { email_verified: true };
    state.venue = null;
  });

  it('redirects to email verification for an unverified account', async () => {
    state.user = { email_verified: false };
    const r = render();
    await act(async () => r.render(<TeamChoiceScreen />));
    expect(output(r)).toContain('/(auth)/verify-email');
  });

  it('redirects to home once a venue is set', async () => {
    state.venue = { id: 'venue-1' };
    const r = render();
    await act(async () => r.render(<TeamChoiceScreen />));
    expect(output(r)).toContain('/(tabs)/home');
  });

  it('routes to invite-check for finding an invite', async () => {
    const r = render();
    await act(async () => r.render(<TeamChoiceScreen />));
    await act(async () => buttonByLabel(r, 'teamChoice.findInviteButton')?.props.onPress());
    expect(state.push).toHaveBeenCalledWith('/(auth)/invite-check');
  });

  it('clears the session and returns to welcome for a different account', async () => {
    const r = render();
    await act(async () => r.render(<TeamChoiceScreen />));
    await act(async () => buttonByLabel(r, 'teamChoice.signInDifferentAccount')?.props.onPress());
    expect(state.clearSession).toHaveBeenCalled();
    expect(state.replace).toHaveBeenCalledWith('/(auth)/welcome');
  });
});

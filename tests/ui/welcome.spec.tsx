import React, { act } from 'react';
import { createRoot } from 'test-renderer';
import { describe, expect, it, vi } from 'vitest';

const state = vi.hoisted(() => ({ push: vi.fn() }));

vi.mock('react-native', () => ({
  Animated: {
    Value: class {
      interpolate() {
        return 0;
      }
    },
    FlatList: 'Animated.FlatList',
    View: 'Animated.View',
    event: () => () => undefined,
  },
  Dimensions: { get: () => ({ width: 400, height: 800 }) },
  Platform: { OS: 'ios' },
  Pressable: 'Pressable',
  StyleSheet: { create: (s: unknown) => s },
  View: 'View',
}));
vi.mock('expo-router', () => ({ router: { push: state.push } }));
vi.mock('@expo/vector-icons', () => ({ MaterialCommunityIcons: 'MaterialCommunityIcons' }));
vi.mock('react-native-paper', async () => {
  const R = await import('react');
  const element = (type: string) => ({ children, ...props }: any) => R.createElement(type, props, children);
  return { Button: element('Button'), Text: element('Text') };
});
vi.mock('../../lib/theme', () => ({
  authColors: { background: '#000', primary: '#0f0', buttonText: '#fff', text: '#fff', muted: '#777', border: '#333', highlight: '#eee' },
  spacing: { lg: 24, md: 16, xl: 32 },
  type: { title: {}, heading: {} },
}));
vi.mock('../../lib/i18n', () => ({ useI18n: () => ({ t: (key: string) => key }) }));

import WelcomeScreen from '../../app/(auth)/welcome';

function render() {
  return createRoot();
}
function buttonByLabel(r: ReturnType<typeof createRoot>, label: string) {
  return r.container.queryAll((n) => n.type === 'Button').find((n) => JSON.stringify(n.toJSON()).includes(label));
}

describe('Welcome screen', () => {
  it('routes to sign-in for an existing user', async () => {
    const r = render();
    await act(async () => r.render(<WelcomeScreen />));
    await act(async () => buttonByLabel(r, 'welcome.logIn')?.props.onPress());
    expect(state.push).toHaveBeenCalledWith({ pathname: '/(auth)/sign-in', params: { tab: 'signIn' } });
  });

  it('routes to invite-check for a new joiner', async () => {
    const r = render();
    await act(async () => r.render(<WelcomeScreen />));
    await act(async () => buttonByLabel(r, 'welcome.joinWithInvite')?.props.onPress());
    expect(state.push).toHaveBeenCalledWith('/(auth)/invite-check');
  });
});

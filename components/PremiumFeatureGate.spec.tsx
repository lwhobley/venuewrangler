import React from 'react';
import { act } from 'react';
import { createRoot } from 'test-renderer';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { PremiumFeatureGate } from './PremiumFeatureGate';

const state = vi.hoisted(() => ({
  authLoading: false,
  isLoading: false,
  isPremium: false,
  me: { profile: { allAccess: false, trialEndsAt: 0 } } as any,
  push: vi.fn(),
}));

vi.mock('expo-router', () => ({ router: { push: state.push } }));
vi.mock('react-native', () => ({
  Platform: { OS: 'ios' },
  ScrollView: 'ScrollView',
  View: 'View',
}));
vi.mock('react-native-paper', async () => {
  const ReactModule = await import('react');
  const element = (type: string) => ({ children, ...props }: any) =>
    ReactModule.createElement(type, props, children);
  const Card = Object.assign(element('Card'), { Content: element('Card.Content') });
  return { Button: element('Button'), Card, Text: element('Text') };
});
vi.mock('../lib/a0-purchases-stub', () => ({
  useA0Purchases: () => ({ isLoading: state.isLoading, isPremium: state.isPremium }),
}));
vi.mock('../lib/auth-readiness', () => ({
  useAuthenticatedSession: () => ({ isAuthLoading: state.authLoading, me: state.me }),
}));
vi.mock('../lib/config', () => ({ config: { billingEnabled: true } }));
vi.mock('../lib/permissions', () => ({ hasAllAccess: (value: unknown) => value === true }));
vi.mock('../lib/theme', () => ({
  radius: { pill: 9999 },
  useDesignTheme: () => ({ primary: '#195C43', shadow: '#173E2B' }),
  colors: { background: '#000', muted: '#777', primary: '#fff', surface: '#111' },
  spacing: { lg: 24, sm: 8 },
}));
vi.mock('../lib/trial', () => ({ getTrialState: () => ({ active: false }) }));
vi.mock('../lib/railway-hooks', () => ({
  useQueryState: () => ({ data: null, isLoading: false }),
}));
vi.mock('../lib/railway-api', () => ({ api: { app: { getMyVenueBilling: 'app.getMyVenueBilling' } } }));

describe('PremiumFeatureGate', () => {
  beforeEach(() => {
    state.authLoading = false;
    state.isLoading = false;
    state.isPremium = false;
    state.me = { profile: { allAccess: false, trialEndsAt: 0 } };
    state.push.mockReset();
  });

  it('does not flash an upsell while access is loading', async () => {
    state.isLoading = true;
    const renderer = createRoot();
    await act(async () => renderer.render(<PremiumFeatureGate feature="reports">private</PremiumFeatureGate>));

    expect(JSON.stringify(renderer.container.toJSON())).not.toContain('Upgrade now');
  });

  it('renders the protected feature for a premium subscriber', async () => {
    state.isPremium = true;
    const renderer = createRoot();
    await act(async () => renderer.render(<PremiumFeatureGate feature="reports">private</PremiumFeatureGate>));

    expect(JSON.stringify(renderer.container.toJSON())).toContain('private');
  });

  it('shows an upsell and routes locked native users to the paywall', async () => {
    const renderer = createRoot();
    await act(async () => renderer.render(<PremiumFeatureGate feature="reports">private</PremiumFeatureGate>));
    const output = JSON.stringify(renderer.container.toJSON());

    expect(output).toContain('Intro access has ended');
    expect(output).toContain('Upgrade now');
    const button = renderer.container.queryAll((node) => node.type === 'Button')[0];
    await act(async () => button.props.onPress());
    expect(state.push).toHaveBeenCalledWith('/billing/paywall');
  });
});

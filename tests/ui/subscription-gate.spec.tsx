import React, { act } from 'react';
import { createRoot } from 'test-renderer';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { SubscriptionGate } from '../../components/SubscriptionGate';
import { ApiError } from '../../lib/api-client';

const mockRouter = vi.hoisted(() => ({
  replace: vi.fn(),
}));

const state = vi.hoisted(() => ({
  segments: ['tabs', 'home'] as string[],
  navKey: 'root-nav-key',
  hydrated: true,
  user: {
    id: 'u1',
    role: 'manager',
    full_name: 'Alex Morgan',
    email_verified: true,
    job_title: 'Manager',
    all_access: false,
    venue_id: 'v1',
  } as any,
  token: 'valid-token',
  syncProfile: vi.fn(),
  clearSession: vi.fn(),
  meData: {
    profile: {
      _id: 'u1',
      role: 'manager',
      fullName: 'Alex Morgan',
      emailVerified: true,
      jobTitle: 'Manager',
      allAccess: false,
      venueId: 'v1',
    },
    venue: { _id: 'v1', name: 'Downtown Bar' },
  } as any,
  meLoading: false,
  billingData: { status: 'active' } as any,
  billingLoading: false,
  isPremium: false,
  isPremiumLoading: false,
}));

vi.mock('expo-router', () => ({
  router: mockRouter,
  useSegments: () => state.segments,
  useRootNavigationState: () => ({ key: state.navKey }),
}));

vi.mock('../../lib/a0-purchases-stub', () => ({
  useA0Purchases: () => ({ isPremium: state.isPremium, isLoading: state.isPremiumLoading }),
}));

vi.mock('../../lib/config', () => ({
  config: { billingEnabled: true },
}));

vi.mock('../../lib/auth-store', () => ({
  useAuthStore: (selector: any) =>
    selector({
      hydrated: state.hydrated,
      user: state.user,
      token: state.token,
      syncProfile: state.syncProfile,
      clearSession: state.clearSession,
    }),
}));

vi.mock('../../lib/railway-api', () => ({
  api: {
    app: {
      getMe: 'getMe',
      getMyVenueBilling: 'getMyVenueBilling',
    },
  },
}));

vi.mock('../../lib/railway-hooks', () => ({
  useQueryState: (ref: string) => {
    if (ref === 'getMe') return { data: state.meData, isLoading: state.meLoading };
    if (ref === 'getMyVenueBilling') return { data: state.billingData, isLoading: state.billingLoading };
    return { data: undefined, isLoading: false };
  },
}));

vi.mock('../../lib/session-from-auth', () => ({
  venueFromApi: (v: any) => ({ id: v._id, name: v.name }),
}));

vi.mock('../../lib/permissions', () => ({
  hasAllAccess: (flag?: boolean) => Boolean(flag),
}));

describe('SubscriptionGate', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    vi.useFakeTimers();
    state.segments = ['(tabs)', 'home'];
    state.navKey = 'root-nav-key';
    state.hydrated = true;
    state.user = {
      id: 'u1',
      role: 'manager',
      full_name: 'Alex Morgan',
      email_verified: true,
      job_title: 'Manager',
      all_access: false,
      venue_id: 'v1',
    };
    state.token = 'valid-token';
    state.meData = {
      profile: {
        _id: 'u1',
        role: 'manager',
        fullName: 'Alex Morgan',
        emailVerified: true,
        jobTitle: 'Manager',
        allAccess: false,
        venueId: 'v1',
      },
      venue: { _id: 'v1', name: 'Downtown Bar' },
    };
    state.meLoading = false;
    state.billingData = { status: 'active' };
    state.billingLoading = false;
    state.isPremium = false;
    state.isPremiumLoading = false;
  });

  it('renders children for an active subscription', async () => {
    const r = createRoot();
    await act(async () => {
      r.render(
        <SubscriptionGate>
          <span>App Content</span>
        </SubscriptionGate>,
      );
    });

    expect(JSON.stringify(r.container.toJSON())).toContain('App Content');
    expect(mockRouter.replace).not.toHaveBeenCalled();
  });

  it('redirects signed-out visitors on protected routes to welcome', async () => {
    state.user = null;
    state.token = null;
    const r = createRoot();
    await act(async () => {
      r.render(
        <SubscriptionGate>
          <span>App Content</span>
        </SubscriptionGate>,
      );
    });

    act(() => {
      vi.runAllTimers();
    });

    expect(mockRouter.replace).toHaveBeenCalledWith('/(auth)/welcome');
  });

  it('clears session when profile query returns null for an existing user', async () => {
    state.meData = null;
    state.meLoading = false;
    const r = createRoot();
    await act(async () => {
      r.render(
        <SubscriptionGate>
          <span>App Content</span>
        </SubscriptionGate>,
      );
    });

    act(() => {
      vi.runAllTimers();
    });

    expect(state.clearSession).toHaveBeenCalled();
    expect(mockRouter.replace).toHaveBeenCalledWith('/(auth)/welcome');
  });

  it('syncs profile when server profile differs from local auth state', async () => {
    state.meData = {
      profile: {
        _id: 'u1',
        role: 'owner', // changed from manager
        fullName: 'Alex Morgan',
        emailVerified: true,
        jobTitle: 'Owner/GM',
        allAccess: true,
        venueId: 'v1',
      },
      venue: { _id: 'v1', name: 'Downtown Bar' },
    };

    const r = createRoot();
    await act(async () => {
      r.render(
        <SubscriptionGate>
          <span>App Content</span>
        </SubscriptionGate>,
      );
    });

    expect(state.syncProfile).toHaveBeenCalledWith(
      expect.objectContaining({
        user: expect.objectContaining({ role: 'owner', job_title: 'Owner/GM', all_access: true }),
      }),
    );
  });

  it('redirects to /billing/locked when venue subscription is cancelled', async () => {
    state.billingData = { status: 'cancelled' };
    const r = createRoot();
    await act(async () => {
      r.render(
        <SubscriptionGate>
          <span>App Content</span>
        </SubscriptionGate>,
      );
    });

    act(() => {
      vi.runAllTimers();
    });

    expect(mockRouter.replace).toHaveBeenCalledWith('/billing/locked?reason=cancelled');
  });

  it('redirects to /billing/locked when trial is expired and venue has no plan', async () => {
    state.billingData = null;
    state.meData = {
      ...state.meData,
      profile: {
        ...state.meData.profile,
        trialEndsAt: Date.now() - 10000,
      },
    };
    const r = createRoot();
    await act(async () => {
      r.render(
        <SubscriptionGate>
          <span>App Content</span>
        </SubscriptionGate>,
      );
    });

    act(() => {
      vi.runAllTimers();
    });

    expect(mockRouter.replace).toHaveBeenCalledWith('/billing/locked?reason=trial_expired');
  });

  it('escapes /billing/locked when the account is actually unblocked', async () => {
    state.segments = ['billing', 'locked'];
    state.billingData = { status: 'active' };
    const r = createRoot();
    await act(async () => {
      r.render(
        <SubscriptionGate>
          <span>App Content</span>
        </SubscriptionGate>,
      );
    });

    act(() => {
      vi.runAllTimers();
    });

    expect(mockRouter.replace).toHaveBeenCalledWith('/(tabs)/home');
  });
});

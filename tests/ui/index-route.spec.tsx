import React, { act } from 'react';
import { createRoot } from 'test-renderer';
import { describe, expect, it, vi } from 'vitest';

const state = vi.hoisted(() => ({ hydrated: false, user: null as any, venue: null as any }));
vi.mock('expo-router', () => ({
  Redirect: ({ href }: { href: unknown }) => React.createElement('Redirect', { href: JSON.stringify(href) }),
}));
vi.mock('../../lib/auth-store', () => ({
  useAuthStore: (select: (s: any) => unknown) =>
    select({ hydrated: state.hydrated, user: state.user, venue: state.venue }),
}));

import Index from '../../app/index';

function render() {
  const r = createRoot();
  act(() => { r.render(<Index />); });
  return JSON.stringify(r.container.toJSON());
}

describe('Root index route', () => {
  it('renders nothing before auth state hydrates', () => {
    state.hydrated = false;
    expect(render()).not.toContain('Redirect');
  });

  it('sends a signed-out visitor to welcome', () => {
    state.hydrated = true;
    state.user = null;
    state.venue = null;
    expect(render()).toContain('/(auth)/welcome');
  });

  it('sends an unverified account to email verification', () => {
    state.hydrated = true;
    state.user = { email_verified: false };
    state.venue = null;
    expect(render()).toContain('/(auth)/verify-email');
  });

  it('sends a verified user with no venue to team choice', () => {
    state.hydrated = true;
    state.user = { email_verified: true };
    state.venue = null;
    expect(render()).toContain('/(auth)/team-choice');
  });

  it('sends a fully onboarded user to the app home', () => {
    state.hydrated = true;
    state.user = { email_verified: true };
    state.venue = { id: 'venue-1' };
    expect(render()).toContain('/(tabs)/home');
  });
});

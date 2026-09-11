import React, { act } from 'react';
import { createRoot } from 'test-renderer';
import { describe, expect, it, vi } from 'vitest';

const state = vi.hoisted(() => ({ params: {} as { invite?: string } }));
vi.mock('expo-router', () => ({
  Redirect: ({ href }: { href: unknown }) => React.createElement('Redirect', { href: JSON.stringify(href) }),
  useLocalSearchParams: () => state.params,
}));

import JoinRedirect from '../../app/join';

function render() {
  const r = createRoot();
  act(() => { r.render(<JoinRedirect />); });
  return JSON.stringify(r.container.toJSON());
}

describe('/join redirect', () => {
  it('routes a query-string invite token to sign-in with the token preserved', () => {
    state.params = { invite: 'invite-123' };
    const out = render();
    expect(out).toContain('/(auth)/sign-in');
    expect(out).toContain('invite-123');
  });

  it('trims whitespace around the invite token', () => {
    state.params = { invite: '  invite-456  ' };
    expect(render()).toContain('invite-456');
  });

  it('falls back to welcome when no invite token is present', () => {
    state.params = {};
    expect(render()).toContain('/(auth)/welcome');
  });

  it('falls back to welcome for a blank invite token', () => {
    state.params = { invite: '   ' };
    expect(render()).toContain('/(auth)/welcome');
  });
});

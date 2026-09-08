import React, { act } from 'react';
import { createRoot } from 'test-renderer';
import { beforeEach, describe, expect, it, vi } from 'vitest';

const state = vi.hoisted(() => ({
  params: { venueName: 'The Fox & Vine' } as Record<string, string>,
  listMyJoinRequests: vi.fn(),
  getMe: vi.fn(),
  clearSession: vi.fn(),
  setVenue: vi.fn(),
  invalidateQueries: vi.fn(),
  replace: vi.fn(),
}));

vi.mock('react-native', () => ({ ScrollView: 'ScrollView', StyleSheet: { create: (s: unknown) => s }, View: 'View' }));
vi.mock('expo-router', () => ({ router: { replace: state.replace }, useLocalSearchParams: () => state.params }));
vi.mock('react-native-paper', async () => {
  const R = await import('react');
  const element = (type: string) => ({ children, ...props }: any) => R.createElement(type, props, children);
  const Card = Object.assign(element('Card'), { Content: element('Card.Content') });
  return { Button: element('Button'), Card, Text: element('Text') };
});
// A stable reference: a fresh object on every call would give `enterApp`'s
// useCallback a new dependency identity each render, redefining `checkStatus`
// and re-firing its mount effect forever.
const queryClientStub = { invalidateQueries: state.invalidateQueries };
vi.mock('@tanstack/react-query', () => ({ useQueryClient: () => queryClientStub }));
vi.mock('../../lib/api-client', () => ({ appApi: { listMyJoinRequests: state.listMyJoinRequests, getMe: state.getMe } }));
vi.mock('../../lib/session-from-auth', () => ({ venueFromApi: (v: unknown) => v }));
vi.mock('../../lib/auth-store', () => ({
  useAuthStore: (select: (s: any) => unknown) => select({ clearSession: state.clearSession, setVenue: state.setVenue }),
}));
vi.mock('../../lib/theme', () => ({
  authCardStyle: {}, authColors: { background: '#000', text: '#fff', muted: '#777', primary: '#0f0', buttonText: '#fff', danger: '#f00', highlight: '#eee' },
  spacing: { lg: 24, md: 16, sm: 8 }, type: { title: {} },
}));
vi.mock('../../lib/i18n', () => ({
  useI18n: () => ({
    t: (key: string, vars?: Record<string, unknown>) =>
      vars ? `${key}(${Object.entries(vars).map(([k, v]) => `${k}=${String(v)}`).join('|')})` : key,
  }),
}));

import JoinPendingScreen from '../../app/(auth)/join-pending';

function render() {
  return createRoot();
}
function output(r: ReturnType<typeof createRoot>) {
  return JSON.stringify(r.container.toJSON());
}
function buttonByLabel(r: ReturnType<typeof createRoot>, label: string) {
  return r.container.queryAll((n) => n.type === 'Button').find((n) => JSON.stringify(n.toJSON()).includes(label));
}

describe('Join pending screen', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    state.params = { venueName: 'The Fox & Vine' };
  });

  it('shows the pending state with the venue name from the join request', async () => {
    state.listMyJoinRequests.mockResolvedValueOnce({ requests: [{ status: 'pending', venueName: 'North Room' }] });
    const r = render();
    await act(async () => r.render(<JoinPendingScreen />));
    expect(output(r)).toContain('joinPending.pending.title');
    expect(output(r)).toContain('North Room');
  });

  it('auto-advances into the app when the latest request is approved', async () => {
    state.listMyJoinRequests.mockResolvedValueOnce({ requests: [{ status: 'approved', venueName: 'North Room' }] });
    state.getMe.mockResolvedValueOnce({ venue: { id: 'venue-1' } });
    const r = render();
    await act(async () => r.render(<JoinPendingScreen />));
    expect(state.setVenue).toHaveBeenCalledWith({ id: 'venue-1' });
    expect(state.replace).toHaveBeenCalledWith('/(tabs)/home');
  });

  it('shows the rejected state with a way to search again', async () => {
    state.listMyJoinRequests.mockResolvedValueOnce({ requests: [{ status: 'rejected', venueName: 'North Room' }] });
    const r = render();
    await act(async () => r.render(<JoinPendingScreen />));
    expect(output(r)).toContain('joinPending.rejected.title');
    await act(async () => buttonByLabel(r, 'joinPending.rejected.searchAgainButton')?.props.onPress());
    expect(state.replace).toHaveBeenCalledWith('/(auth)/invite-check');
  });

  it('shows the none-found state when there is no join request at all', async () => {
    state.listMyJoinRequests.mockResolvedValueOnce({ requests: [] });
    const r = render();
    await act(async () => r.render(<JoinPendingScreen />));
    expect(output(r)).toContain('joinPending.none.title');
  });

  it('signs out and returns to welcome', async () => {
    state.listMyJoinRequests.mockResolvedValueOnce({ requests: [{ status: 'pending', venueName: 'North Room' }] });
    const r = render();
    await act(async () => r.render(<JoinPendingScreen />));
    await act(async () => buttonByLabel(r, 'joinPending.signOut')?.props.onPress());
    expect(state.clearSession).toHaveBeenCalled();
    expect(state.replace).toHaveBeenCalledWith('/(auth)/welcome');
  });

  it('re-checks status on demand', async () => {
    state.listMyJoinRequests.mockResolvedValue({ requests: [{ status: 'pending', venueName: 'North Room' }] });
    const r = render();
    await act(async () => r.render(<JoinPendingScreen />));
    await act(async () => buttonByLabel(r, 'joinPending.pending.checkStatusButton')?.props.onPress());
    expect(state.listMyJoinRequests).toHaveBeenCalledTimes(2);
  });
});

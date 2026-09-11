import { afterEach, describe, expect, it, vi } from 'vitest';

vi.mock('expo-constants', () => ({
  default: { expoConfig: { extra: { EXPO_PUBLIC_API_URL: 'https://api.example.test' } } },
}));

vi.mock('./auth-store', () => {
  const state = { token: null, authEpoch: 0, user: null, venue: null, clearSession: vi.fn() };
  const store = Object.assign(
    (selector: (value: typeof state) => unknown) => selector(state),
    { getState: () => state },
  );
  return { useAuthStore: store };
});

import { ApiError, apiRequest } from './api-client';

function abortableFetch() {
  return vi.fn((_url: string, init?: RequestInit) => new Promise<Response>((_resolve, reject) => {
    const rejectAbort = () => reject(new DOMException('Aborted', 'AbortError'));
    if (init?.signal?.aborted) rejectAbort();
    else init?.signal?.addEventListener('abort', rejectAbort, { once: true });
  }));
}

describe('apiRequest cancellation', () => {
  it('rejects queued inventory belonging to a different account before sending it', async () => {
    const fetch = vi.fn();
    vi.stubGlobal('fetch', fetch);
    await expect(apiRequest('/v1/bar-inventory/i1/movement', { method: 'POST', expectedProfileId: 'other-profile', expectedVenueId: 'v1' })).rejects.toMatchObject({ status: 409 });
    expect(fetch).not.toHaveBeenCalled();
  });
  afterEach(() => {
    vi.useRealTimers();
    vi.unstubAllGlobals();
  });

  it('preserves caller cancellation instead of reporting a timeout', async () => {
    vi.stubGlobal('fetch', abortableFetch());
    const controller = new AbortController();

    const request = apiRequest('/cancelled', { signal: controller.signal });
    controller.abort();

    await expect(request).rejects.toMatchObject({ name: 'AbortError' });
    await expect(request).rejects.not.toBeInstanceOf(ApiError);
  });

  it('maps only the internal deadline to an HTTP 408 error', async () => {
    vi.useFakeTimers();
    vi.stubGlobal('fetch', abortableFetch());

    const request = apiRequest('/slow', { timeoutMs: 100 });
    const assertion = expect(request).rejects.toMatchObject({ name: 'ApiError', status: 408 });
    await vi.advanceTimersByTimeAsync(100);

    await assertion;
  });

  it('propagates a signal that was already aborted', async () => {
    vi.stubGlobal('fetch', abortableFetch());
    const controller = new AbortController();
    controller.abort();

    await expect(apiRequest('/already-cancelled', { signal: controller.signal })).rejects.toMatchObject({
      name: 'AbortError',
    });
  });
});

describe('apiRequest error bodies', () => {
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it('preserves a non-JSON error body', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(new Response('Service temporarily unavailable', { status: 503 })));

    await expect(apiRequest('/unavailable')).rejects.toMatchObject({
      name: 'ApiError',
      status: 503,
      message: 'Service temporarily unavailable',
    });
  });

  it('clears session on 401 when a token is present', async () => {
    const { useAuthStore } = await import('./auth-store');
    const storeState = (useAuthStore as any).getState();
    storeState.token = 'test-token';
    storeState.clearSession = vi.fn();

    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(new Response(JSON.stringify({ message: 'Unauthorized' }), { status: 401 })));

    await expect(apiRequest('/unauthorized')).rejects.toMatchObject({ status: 401 });
    expect(storeState.clearSession).toHaveBeenCalled();
  });

  it('clears session on 403 when active membership was revoked', async () => {
    const { useAuthStore } = await import('./auth-store');
    const storeState = (useAuthStore as any).getState();
    storeState.token = 'test-token';
    storeState.clearSession = vi.fn();

    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(new Response(JSON.stringify({ message: 'You do not have an active membership at the requested venue.' }), { status: 403 })));

    await expect(apiRequest('/revoked')).rejects.toMatchObject({ status: 403 });
    expect(storeState.clearSession).toHaveBeenCalled();
  });

  it('does not clear session on ordinary 403 forbidden errors', async () => {
    const { useAuthStore } = await import('./auth-store');
    const storeState = (useAuthStore as any).getState();
    storeState.token = 'test-token';
    storeState.clearSession = vi.fn();

    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(new Response(JSON.stringify({ message: 'You cannot perform this action' }), { status: 403 })));

    await expect(apiRequest('/forbidden')).rejects.toMatchObject({ status: 403 });
    expect(storeState.clearSession).not.toHaveBeenCalled();
  });
});

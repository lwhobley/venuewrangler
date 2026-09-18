import React from 'react';
import { act } from 'react';
import { createRoot } from 'test-renderer';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { ErrorBoundary } from './ErrorBoundary';
import { queryClient } from '../lib/query-client';

vi.mock('expo-router', () => ({ router: { replace: vi.fn() } }));
vi.mock('../lib/auth-store', () => ({
  useAuthStore: { getState: () => ({ clearSession: vi.fn() }) },
}));
vi.mock('react-native', () => ({
  Platform: { OS: 'ios' },
  ScrollView: 'ScrollView',
  View: 'View',
}));
vi.mock('react-native-paper', () => ({
  Button: 'Button',
  MD3DarkTheme: { colors: { elevation: {} } },
  MD3LightTheme: { colors: { elevation: {} } },
  Text: 'Text',
}));

function BrokenScreen(): React.ReactNode {
  throw new Error('query failed');
}

describe('ErrorBoundary', () => {
  beforeEach(() => {
    vi.spyOn(queryClient, 'resetQueries').mockResolvedValue(undefined);
  });

  it('turns a thrown data error into a recoverable user-facing state', async () => {
    const renderer = createRoot();

    await act(async () => {
      renderer.render(
        <ErrorBoundary>
          <BrokenScreen />
        </ErrorBoundary>,
      );
    });

    const output = JSON.stringify(renderer.container.toJSON());

    expect(output).toContain('Something went wrong');
    expect(output).toContain('Try again');

    const retry = renderer.container.queryAll((node) => node.type === 'Button')
      .find((node) => JSON.stringify(node.toJSON()).includes('Try again'));
    expect(retry).toBeDefined();
    await act(async () => {
      retry?.props.onPress();
    });
    expect(queryClient.resetQueries).toHaveBeenCalledOnce();
    const resetOptions = vi.mocked(queryClient.resetQueries).mock.calls[0][0];
    expect(resetOptions?.predicate?.({ state: { status: 'error' } } as never)).toBe(true);
    expect(resetOptions?.predicate?.({ state: { status: 'success' } } as never)).toBe(false);
  });
});

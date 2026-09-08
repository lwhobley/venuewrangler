import React, { act } from 'react';
import { createRoot } from 'test-renderer';
import { describe, expect, it, vi } from 'vitest';
import { QueryBoundary } from '../../components/QueryBoundary';

const mockRouter = vi.hoisted(() => ({
  push: vi.fn(),
}));

vi.mock('expo-router', () => ({
  router: mockRouter,
}));

vi.mock('react-native', () => {
  const R = require('react');
  return {
    Pressable: ({ children, onPress, ...props }: any) =>
      R.createElement('Pressable', { onPress, ...props }, children),
    View: 'View',
  };
});

vi.mock('react-native-paper', () => {
  const R = require('react');
  return {
    Text: ({ children, style }: any) => R.createElement('Text', { style }, children),
  };
});

vi.mock('../../components/Skeleton', () => ({
  Skeleton: ({ height }: any) => `Skeleton(${height})`,
}));

vi.mock('../../lib/theme', () => ({
  colors: { primary: '#007aff', danger: '#ff3b30', muted: '#8e8e93' },
  radius: { sharp: 2 },
  spacing: { sm: 8, md: 16 },
}));

vi.mock('../../lib/i18n', () => ({
  useI18n: () => ({
    t: (key: string, params?: any) =>
      params?.feature ? `${key}:${params.feature}` : key,
  }),
}));

function output(r: ReturnType<typeof createRoot>) {
  return JSON.stringify(r.container.toJSON());
}

describe('QueryBoundary', () => {
  it('renders 402 upgrade view when subscription is required', async () => {
    const r = createRoot();
    const state = {
      data: undefined,
      error: null,
      isLoading: false,
      subscriptionRequired: true,
      refetch: vi.fn(),
    };

    await act(async () => {
      r.render(
        <QueryBoundary state={state} feature="Floor Plan">
          {() => <span>Rendered Data</span>}
        </QueryBoundary>,
      );
    });

    const json = output(r);
    expect(json).toContain('queryBoundary.upgradeRequired:Floor Plan');
    expect(json).toContain('queryBoundary.viewPlans');
    expect(json).not.toContain('Rendered Data');

    const button = r.container.queryAll((node) => node.type === 'Pressable')[0];
    await act(async () => {
      button?.props.onPress();
    });
    expect(mockRouter.push).toHaveBeenCalledWith('/billing');
  });

  it('renders default skeleton when loading with no data', async () => {
    const r = createRoot();
    const state = {
      data: undefined,
      error: null,
      isLoading: true,
      refetch: vi.fn(),
    };

    await act(async () => {
      r.render(
        <QueryBoundary state={state}>
          {() => <span>Rendered Data</span>}
        </QueryBoundary>,
      );
    });

    expect(output(r)).toContain('Skeleton(72)');
  });

  it('renders custom skeleton when provided', async () => {
    const r = createRoot();
    const state = {
      data: undefined,
      error: null,
      isLoading: true,
      refetch: vi.fn(),
    };

    await act(async () => {
      r.render(
        <QueryBoundary state={state} skeleton={<span>Custom Loading...</span>}>
          {() => <span>Rendered Data</span>}
        </QueryBoundary>,
      );
    });

    expect(output(r)).toContain('Custom Loading...');
  });

  it('renders error state and handles retry button press', async () => {
    const r = createRoot();
    const refetch = vi.fn();
    const state = {
      data: undefined,
      error: new Error('Network timeout'),
      isLoading: false,
      refetch,
    };

    await act(async () => {
      r.render(
        <QueryBoundary state={state}>
          {() => <span>Rendered Data</span>}
        </QueryBoundary>,
      );
    });

    const json = output(r);
    expect(json).toContain('Network timeout');
    expect(json).toContain('queryBoundary.retry');

    const button = r.container.queryAll((node) => node.type === 'Pressable')[0];
    await act(async () => {
      button?.props.onPress();
    });
    expect(refetch).toHaveBeenCalled();
  });

  it('renders empty message when isEmpty returns true', async () => {
    const r = createRoot();
    const state = {
      data: [],
      error: null,
      isLoading: false,
      refetch: vi.fn(),
    };

    await act(async () => {
      r.render(
        <QueryBoundary
          state={state}
          isEmpty={(d) => d.length === 0}
          emptyMessage="No items found."
        >
          {(data) => <span>Items: {data.length}</span>}
        </QueryBoundary>,
      );
    });

    expect(output(r)).toContain('No items found.');
    expect(output(r)).not.toContain('Items: 0');
  });

  it('renders children with stale warning when background refetch has an error', async () => {
    const r = createRoot();
    const state = {
      data: [{ id: 1, name: 'Cached' }],
      error: new Error('Failed to revalidate'),
      isLoading: false,
      refetch: vi.fn(),
    };

    await act(async () => {
      r.render(
        <QueryBoundary state={state}>
          {(data) => <span>Item: {data[0].name}</span>}
        </QueryBoundary>,
      );
    });

    const json = output(r);
    expect(json).toContain('queryBoundary.stale');
    expect(json).toContain('Cached');
  });

  it('renders empty fragment if data is undefined and neither loading nor error', async () => {
    const r = createRoot();
    const state = {
      data: undefined,
      error: null,
      isLoading: false,
      refetch: vi.fn(),
    };

    await act(async () => {
      r.render(
        <QueryBoundary state={state}>
          {() => <span>Data</span>}
        </QueryBoundary>,
      );
    });

    expect(r.container.toJSON()?.children).toEqual([]);
  });
});

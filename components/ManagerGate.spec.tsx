import React from 'react';
import { act } from 'react';
import { createRoot } from 'test-renderer';
import { describe, expect, it, vi } from 'vitest';
import { Text } from 'react-native-paper';
import { ManagerGate } from './ManagerGate';

vi.mock('react-native', () => ({
  Platform: { OS: 'ios' },
  ScrollView: 'ScrollView',
}));
vi.mock('react-native-paper', () => ({
  Button: 'Button',
  MD3DarkTheme: { colors: { elevation: {} } },
  MD3LightTheme: { colors: { elevation: {} } },
  Text: 'Text',
}));

function SecretChild() {
  return <Text>secret-manager-content</Text>;
}

describe('ManagerGate', () => {
  it('shows a loading state while the profile is fetching', async () => {
    const renderer = createRoot();
    await act(async () => {
      renderer.render(
        <ManagerGate canManage={false} profileLoading feature="Reports">
          <SecretChild />
        </ManagerGate>,
      );
    });
    expect(JSON.stringify(renderer.container.toJSON())).toContain('Loading…');
  });

  it('shows a retryable error when the profile fetch failed', async () => {
    const onRetry = vi.fn();
    const renderer = createRoot();
    await act(async () => {
      renderer.render(
        <ManagerGate canManage={false} profileLoading={false} profileError={new Error('offline')} onRetry={onRetry} feature="Reports">
          <SecretChild />
        </ManagerGate>,
      );
    });
    const output = JSON.stringify(renderer.container.toJSON());
    expect(output).toContain("Couldn't load your profile");
    const retry = renderer.container.queryAll((node) => node.type === 'Button')[0];
    expect(retry).toBeDefined();
    await act(async () => {
      retry?.props.onPress();
    });
    expect(onRetry).toHaveBeenCalledOnce();
  });

  it('hides manager content from staff', async () => {
    const renderer = createRoot();
    await act(async () => {
      renderer.render(
        <ManagerGate canManage={false} profileLoading={false} feature="Reports">
          <SecretChild />
        </ManagerGate>,
      );
    });
    const output = JSON.stringify(renderer.container.toJSON());
    expect(output).toContain('available to managers and admins');
    expect(output).not.toContain('secret-manager-content');
  });

  it('renders children when the caller can manage the venue', async () => {
    const renderer = createRoot();
    await act(async () => {
      renderer.render(
        <ManagerGate canManage profileLoading={false} feature="Reports">
          <SecretChild />
        </ManagerGate>,
      );
    });
    expect(JSON.stringify(renderer.container.toJSON())).toContain('secret-manager-content');
  });
});

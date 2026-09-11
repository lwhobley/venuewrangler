import React, { act } from 'react';
import { createRoot } from 'test-renderer';
import { describe, expect, it, vi } from 'vitest';

const state = vi.hoisted(() => ({ replace: vi.fn() }));
vi.mock('expo-router', () => ({ router: { replace: state.replace } }));
vi.mock('react-native-paper', async () => {
  const R = await import('react');
  const element = (type: string) => ({ children, ...props }: any) => R.createElement(type, props, children);
  const Card = Object.assign(element('Card'), { Content: element('Card.Content') });
  return { Button: element('Button'), Card, Text: element('Text') };
});
vi.mock('../../components/AppCard', () => ({ Kicker: ({ children }: any) => children }));
vi.mock('../../lib/theme', () => ({
  authCardStyle: {}, authColors: { background: '#000', text: '#fff', muted: '#777', primary: '#0f0', buttonText: '#fff' },
  spacing: { lg: 24, md: 16 }, type: { title: {} },
}));

import CreateVenueScreen from '../../app/(auth)/create-venue';

function render() {
  return createRoot();
}
function buttonByLabel(r: ReturnType<typeof createRoot>, label: string) {
  return r.container.queryAll((n) => n.type === 'Button').find((n) => JSON.stringify(n.toJSON()).includes(label));
}

describe('Create venue screen (invite-only notice)', () => {
  it('routes to invite check when joining with an invite', async () => {
    const r = render();
    await act(async () => r.render(<CreateVenueScreen />));
    await act(async () => buttonByLabel(r, 'Join with invite')?.props.onPress());
    expect(state.replace).toHaveBeenCalledWith('/(auth)/invite-check');
  });

  it('routes back to welcome', async () => {
    const r = render();
    await act(async () => r.render(<CreateVenueScreen />));
    await act(async () => buttonByLabel(r, 'Back')?.props.onPress());
    expect(state.replace).toHaveBeenCalledWith('/(auth)/welcome');
  });
});

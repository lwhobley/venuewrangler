import React, { act } from 'react';
import { createRoot } from 'test-renderer';
import { describe, expect, it, vi } from 'vitest';

const state = vi.hoisted(() => ({ back: vi.fn() }));

vi.mock('react-native', () => ({ Pressable: 'Pressable', ScrollView: 'ScrollView', View: 'View' }));
vi.mock('expo-router', () => ({ router: { back: state.back } }));
vi.mock('@expo/vector-icons', () => ({ MaterialCommunityIcons: 'MaterialCommunityIcons' }));
vi.mock('react-native-paper', async () => {
  const R = await import('react');
  const element = (type: string) => ({ children, ...props }: any) => R.createElement(type, props, children);
  const TextInput = Object.assign(element('TextInput'), { Icon: element('TextInput.Icon') });
  return { IconButton: element('IconButton'), Text: element('Text'), TextInput };
});
vi.mock('../../components/AppCard', () => {
  const React = require('react');
  return { AppCard: ({ children }: any) => React.createElement('AppCard', null, children), Kicker: ({ children }: any) => children };
});
vi.mock('../../lib/theme', () => ({
  colors: { background: '#000', border: '#333', charcoal: '#222', muted: '#777', primary: '#0f0', surface: '#111' },
  spacing: { lg: 24, md: 16, xxl: 48 },
  type: { title: {}, heading: {} },
}));
vi.mock('../../lib/i18n', () => ({
  useI18n: () => ({
    t: (key: string, vars?: Record<string, unknown>) => {
      if (key === 'help.sections.floor.steps') return JSON.stringify(['Open the floor tab', 'Tap a table to seat it']);
      if (key.endsWith('.steps')) return '[]';
      if (vars) return `${key}(${Object.entries(vars).map(([k, v]) => `${k}=${String(v)}`).join('|')})`;
      return key;
    },
  }),
}));

import HelpScreen from '../../app/help';

function render() {
  return createRoot();
}
function output(r: ReturnType<typeof createRoot>) {
  // TextInput's `left` prop carries a raw (unrendered) React element with a
  // circular `_owner` fiber reference.
  return JSON.stringify(r.container.toJSON(), (key, value) => (key === 'left' ? '[Left]' : value));
}

describe('Help screen', () => {
  it('lists every guide section by default', async () => {
    const r = render();
    await act(async () => r.render(<HelpScreen />));
    const out = output(r);
    expect(out).toContain('help.sections.home.title');
    expect(out).toContain('help.sections.floor.title');
    expect(out).toContain('help.sections.checklist.title');
  });

  it('filters sections by search text', async () => {
    const r = render();
    await act(async () => r.render(<HelpScreen />));
    const input = r.container.queryAll((n) => n.type === 'TextInput')[0];
    await act(async () => input?.props.onChangeText('floor'));
    const out = output(r);
    expect(out).toContain('help.sections.floor.title');
    expect(out).not.toContain('help.sections.chat.title');
  });

  it('shows a no-results message for an unmatched search', async () => {
    const r = render();
    await act(async () => r.render(<HelpScreen />));
    const input = r.container.queryAll((n) => n.type === 'TextInput')[0];
    await act(async () => input?.props.onChangeText('xyznotasection'));
    expect(output(r)).toContain('help.noResults');
  });

  it('expands a section to reveal its steps and collapses on second tap', async () => {
    const r = render();
    await act(async () => r.render(<HelpScreen />));
    const floorHeader = r.container.queryAll((n) => n.type === 'Pressable').find((n) => JSON.stringify(n.toJSON()).includes('help.sections.floor.title'));
    await act(async () => floorHeader?.props.onPress());
    expect(output(r)).toContain('Open the floor tab');

    await act(async () => floorHeader?.props.onPress());
    expect(output(r)).not.toContain('Open the floor tab');
  });

  it('navigates back', async () => {
    const r = render();
    await act(async () => r.render(<HelpScreen />));
    const backButton = r.container.queryAll((n) => n.type === 'IconButton')[0];
    await act(async () => backButton?.props.onPress());
    expect(state.back).toHaveBeenCalled();
  });
});

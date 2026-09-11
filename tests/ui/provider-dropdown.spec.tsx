import React, { act } from 'react';
import { createRoot } from 'test-renderer';
import { describe, expect, it, vi } from 'vitest';

vi.mock('react-native', () => ({ Pressable: 'Pressable', View: 'View' }));
vi.mock('react-native-paper', async () => {
  const R = await import('react');
  const element = (type: string) => ({ children, ...props }: any) => R.createElement(type, props, children);
  const Menu = Object.assign(element('Menu'), { Item: element('Menu.Item') });
  return { Menu, Text: element('Text') };
});
vi.mock('@expo/vector-icons', () => ({ MaterialCommunityIcons: 'MaterialCommunityIcons' }));
vi.mock('../../lib/theme', () => ({
  colors: { border: '#333', charcoal: '#222', muted: '#777', surface: '#111' },
  spacing: { md: 16, sm: 8 },
  radius: { md: 8 },
}));

import { ProviderDropdown } from '../../components/ProviderDropdown';

const options = [
  { value: 'toast', label: 'Toast' },
  { value: 'square', label: 'Square' },
] as const;

function output(r: ReturnType<typeof createRoot>) {
  return JSON.stringify(r.container.toJSON(), (key, value) => (key === 'anchor' ? '[Anchor]' : value));
}

describe('ProviderDropdown', () => {
  it('shows the current selection label', async () => {
    const r = createRoot();
    await act(async () => r.render(<ProviderDropdown label="POS provider" value="toast" options={options} onChange={vi.fn()} />));
    expect(output(r)).toContain('Toast');
  });

  it('selects a new option and closes the menu', async () => {
    const onChange = vi.fn();
    const r = createRoot();
    await act(async () => r.render(<ProviderDropdown label="POS provider" value="toast" options={options} onChange={onChange} />));
    const squareItem = r.container.queryAll((n) => n.type === 'Menu.Item').find((n) => n.props.title === 'Square');
    await act(async () => squareItem?.props.onPress());
    expect(onChange).toHaveBeenCalledWith('square');
  });

  it('marks the disabled anchor when disabled', async () => {
    const r = createRoot();
    await act(async () => r.render(<ProviderDropdown label="POS provider" value="toast" options={options} onChange={vi.fn()} disabled />));
    // The anchor is a React element stored as a Menu prop, not rendered into
    // the tree by the mock, so read its props directly rather than via toJSON.
    const menuNode = r.container.queryAll((n) => n.type === 'Menu')[0];
    expect(menuNode?.props.anchor.props.disabled).toBe(true);
  });
});

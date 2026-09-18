import React, { act } from 'react';
import { createRoot } from 'test-renderer';
import { describe, expect, it, vi } from 'vitest';
import { Button } from './AppButton';
vi.unmock('./AppButton');

vi.mock('react-native', () => ({ Platform: { OS: 'web' } }));
vi.mock('react-native-paper', () => ({ Button: 'PaperButton' }));
vi.mock('../lib/theme', () => ({
  radius: { pill: 9999 },
  useDesignTheme: () => ({ primary: '#195C43', shadow: '#173E2B' }),
}));

describe('raised button feedback', () => {
  it('glows only while pressed and preserves the caller’s event handlers and semantics', async () => {
    const renderer = createRoot();
    const onPress = vi.fn(), onPressIn = vi.fn(), onPressOut = vi.fn();
    await act(async () => renderer.render(<Button mode="contained" accessibilityLabel="Save shift" onPress={onPress} onPressIn={onPressIn} onPressOut={onPressOut}>Save</Button>));
    const control = () => renderer.container.queryAll(node => node.type === 'PaperButton')[0];
    expect(control().props.accessibilityLabel).toBe('Save shift');
    expect(control().props.onPress).toBe(onPress);
    expect(control().props.style.at(-1).shadowOpacity).toBe(0.18);
    const event = {};
    await act(async () => control().props.onPressIn(event));
    expect(control().props.style.at(-1).shadowOpacity).toBe(0.48);
    expect(control().props.style.at(-1).boxShadow).toContain('0 0 18px');
    expect(onPressIn).toHaveBeenCalledWith(event);
    await act(async () => control().props.onPressOut(event));
    expect(control().props.style.at(-1).shadowOpacity).toBe(0.18);
    expect(onPressOut).toHaveBeenCalledWith(event);
    expect(onPress).not.toHaveBeenCalled();
    await act(async () => renderer.unmount());
  });

  it('keeps disabled and text controls free from raised feedback', async () => {
    const renderer = createRoot();
    for (const props of [{ mode: 'contained' as const, disabled: true }, { mode: 'text' as const }]) {
      await act(async () => renderer.render(<Button {...props}>Save</Button>));
      const control = () => renderer.container.queryAll(node => node.type === 'PaperButton')[0];
      await act(async () => control().props.onPressIn({}));
      expect(control().props.style.at(-1)).toEqual({});
    }
    await act(async () => renderer.unmount());
  });
});

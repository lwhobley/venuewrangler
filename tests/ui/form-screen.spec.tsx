import React, { act } from 'react';
import { createRoot } from 'test-renderer';
import { describe, expect, it, vi } from 'vitest';
import { FormScreen } from '../../components/FormScreen';

vi.mock('react-native', () => {
  const R = require('react');
  return {
    KeyboardAvoidingView: ({ children, style, behavior }: any) =>
      R.createElement('KeyboardAvoidingView', { style, behavior }, children),
    Platform: { OS: 'ios' },
    ScrollView: ({ children, style, contentContainerStyle, keyboardShouldPersistTaps }: any) =>
      R.createElement('ScrollView', { style, contentContainerStyle, keyboardShouldPersistTaps }, children),
  };
});
vi.mock('../../lib/theme', () => ({
  colors: { background: '#123456' },
}));

function output(r: ReturnType<typeof createRoot>) {
  return JSON.stringify(r.container.toJSON());
}

describe('FormScreen', () => {
  it('renders children within a scrollable keyboard-avoiding container', async () => {
    const r = createRoot();
    await act(async () => {
      r.render(
        <FormScreen contentContainerStyle={{ padding: 16 }}>
          <span>Child Form Content</span>
        </FormScreen>,
      );
    });

    const json = output(r);
    expect(json).toContain('Child Form Content');
    expect(json).toContain('"behavior":"padding"');
    expect(json).toContain('"backgroundColor":"#123456"');
    expect(json).toContain('"keyboardShouldPersistTaps":"handled"');
  });

  it('accepts custom container and content styles', async () => {
    const r = createRoot();
    await act(async () => {
      r.render(
        <FormScreen style={{ marginTop: 20 }} contentContainerStyle={{ gap: 8 }}>
          <span>Styled Content</span>
        </FormScreen>,
      );
    });

    const json = output(r);
    expect(json).toContain('"marginTop":20');
    expect(json).toContain('"gap":8');
  });
});

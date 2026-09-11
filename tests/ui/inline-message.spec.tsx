import React, { act } from 'react';
import { createRoot } from 'test-renderer';
import { describe, expect, it, vi } from 'vitest';

vi.mock('react-native-paper', async () => {
  const R = await import('react');
  return { Text: ({ children, style }: any) => R.createElement('Text', { style }, children) };
});
vi.mock('../../lib/theme', () => ({ colors: { danger: '#f00', muted: '#777' } }));

import { InlineMessage } from '../../components/InlineMessage';

function output(r: ReturnType<typeof createRoot>) {
  return JSON.stringify(r.container.toJSON());
}

describe('InlineMessage', () => {
  it('renders nothing for no message', async () => {
    const r = createRoot();
    await act(async () => r.render(<InlineMessage message={null} />));
    expect(output(r)).not.toContain('Text');
  });

  it('colors an error-shaped message as danger', async () => {
    const r = createRoot();
    await act(async () => r.render(<InlineMessage message="Could not save changes" />));
    expect(output(r)).toContain('"color":"#f00"');
  });

  it('colors a required-field message as danger', async () => {
    const r = createRoot();
    await act(async () => r.render(<InlineMessage message="Name is required" />));
    expect(output(r)).toContain('"color":"#f00"');
  });

  it('colors a neutral message as muted', async () => {
    const r = createRoot();
    await act(async () => r.render(<InlineMessage message="Item saved" />));
    expect(output(r)).toContain('"color":"#777"');
  });
});

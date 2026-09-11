import React, { act } from 'react';
import { createRoot } from 'test-renderer';
import { describe, expect, it, vi } from 'vitest';

vi.mock('react-native', () => ({ View: 'View' }));
vi.mock('../../lib/theme', () => ({ colors: { border: '#333' } }));

import { Skeleton } from '../../components/Skeleton';

function output(r: ReturnType<typeof createRoot>) {
  return JSON.stringify(r.container.toJSON());
}

describe('Skeleton', () => {
  it('defaults to a full-width 16px bar', async () => {
    const r = createRoot();
    await act(async () => r.render(<Skeleton />));
    const out = output(r);
    expect(out).toContain('"width":"100%"');
    expect(out).toContain('"height":16');
    expect(out).toContain('"backgroundColor":"#333"');
  });

  it('applies custom width, height, and an extra style', async () => {
    const r = createRoot();
    await act(async () => r.render(<Skeleton width={200} height={40} style={{ marginTop: 8 }} />));
    const out = output(r);
    expect(out).toContain('"width":200');
    expect(out).toContain('"height":40');
    expect(out).toContain('"marginTop":8');
  });
});

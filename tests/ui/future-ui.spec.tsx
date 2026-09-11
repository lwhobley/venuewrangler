import React, { act } from 'react';
import { createRoot } from 'test-renderer';
import { describe, expect, it, vi } from 'vitest';
import { CommandButton, CommandSurface, CommandText, MiniTrend, StatusPill } from '../../components/FutureUI';
import type { DesignPalette } from '../../lib/theme';

const dummyPalette: DesignPalette = {
  surface: '#ffffff',
  surfaceStrong: '#f5f5f5',
  surfaceSoft: '#fafafa',
  border: '#e5e5e5',
  charcoal: '#1a1a1a',
  muted: '#737373',
  primary: '#2563eb',
  backgroundAlt: '#ffffff',
  success: '#16a34a',
  warning: '#ca8a04',
  danger: '#dc2626',
  divider: '#e5e5e5',
} as any;

vi.mock('react-native', () => {
  const R = require('react');
  return {
    Pressable: ({ children, onPress, disabled, style, accessibilityRole, ...props }: any) => {
      const computedStyle = typeof style === 'function' ? style({ pressed: false }) : style;
      return R.createElement('Pressable', { onPress, disabled, style: computedStyle, accessibilityRole, ...props }, children);
    },
    View: ({ children, style, ...props }: any) =>
      R.createElement('View', { style, ...props }, children),
    Text: ({ children, style, ...props }: any) =>
      R.createElement('Text', { style, ...props }, children),
    StyleSheet: { hairlineWidth: 1 },
  };
});

vi.mock('@expo/vector-icons', () => ({
  MaterialCommunityIcons: ({ name, size, color }: any) => `Icon(${name},${size},${color})`,
}));

vi.mock('../../lib/theme', () => ({
  radius: { sharp: 2, soft: 8 },
  spacing: { md: 16, lg: 24 },
}));

function output(r: ReturnType<typeof createRoot>) {
  return JSON.stringify(r.container.toJSON());
}

describe('FutureUI Primitives', () => {
  describe('CommandSurface', () => {
    it('renders normal, strong, and inset surfaces', async () => {
      const r = createRoot();
      await act(async () => {
        r.render(
          <>
            <CommandSurface palette={dummyPalette}>Normal</CommandSurface>
            <CommandSurface palette={dummyPalette} strong>Strong</CommandSurface>
            <CommandSurface palette={dummyPalette} inset>Inset</CommandSurface>
          </>,
        );
      });

      const json = output(r);
      expect(json).toContain('"backgroundColor":"#ffffff"');
      expect(json).toContain('"backgroundColor":"#f5f5f5"');
      expect(json).toContain('"backgroundColor":"#fafafa"');
      expect(json).toContain('"borderWidth":0'); // for inset
    });
  });

  describe('CommandText', () => {
    it('renders different typography variants', async () => {
      const r = createRoot();
      await act(async () => {
        r.render(
          <>
            <CommandText palette={dummyPalette} variant="hero">Hero Heading</CommandText>
            <CommandText palette={dummyPalette} variant="title">Title</CommandText>
            <CommandText palette={dummyPalette} variant="label">Label</CommandText>
            <CommandText palette={dummyPalette} variant="metric">42</CommandText>
            <CommandText palette={dummyPalette}>Default Body</CommandText>
          </>,
        );
      });

      const json = output(r);
      expect(json).toContain('"fontSize":30'); // hero
      expect(json).toContain('"fontSize":19'); // title
      expect(json).toContain('"fontSize":11'); // label
      expect(json).toContain('"fontSize":28'); // metric
      expect(json).toContain('"fontSize":14'); // body
    });
  });

  describe('CommandButton', () => {
    it('handles press, selected state, icon, and disabled', async () => {
      const onPress = vi.fn();
      const r = createRoot();
      await act(async () => {
        r.render(
          <>
            <CommandButton palette={dummyPalette} icon="star" onPress={onPress}>
              Star
            </CommandButton>
            <CommandButton palette={dummyPalette} selected>
              Selected
            </CommandButton>
            <CommandButton palette={dummyPalette} disabled>
              Disabled
            </CommandButton>
          </>,
        );
      });

      const json = output(r);
      expect(json).toContain('Icon(star,15,#737373)');
      expect(json).toContain('"backgroundColor":"#2563eb"'); // selected

      const buttons = r.container.queryAll((node) => node.type === 'Pressable');
      await act(async () => {
        buttons[0]?.props.onPress();
      });
      expect(onPress).toHaveBeenCalled();
    });
  });

  describe('StatusPill', () => {
    it('renders neutral, good, warn, and danger tone styles', async () => {
      const r = createRoot();
      await act(async () => {
        r.render(
          <>
            <StatusPill palette={dummyPalette} tone="good">Online</StatusPill>
            <StatusPill palette={dummyPalette} tone="warn">Late</StatusPill>
            <StatusPill palette={dummyPalette} tone="danger">Offline</StatusPill>
            <StatusPill palette={dummyPalette} tone="neutral">Idle</StatusPill>
          </>,
        );
      });

      const json = output(r);
      expect(json).toContain('"borderLeftColor":"#16a34a"'); // good
      expect(json).toContain('"borderLeftColor":"#ca8a04"'); // warn
      expect(json).toContain('"borderLeftColor":"#dc2626"'); // danger
      expect(json).toContain('"borderLeftColor":"#2563eb"'); // neutral uses palette.primary
    });
  });

  describe('MiniTrend', () => {
    it('renders scaled trend bars matching input values', async () => {
      const r = createRoot();
      await act(async () => {
        r.render(<MiniTrend palette={dummyPalette} values={[10, 20, 30]} />);
      });

      const json = output(r);
      expect(json).toContain('"height":34');
      expect(json).toContain('"backgroundColor":"#2563eb"');
    });
  });
});

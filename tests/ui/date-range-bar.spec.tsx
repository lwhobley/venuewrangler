import React, { act } from 'react';
import { createRoot } from 'test-renderer';
import { describe, expect, it, vi } from 'vitest';
import { buildPresets, DateRangeBar, useDateRange } from '../../components/DateRangeBar';

vi.mock('react-native', () => {
  const R = require('react');
  return {
    View: ({ children, style }: any) => R.createElement('View', { style }, children),
  };
});

vi.mock('react-native-paper', () => {
  const R = require('react');
  const Button = ({ children, onPress }: any) =>
    R.createElement('button', { 'data-testid': 'date-button', onClick: onPress }, children);
  const MenuItem = ({ title, onPress, leadingIcon }: any) =>
    R.createElement('div', { 'data-testid': 'menu-item', 'data-icon': leadingIcon, onClick: onPress }, title);
  const Menu = Object.assign(
    ({ visible, children, anchor }: any) =>
      R.createElement('div', { 'data-visible': visible }, anchor, visible ? children : null),
    { Item: MenuItem },
  );
  const Text = ({ children, style }: any) => R.createElement('Text', { style }, children);
  return { Button, Menu, Text };
});

vi.mock('../../lib/theme', () => ({
  colors: { primary: '#007aff', muted: '#8e8e93' },
  spacing: { sm: 8 },
}));

function output(r: ReturnType<typeof createRoot>) {
  return JSON.stringify(r.container.toJSON());
}

describe('DateRangeBar and helpers', () => {
  it('builds date presets with valid keys and timestamps', () => {
    const presets = buildPresets('America/New_York');
    const keys = presets.map((p) => p.key);
    expect(keys).toContain('today');
    expect(keys).toContain('yesterday');
    expect(keys).toContain('this_week');
    expect(keys).toContain('last_7');
    expect(keys).toContain('last_30');
    expect(keys).toContain('this_month');

    const today = presets.find((p) => p.key === 'today')!;
    expect(today.days).toBe(1);
    expect(today.startDate).toBe(today.endDate);
    expect(today.startTs).toBeLessThan(today.endTs);
  });

  it('renders DateRangeBar and interacts with preset menu', async () => {
    const presets = buildPresets('UTC');
    const selected = presets[0];
    const onSelect = vi.fn();

    const r = createRoot();
    await act(async () => {
      r.render(<DateRangeBar selected={selected} presets={presets} onSelect={onSelect} />);
    });

    // Menu initially closed
    expect(output(r)).toContain('"data-visible":false');

    // Click anchor button to open menu
    const button = r.container.queryAll((node) => node.props['data-testid'] === 'date-button')[0];
    await act(async () => {
      button.props.onClick();
    });

    expect(output(r)).toContain('"data-visible":true');

    // Select the 'last_7' item
    const last7Item = r.container.queryAll(
      (node) => node.props['data-testid'] === 'menu-item' && node.children.some((c: any) => String(c).includes('Last 7 days')),
    )[0];
    expect(last7Item).toBeDefined();

    await act(async () => {
      last7Item.props.onClick();
    });

    expect(onSelect).toHaveBeenCalledWith(expect.objectContaining({ key: 'last_7' }));
  });

  it('renders date range string when start and end dates differ', async () => {
    const presets = buildPresets('UTC');
    const multiDay = presets.find((p) => p.key === 'last_7')!;
    const r = createRoot();

    await act(async () => {
      r.render(<DateRangeBar selected={multiDay} presets={presets} onSelect={vi.fn()} />);
    });

    const json = output(r);
    expect(json).toContain(multiDay.startDate);
    expect(json).toContain(multiDay.endDate);
  });

  it('provides working useDateRange hook', async () => {
    let hookResult: any;
    function TestComponent() {
      hookResult = useDateRange('last_7', 'UTC');
      return <span>Hook Test</span>;
    }

    const r = createRoot();
    await act(async () => {
      r.render(<TestComponent />);
    });

    expect(hookResult.selected.key).toBe('last_7');
    expect(hookResult.presets.length).toBeGreaterThanOrEqual(6);

    await act(async () => {
      hookResult.setSelected(hookResult.presets.find((p: any) => p.key === 'today'));
    });

    expect(hookResult.selected.key).toBe('today');
  });
});

import React, { act } from 'react';
import { createRoot } from 'test-renderer';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { WranglerAiUsagePanel } from '../../components/WranglerAiUsagePanel';
import { WranglerShiftStory } from '../../components/WranglerShiftStory';
import { WranglerIntelligencePanel } from '../../components/WranglerIntelligencePanel';
import { HomeWranglerSurface } from '../../components/HomeWranglerSurface';

const state = vi.hoisted(() => ({
  usage: {
    data: null as any,
    isLoading: false,
    isError: false,
  },
  wrangler: {
    data: null as any,
    isLoading: false,
    error: null as any,
    refetch: vi.fn(),
  },
  askResult: { answer: 'All stations are fully staffed.' },
  operatorPlanResult: {
    status: 'preview',
    summary: 'Add server to schedule',
    preview: ['Jose on Monday 3pm-11pm'],
    plan: { risk: 'sensitive_write', summary: 'Schedule add' },
  },
  operatorExecuteResult: { result: 'OK' },
  alertMock: vi.fn(),
}));

vi.mock('react-native', () => {
  const R = require('react');
  return {
    Alert: { alert: state.alertMock },
    Pressable: ({ children, onPress, disabled, style, accessibilityRole, ...props }: any) => {
      const s = typeof style === 'function' ? style({ pressed: false }) : style;
      return R.createElement('Pressable', { onPress, disabled, style: s, accessibilityRole, ...props }, children);
    },
    ScrollView: 'ScrollView',
    StyleSheet: { hairlineWidth: 1 },
    Text: ({ children, style, ...props }: any) =>
      R.createElement('Text', { style, ...props }, children),
    TextInput: ({ value, onChangeText, onSubmitEditing, placeholder }: any) =>
      R.createElement('TextInput', { value, onChangeText, onSubmitEditing, placeholder }),
    View: ({ children, style }: any) => R.createElement('View', { style }, children),
  };
});

vi.mock('react-native-paper', () => {
  const R = require('react');
  return {
    Button: ({ children, onPress }: any) => R.createElement('Button', { onPress }, children),
    Text: ({ children, style }: any) => R.createElement('Text', { style }, children),
  };
});

vi.mock('@expo/vector-icons', () => ({
  MaterialCommunityIcons: ({ name, size, color }: any) => `Icon(${name},${size},${color})`,
}));

vi.mock('expo-router', () => ({
  router: { push: vi.fn() },
}));

vi.mock('../../lib/theme', () => ({
  radius: { sharp: 2, soft: 6 },
  spacing: { xs: 4, sm: 8, md: 16, lg: 24 },
  useDesignTheme: () => ({
    background: '#fff',
    surface: '#fff',
    surfaceSoft: '#f8f8f8',
    surfaceStrong: '#eee',
    border: '#ddd',
    divider: '#eee',
    primary: '#7A5A35',
    charcoal: '#222',
    muted: '#666',
    warning: '#e65100',
    success: '#2e7d32',
    danger: '#c62828',
  }),
}));

vi.mock('../../lib/useWrangler', () => ({
  useWranglerAiUsage: () => state.usage,
  useWrangler: () => state.wrangler,
  useAskWrangler: () => ({
    mutateAsync: vi.fn().mockImplementation(async () => state.askResult),
    isPending: false,
  }),
  useWranglerOperatorPlan: () => ({
    mutateAsync: vi.fn().mockImplementation(async () => state.operatorPlanResult),
    isPending: false,
  }),
  useWranglerOperatorExecute: () => ({
    mutateAsync: vi.fn().mockImplementation(async () => state.operatorExecuteResult),
    isPending: false,
  }),
}));

vi.mock('../../lib/wrangler-result-format', () => ({
  formatOperatorResult: (res: any) => `Formatted: ${JSON.stringify(res)}`,
}));

function output(r: ReturnType<typeof createRoot>) {
  return JSON.stringify(r.container.toJSON());
}

describe('Wrangler AI Panels', () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  describe('WranglerAiUsagePanel', () => {
    it('returns null on error', async () => {
      state.usage = { data: null, isLoading: false, isError: true };
      const r = createRoot();
      await act(async () => r.render(<WranglerAiUsagePanel />));
      expect(r.container.toJSON()?.children).toEqual([]);
    });

    it('shows loading state when fetching usage', async () => {
      state.usage = { data: null, isLoading: true, isError: false };
      const r = createRoot();
      await act(async () => r.render(<WranglerAiUsagePanel />));
      expect(output(r)).toContain('Loading venue AI usage');
    });

    it('renders budget warning and feature breakdowns', async () => {
      state.usage = {
        isLoading: false,
        isError: false,
        data: {
          estimatedCostUsd: 14.5,
          requests: 120,
          promptTokens: 45000,
          completionTokens: 20000,
          budget: {
            status: 'warning',
            budgetUsd: 20,
            percentUsed: 72.5,
            warningPercent: 70,
            remainingUsd: 5.5,
          },
          breakdown: [
            {
              feature: 'shift_story',
              model: 'gemini-1.5-flash',
              requests: 60,
              totalTokens: 30000,
              estimatedCostUsd: 7.25,
            },
          ],
        },
      };

      const r = createRoot();
      await act(async () => r.render(<WranglerAiUsagePanel />));
      const json = output(r);
      expect(json).toContain('AI BUDGET WARNING');
      expect(json).toContain('72.5%');
      expect(json).toContain('Estimated spend');
      expect(json).toContain('Shift Story');
      expect(json).toContain('gemini-1.5-flash');
    });
  });

  describe('WranglerShiftStory', () => {
    it('renders calm message when no urgent priorities exist', async () => {
      const snapshot: any = { priorities: [] };
      const r = createRoot();
      await act(async () => r.render(<WranglerShiftStory snapshot={snapshot} />));
      expect(output(r)).toContain('Nothing is pulling service off course right now');
    });

    it('renders priority items with kind icons and severity copy', async () => {
      const snapshot: any = {
        priorities: [
          {
            id: 'p1',
            kind: 'floor',
            severity: 'critical',
            title: 'Table 12 rush',
            body: '3 guests waiting on dessert',
          },
          {
            id: 'p2',
            kind: 'stock',
            severity: 'watch',
            title: 'Bourbon low',
            body: 'Only 1 bottle left in service bar',
          },
        ],
      };
      const r = createRoot();
      await act(async () => r.render(<WranglerShiftStory snapshot={snapshot} />));
      const json = output(r);
      expect(json).toContain('Table 12 rush');
      expect(json).toContain('Now');
      expect(json).toContain('Bourbon low');
      expect(json).toContain('Watch');
      expect(json).toContain('Icon(table-chair');
      expect(json).toContain('Icon(bottle-wine-outline');
    });
  });

  describe('WranglerIntelligencePanel', () => {
    it('renders recap, patterns, and supports running commands', async () => {
      const snapshot: any = {
        recap: {
          headline: 'Strong Friday dinner',
          unresolved: [{ id: 'u1', title: 'Wine restock', reason: '86 pinot' }],
        },
        patterns: [{ id: 'pat1', title: 'Late patio rush', detail: 'Patio fills after 9pm' }],
      };

      const r = createRoot();
      await act(async () => {
        r.render(<WranglerIntelligencePanel snapshot={snapshot} />);
      });

      const json = output(r);
      expect(json).toContain('Strong Friday dinner');
      expect(json).toContain('Wine restock');
      expect(json).toContain('Late patio rush');

      // Click an operator preset
      const presetButton = r.container.queryAll(
        (n) => n.type === 'Pressable' && JSON.stringify(n.children).includes('Clear table 3'),
      )[0];
      expect(presetButton).toBeDefined();

      await act(async () => {
        presetButton.props.onPress();
      });

      // Review & confirm sensitive action
      const reviewButton = r.container.queryAll(
        (n) => n.type === 'Pressable' && JSON.stringify(n.children).includes('REVIEW & CONFIRM'),
      )[0];
      expect(reviewButton).toBeDefined();

      await act(async () => {
        reviewButton.props.onPress();
      });

      expect(state.alertMock).toHaveBeenCalled();
      const alertButtons = state.alertMock.mock.calls[0][2];
      const confirmButton = alertButtons.find((b: any) => b.text === 'Confirm & record');

      await act(async () => {
        confirmButton.onPress();
      });

      expect(output(r)).toContain('Done. Schedule add');
    });
  });

  describe('HomeWranglerSurface', () => {
    it('returns null when not enabled', async () => {
      const r = createRoot();
      await act(async () => r.render(<HomeWranglerSurface enabled={false} />));
      expect(r.container.toJSON()?.children).toEqual([]);
    });

    it('shows error retry UI on failure', async () => {
      state.wrangler = { data: null, isLoading: false, error: new Error('Network error'), refetch: vi.fn() };
      const r = createRoot();
      await act(async () => r.render(<HomeWranglerSurface enabled={true} />));

      expect(output(r)).toContain('The live service picture could not be loaded');
      const retryBtn = r.container.queryAll((n) => n.type === 'Button')[0];
      await act(async () => retryBtn?.props.onPress());
      expect(state.wrangler.refetch).toHaveBeenCalled();
    });

    it('renders snapshot priority details when loaded', async () => {
      state.wrangler = {
        data: {
          servicePhaseLabel: 'Dinner Service',
          summary: {
            covers: 48,
            vipArrivals: 3,
            seatedTables: 12,
          },
          priorities: [
            {
              id: 'p1',
              kind: 'floor',
              severity: 'critical',
              title: 'Floor backed up',
              body: 'High turnover at main dining',
              actions: [{ id: 'a1', label: 'Call support', kind: 'floor' }],
            },
          ],
        },
        isLoading: false,
        error: null,
        refetch: vi.fn(),
      };

      const r = createRoot();
      await act(async () => r.render(<HomeWranglerSurface enabled={true} />));

      const json = output(r);
      expect(json).toContain('THE WRANGLER');
      expect(json).toContain('DINNER SERVICE');
      expect(json).toContain('Floor backed up');
      expect(json).toContain('Call support');
    });
  });
});

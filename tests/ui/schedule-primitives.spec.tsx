import React, { act } from 'react';
import { createRoot } from 'test-renderer';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { ScheduleSkeleton } from '../../components/schedule/ScheduleSkeleton';
import { ScheduleMemoryPanel } from '../../components/schedule/ScheduleMemoryPanel';
import { BlackoutManager } from '../../components/schedule/BlackoutManager';
import { AutoScheduleModal } from '../../components/schedule/AutoScheduleModal';

const state = vi.hoisted(() => ({
  memoryNotes: [] as any[],
  blackouts: [] as any[],
  autoPreview: {
    weekStart: '2026-09-06',
    proposals: [
      { shiftId: 's1', profileId: 'p1', role: 'server' },
    ],
  } as any,
  addMemoryNote: vi.fn(),
  addBlackout: vi.fn(),
  removeBlackout: vi.fn(),
  applyAutoSchedule: vi.fn(),
}));

vi.mock('react-native', () => {
  const R = require('react');
  return {
    Animated: {
      Value: class {
        constructor(public val: number) {}
        interpolate() { return this; }
      },
      timing: () => ({ start: vi.fn(), stop: vi.fn() }),
      sequence: () => ({ start: vi.fn(), stop: vi.fn() }),
      loop: () => ({ start: vi.fn(), stop: vi.fn() }),
      View: ({ children, style }: any) => R.createElement('AnimatedView', { style }, children),
    },
    ScrollView: ({ children }: any) => R.createElement('ScrollView', null, children),
    View: ({ children, style, accessibilityLabel, ...props }: any) =>
      R.createElement('View', { style, accessibilityLabel, ...props }, children),
  };
});

vi.mock('react-native-paper', () => {
  const R = require('react');
  const element = (type: string) => ({ children, ...props }: any) =>
    R.createElement(type, props, children);
  const Card = Object.assign(element('Card'), { Content: element('Card.Content') });
  const Menu = Object.assign(
    ({ visible, children, anchor }: any) =>
      R.createElement('div', { 'data-visible': visible }, anchor, visible ? children : null),
    { Item: element('MenuItem') },
  );
  return {
    Button: ({ children, onPress, disabled, loading, ...props }: any) =>
      R.createElement('button', { onClick: onPress, disabled, 'data-loading': loading, ...props }, children),
    Card,
    Chip: element('Chip'),
    Divider: element('Divider'),
    Menu,
    Modal: ({ visible, children }: any) => (visible ? R.createElement('div', { 'data-modal': true }, children) : null),
    Portal: ({ children }: any) => R.createElement('div', { 'data-testid': 'portal' }, children),
    Text: element('Text'),
    TextInput: ({ value, onChangeText, label, placeholder, ...props }: any) =>
      R.createElement('input', {
        value,
        placeholder: label || placeholder,
        onChange: (e: any) => onChangeText(e.target.value),
        ...props,
      }),
  };
});

vi.mock('../../lib/railway-api', () => ({
  api: {
    scheduling: {
      listScheduleMemory: 'listScheduleMemory',
      addScheduleMemoryNote: 'addScheduleMemoryNote',
      listBlackouts: 'listBlackouts',
      addBlackout: 'addBlackout',
      removeBlackout: 'removeBlackout',
      previewAutoSchedule: 'previewAutoSchedule',
      applyAutoSchedule: 'applyAutoSchedule',
    },
  },
}));

vi.mock('../../lib/railway-hooks', () => ({
  useQuery: (ref: string) => {
    if (ref === 'listScheduleMemory') return { notes: state.memoryNotes };
    if (ref === 'listBlackouts') return state.blackouts;
    if (ref === 'previewAutoSchedule') return state.autoPreview;
    return undefined;
  },
  useMutation: (ref: string) => {
    if (ref === 'addScheduleMemoryNote') return state.addMemoryNote;
    if (ref === 'addBlackout') return state.addBlackout;
    if (ref === 'removeBlackout') return state.removeBlackout;
    if (ref === 'applyAutoSchedule') return state.applyAutoSchedule;
    return vi.fn();
  },
}));

vi.mock('../../lib/theme', () => ({
  accents: [{ bg: '#fef3c7', fg: '#b45309' }, {}, {}, {}, { bg: '#fee2e2', fg: '#b91c1c' }],
  colors: {
    primary: '#007aff',
    surface: '#fff',
    background: '#f4f4f4',
    charcoal: '#111',
    muted: '#777',
    border: '#eee',
    danger: '#ff3b30',
  },
  spacing: { sm: 8, md: 16 },
}));

function output(r: ReturnType<typeof createRoot>) {
  return JSON.stringify(r.container.toJSON());
}

describe('Schedule Primitives & Modals', () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  describe('ScheduleSkeleton', () => {
    it('renders skeleton rows and bar placeholders', async () => {
      const r = createRoot();
      await act(async () => r.render(<ScheduleSkeleton rows={3} />));
      const json = output(r);
      expect(json).toContain('Loading schedule');
      expect(json).toContain('AnimatedView');
    });
  });

  describe('ScheduleMemoryPanel', () => {
    it('renders empty notice and handles adding a memory note', async () => {
      state.memoryNotes = [];
      state.addMemoryNote.mockResolvedValueOnce({});

      const r = createRoot();
      await act(async () => r.render(<ScheduleMemoryPanel venueId={'v1' as any} />));
      expect(output(r)).toContain('No schedule lessons yet');

      const inputs = r.container.queryAll((n) => n.type === 'input');
      const titleInput = inputs.find((i) => i.props.placeholder === 'Memory title');
      const detailInput = inputs.find((i) => i.props.placeholder === 'Memory detail');

      await act(async () => {
        titleInput?.props.onChange({ target: { value: 'Patio Weather Surge' } });
      });
      await act(async () => {
        detailInput?.props.onChange({ target: { value: 'Need 2 extra food runners on sunny Sundays' } });
      });

      const saveBtn = r.container.queryAll((n) => n.type === 'button' && JSON.stringify(n.children).includes('Save memory'))[0];
      await act(async () => {
        saveBtn?.props.onClick();
      });

      expect(state.addMemoryNote).toHaveBeenCalledWith({
        venueId: 'v1',
        title: 'Patio Weather Surge',
        detail: 'Need 2 extra food runners on sunny Sundays',
      });
    });

    it('renders existing memory notes', async () => {
      state.memoryNotes = [
        {
          _id: 'n1',
          title: 'Sunday Brunch Rush',
          detail: 'Keep 3 bartenders on open',
          weekStart: '2026-09-06',
          createdAt: 1725800000000,
        },
      ];

      const r = createRoot();
      await act(async () => r.render(<ScheduleMemoryPanel venueId={'v1' as any} />));
      const json = output(r);
      expect(json).toContain('Sunday Brunch Rush');
      expect(json).toContain('Keep 3 bartenders on open');
    });
  });

  describe('BlackoutManager', () => {
    it('validates ISO date format and adds a blackout range', async () => {
      state.blackouts = [];
      state.addBlackout.mockResolvedValueOnce({});

      const r = createRoot();
      await act(async () => r.render(<BlackoutManager venueId={'v1' as any} />));

      let inputs = r.container.queryAll((n) => n.type === 'input');
      let startInput = inputs.find((i) => i.props.placeholder?.includes('Start'));
      let reasonInput = inputs.find((i) => i.props.placeholder?.includes('Reason'));
      let addBtn = r.container.queryAll((n) => n.type === 'button' && JSON.stringify(n.children).includes('Add blackout'))[0];

      // Invalid format first
      await act(async () => {
        startInput?.props.onChange({ target: { value: '09/20/2026' } });
      });
      await act(async () => {
        addBtn?.props.onClick();
      });
      expect(output(r)).toContain('Start date must be YYYY-MM-DD.');

      // Valid format
      inputs = r.container.queryAll((n) => n.type === 'input');
      startInput = inputs.find((i) => i.props.placeholder?.includes('Start'));
      reasonInput = inputs.find((i) => i.props.placeholder?.includes('Reason'));
      addBtn = r.container.queryAll((n) => n.type === 'button' && JSON.stringify(n.children).includes('Add blackout'))[0];

      await act(async () => {
        startInput?.props.onChange({ target: { value: '2026-12-31' } });
      });
      await act(async () => {
        reasonInput?.props.onChange({ target: { value: "New Year's Eve" } });
      });
      await act(async () => {
        addBtn?.props.onClick();
      });

      expect(state.addBlackout).toHaveBeenCalledWith({
        venueId: 'v1',
        startDate: '2026-12-31',
        endDate: undefined,
        reason: "New Year's Eve",
      });
    });

    it('renders blackouts list and handles removal', async () => {
      state.blackouts = [
        { _id: 'b1', startDate: '2026-12-31', endDate: '2027-01-01', reason: 'NYE Weekend' },
      ];
      state.removeBlackout.mockResolvedValueOnce({});

      const r = createRoot();
      await act(async () => r.render(<BlackoutManager venueId={'v1' as any} />));

      expect(output(r)).toContain('NYE Weekend');
      const removeBtn = r.container.queryAll((n) => n.type === 'button' && JSON.stringify(n.children).includes('Remove'))[0];
      await act(async () => removeBtn?.props.onClick());
      expect(state.removeBlackout).toHaveBeenCalledWith({ venueId: 'v1', blackoutId: 'b1' });
    });
  });

  describe('AutoScheduleModal', () => {
    it('renders proposals and handles applying schedule assignments', async () => {
      state.applyAutoSchedule.mockResolvedValueOnce({ assigned: 1, skipped: 0 });
      const onApplied = vi.fn();
      const onClose = vi.fn();
      const staff = [
        { _id: 'p1' as any, fullName: 'Taylor Green', jobTitle: 'Server', role: 'staff', weeklyHours: 30 },
      ];

      const r = createRoot();
      await act(async () => {
        r.render(
          <AutoScheduleModal
            venueId={'v1' as any}
            weekStartDate="2026-09-06"
            visible={true}
            onClose={onClose}
            onApplied={onApplied}
            staff={staff}
          />,
        );
      });

      const json = output(r);
      expect(json).toContain('Auto-schedule');
      expect(json).toContain('Taylor Green');

      const applyBtn = r.container.queryAll(
        (n) => n.type === 'button' && JSON.stringify(n.children).includes('Assign'),
      )[0];
      expect(applyBtn).toBeDefined();

      await act(async () => {
        applyBtn.props.onClick();
      });

      expect(state.applyAutoSchedule).toHaveBeenCalledWith(
        expect.objectContaining({
          venueId: 'v1',
          assignments: [{ shiftId: 's1', profileId: 'p1' }],
        }),
      );
      expect(onApplied).toHaveBeenCalledWith(expect.stringContaining('Auto-scheduled 1 shift'));
      expect(onClose).toHaveBeenCalled();
    });
  });
});

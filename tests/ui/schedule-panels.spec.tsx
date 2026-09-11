import React, { act } from 'react';
import { createRoot } from 'test-renderer';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { LaborForecastPanel } from '../../components/schedule/LaborForecastPanel';
import { MyShifts } from '../../components/schedule/MyShifts';

const mockRouter = vi.hoisted(() => ({
  push: vi.fn(),
}));

const state = vi.hoisted(() => ({
  venue: { id: 'v1', name: 'Downtown Bar', timezone: 'America/New_York' } as any,
  forecast: {
    days: [
      {
        dayIndex: 0,
        dayLabel: 'Sun Sep 6',
        covers: 120,
        privateEvents: 1,
        scheduledPeople: 5,
        scheduledHours: 35,
        suggestedHours: 42,
        gapHours: 7,
        status: 'under',
        dayparts: [{ key: 'dinner', label: 'Dinner', covers: 90, scheduledPeople: 4 }],
      },
      {
        dayIndex: 1,
        dayLabel: 'Mon Sep 7',
        covers: 60,
        privateEvents: 0,
        scheduledPeople: 3,
        scheduledHours: 24,
        suggestedHours: 24,
        gapHours: 0,
        status: 'balanced',
        dayparts: [{ key: 'dinner', label: 'Dinner', covers: 60, scheduledPeople: 3 }],
      },
    ],
    totals: { covers: 180, scheduledHours: 59, suggestedHours: 66, gapHours: 7 },
    alerts: [{ kind: 'understaffed', severity: 'critical', message: 'Short 7h on Sunday', dayLabel: 'Sun Sep 6' }],
    otRisk: [{ name: 'Chris Evans', scheduledHours: 44, overLimit: true }],
  } as any,
  mySchedule: {
    mine: [
      {
        _id: 'shift-1',
        dayIndex: 0,
        dayLabel: 'Sun',
        startMinutes: 600,
        endMinutes: 1020,
        startTime: '10:00 AM',
        endTime: '5:00 PM',
        jobTitle: 'Bartender',
        station: 'Main Bar',
        status: 'scheduled',
        mine: true,
        conflict: false,
      },
    ],
    open: [
      {
        _id: 'shift-2',
        dayIndex: 1,
        dayLabel: 'Mon',
        startMinutes: 1020,
        endMinutes: 1380,
        startTime: '5:00 PM',
        endTime: '11:00 PM',
        jobTitle: 'Bartender',
        station: 'Main Bar',
        status: 'open',
        mine: false,
        conflict: false,
      },
    ],
    roster: [
      {
        dayIndex: 0,
        dayLabel: 'Sun',
        coworkers: [
          {
            shiftId: 'shift-c1',
            profileId: 'p2',
            name: 'Jordan Lee',
            jobTitle: 'Server',
            station: 'Patio',
            dayIndex: 0,
            startMinutes: 600,
            endMinutes: 1020,
            startTime: '10:00 AM',
            endTime: '5:00 PM',
            withMe: true,
          },
        ],
      },
    ],
    weekStart: '2026-09-06',
  } as any,
  blackouts: [] as any[],
  directory: [
    { _id: 'p2', fullName: 'Jordan Lee', jobTitle: 'Server' },
  ] as any[],
  swaps: [] as any[],
  claimOpenShift: vi.fn(),
  requestDropShift: vi.fn(),
  createRequest: vi.fn(),
  proposeSwap: vi.fn(),
  respondToSwap: vi.fn(),
  openDm: vi.fn(),
  generateForecastAction: vi.fn(),
  generateDraftScheduleMutation: vi.fn(),
}));

vi.mock('expo-router', () => ({
  router: mockRouter,
}));

vi.mock('react-native', () => {
  const R = require('react');
  return {
    View: ({ children, style }: any) => R.createElement('View', { style }, children),
    ScrollView: ({ children }: any) => R.createElement('ScrollView', null, children),
    TextInput: ({ value, onChangeText, placeholder }: any) =>
      R.createElement('input', { value, placeholder, onChange: (e: any) => onChangeText(e.target.value) }),
  };
});

vi.mock('react-native-paper', () => {
  const R = require('react');
  const element = (type: string) => ({ children, ...props }: any) =>
    R.createElement(type, props, children);
  const Card = Object.assign(element('Card'), { Content: element('Card.Content') });
  return {
    Button: ({ children, onPress, disabled, loading, ...props }: any) =>
      R.createElement('button', { onClick: onPress, disabled, 'data-loading': loading, ...props }, children),
    Card,
    Chip: element('Chip'),
    Snackbar: ({ children, visible }: any) => (visible ? R.createElement('div', null, children) : null),
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

vi.mock('@expo/vector-icons', () => ({
  MaterialCommunityIcons: ({ name }: any) => `Icon(${name})`,
}));

vi.mock('../../lib/auth-store', () => ({
  useAuthStore: (selector: any) => selector({ venue: state.venue }),
}));

vi.mock('../../lib/auth-readiness', () => ({
  useAuthenticatedSession: () => ({ isReady: true, venue: state.venue }),
}));

vi.mock('../../lib/railway-api', () => ({
  api: {
    scheduling: {
      getLaborForecast: 'getLaborForecast',
      generateDraftSchedule: 'generateDraftSchedule',
      generateForecast: 'generateForecast',
      getMySchedule: 'getMySchedule',
      listBlackouts: 'listBlackouts',
      claimOpenShift: 'claimOpenShift',
      requestDropShift: 'requestDropShift',
      proposeShiftSwap: 'proposeShiftSwap',
      respondToShiftSwap: 'respondToShiftSwap',
      getMyShiftSwaps: 'getMyShiftSwaps',
      listScheduleMemory: 'listScheduleMemory',
      addScheduleMemoryNote: 'addScheduleMemoryNote',
    },
    app: {
      createStaffRequest: 'createStaffRequest',
    },
    chat: {
      listDirectory: 'listDirectory',
      openDm: 'openDm',
    },
  },
}));

vi.mock('../../lib/railway-hooks', () => ({
  useQuery: (ref: string) => {
    if (ref === 'getLaborForecast') return state.forecast;
    if (ref === 'getMySchedule') return state.mySchedule;
    if (ref === 'listBlackouts') return state.blackouts;
    if (ref === 'listDirectory') return state.directory;
    if (ref === 'getMyShiftSwaps') return state.swaps;
    if (ref === 'listScheduleMemory') return { notes: [] };
    return undefined;
  },
  useMutation: (ref: string) => {
    if (ref === 'generateDraftSchedule') return state.generateDraftScheduleMutation;
    if (ref === 'claimOpenShift') return state.claimOpenShift;
    if (ref === 'requestDropShift') return state.requestDropShift;
    if (ref === 'createStaffRequest') return state.createRequest;
    if (ref === 'proposeShiftSwap') return state.proposeSwap;
    if (ref === 'respondToShiftSwap') return state.respondToSwap;
    if (ref === 'openDm') return state.openDm;
    return vi.fn();
  },
  useAction: () => state.generateForecastAction,
}));

vi.mock('../../lib/theme', () => ({
  accents: [{}, {}, {}, {}, { bg: '#fee2e2', fg: '#b91c1c' }],
  colors: {
    primary: '#007aff',
    surface: '#fff',
    background: '#f4f4f4',
    charcoal: '#111',
    muted: '#777',
    border: '#eee',
    danger: '#ff3b30',
    warning: '#ff9500',
    success: '#34c759',
  },
  spacing: { sm: 8, md: 16 },
}));

function output(r: ReturnType<typeof createRoot>) {
  return JSON.stringify(r.container.toJSON());
}

describe('Schedule Panels', () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  describe('LaborForecastPanel', () => {
    it('renders forecast stats, explainability bullets, day breakdown, and overtime alerts', async () => {
      const r = createRoot();
      await act(async () => {
        r.render(<LaborForecastPanel venueId={'v1' as any} />);
      });

      const json = output(r);
      // Totals
      expect(json).toContain('180');
      expect(json).toContain('59h');
      // Explainability
      expect(json).toContain('Sun Sep 6 is the biggest shortfall');
      // Day details
      expect(json).toContain('Understaffed');
      expect(json).toContain('Chris Evans');
      expect(json).toContain('44');
      // Shortfall alert
      expect(json).toContain('Short 7h on Sunday');
    });

    it('triggers generate draft schedule on button click', async () => {
      state.generateForecastAction.mockResolvedValueOnce({
        shifts: [
          {
            dayIndex: 0,
            startMinutes: 600,
            endMinutes: 1020,
            jobTitle: 'Server',
            station: 'Floor',
            profileId: null,
            reason: 'High Sunday demand',
            dayLabel: 'Sun',
            startTime: '10:00 AM',
            endTime: '5:00 PM',
            memberName: null,
          },
        ],
      });

      const r = createRoot();
      await act(async () => {
        r.render(<LaborForecastPanel venueId={'v1' as any} />);
      });

      const draftBtn = r.container.queryAll(
        (n) => n.type === 'button' && JSON.stringify(n.children).includes('Generate AI draft'),
      )[0];
      expect(draftBtn).toBeDefined();

      await act(async () => {
        draftBtn.props.onClick();
      });

      expect(state.generateForecastAction).toHaveBeenCalled();
      expect(output(r)).toContain('Proposed 1 shift');
    });
  });

  describe('MyShifts', () => {
    it('renders user shifts and handles claiming an open shift', async () => {
      state.claimOpenShift.mockResolvedValueOnce({});
      const r = createRoot();
      await act(async () => {
        r.render(<MyShifts />);
      });

      const json = output(r);
      expect(json).toContain('Main Bar');
      expect(json).toContain('10:00 AM');
      expect(json).toContain('5:00 PM');
      expect(json).toContain('Open shifts you can pick up');

      const claimBtn = r.container.queryAll(
        (n) => n.type === 'button' && JSON.stringify(n.children).includes('Pick up shift'),
      )[0];
      expect(claimBtn).toBeDefined();

      await act(async () => {
        claimBtn.props.onClick();
      });

      expect(state.claimOpenShift).toHaveBeenCalledWith({ shiftId: 'shift-2' });
    });

    it('handles requesting to drop a shift', async () => {
      state.requestDropShift.mockResolvedValueOnce({});
      const r = createRoot();
      await act(async () => {
        r.render(<MyShifts />);
      });

      const dropBtn = r.container.queryAll(
        (n) => n.type === 'button' && JSON.stringify(n.children).includes('Request to drop'),
      )[0];
      expect(dropBtn).toBeDefined();

      await act(async () => {
        dropBtn.props.onClick();
      });

      expect(state.requestDropShift).toHaveBeenCalledWith({ shiftId: 'shift-1' });
    });

    it('routes to direct message when tapping teammate message button', async () => {
      state.openDm.mockResolvedValueOnce({ conversationId: 'c1' });
      const r = createRoot();
      await act(async () => {
        r.render(<MyShifts />);
      });

      const messageBtn = r.container.queryAll(
        (n) => n.type === 'button' && JSON.stringify(n.children).includes('Message'),
      )[0];
      expect(messageBtn).toBeDefined();

      await act(async () => {
        messageBtn.props.onClick();
      });

      expect(state.openDm).toHaveBeenCalledWith({ venueId: 'v1', targetProfileId: 'p2' });
      expect(mockRouter.push).toHaveBeenCalledWith('/chat/c1');
    });
  });
});

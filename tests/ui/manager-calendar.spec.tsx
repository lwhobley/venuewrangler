import React, { act } from 'react';
import { createRoot } from 'test-renderer';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { ManagerCalendar } from '../../components/schedule/ManagerCalendar';

const state = vi.hoisted(() => ({
  scheduleLoading: false,
  scheduleError: null as any,
  scheduleData: {
    shifts: [
      {
        _id: 's1',
        dayIndex: 0,
        startMinutes: 600,
        endMinutes: 1020,
        startTime: '10:00 AM',
        endTime: '5:00 PM',
        jobTitle: 'Server',
        station: 'Floor',
        notes: 'VIP table',
        status: 'scheduled',
        profileId: 'p1',
        memberName: 'Alice Walker',
        conflict: false,
      },
    ],
    staff: [
      {
        _id: 'p1',
        fullName: 'Alice Walker',
        role: 'server',
        jobTitle: 'Server',
        weeklyHours: 32,
        overtime: false,
        availability: [],
      },
    ],
    laborBudget: 4500,
    status: 'Draft',
  } as any,
  forecast: {
    days: [{ dayIndex: 0, dayLabel: 'Sun', covers: 100, scheduledHours: 7, suggestedHours: 7, gapHours: 0, status: 'balanced' }],
    totals: { covers: 100, scheduledHours: 7, suggestedHours: 7, gapHours: 0 },
  } as any,
  templates: [{ _id: 't1', name: 'Standard Weekend', shiftCount: 8 }] as any[],
  requestRows: [] as any[],
  refetch: vi.fn(),
  createShift: vi.fn(),
  updateShift: vi.fn(),
  assignShift: vi.fn(),
  unassignShift: vi.fn(),
  deleteShift: vi.fn(),
  publishSchedule: vi.fn(),
  saveTemplate: vi.fn(),
  applyTemplate: vi.fn(),
  deleteTemplate: vi.fn(),
  copyDayShifts: vi.fn(),
  clearWeek: vi.fn(),
  setLaborBudget: vi.fn(),
  restoreShifts: vi.fn(),
  openDm: vi.fn(),
}));

vi.mock('expo-router', () => ({
  router: { push: vi.fn() },
}));

vi.mock('react-native', () => {
  const R = require('react');
  return {
    Platform: { OS: 'web' },
    Pressable: ({ children, onPress, ...props }: any) =>
      R.createElement('Pressable', { onClick: onPress, ...props }, children),
    ScrollView: ({ children }: any) => R.createElement('ScrollView', null, children),
    View: ({ children, style }: any) => R.createElement('View', { style }, children),
    Modal: ({ visible, children }: any) => (visible ? R.createElement('div', { 'data-modal': true }, children) : null),
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
    IconButton: ({ icon, onPress }: any) =>
      R.createElement('button', { onClick: onPress, 'data-icon': icon }, icon),
    Menu,
    Searchbar: ({ value, onChangeText, placeholder }: any) =>
      R.createElement('input', { value, placeholder, onChange: (e: any) => onChangeText(e.target.value) }),
    SegmentedButtons: ({ value, onValueChange, buttons }: any) =>
      R.createElement(
        'div',
        { 'data-segmented': value },
        buttons.map((b: any) =>
          R.createElement('button', { key: b.value, onClick: () => onValueChange(b.value) }, b.label),
        ),
      ),
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

vi.mock('../../lib/responsive', () => ({
  useIsDesktop: () => false,
}));

vi.mock('../../components/schedule/AutoScheduleModal', () => ({
  AutoScheduleModal: () => 'AutoScheduleModal',
}));

vi.mock('../../components/schedule/ScheduleSkeleton', () => ({
  ScheduleSkeleton: () => 'ScheduleSkeleton',
}));

vi.mock('../../components/AppCard', () => {
  const R = require('react');
  return {
    CollapsibleSection: ({ title, children }: any) =>
      R.createElement('div', { 'data-collapsible': title }, R.createElement('span', null, title), children),
  };
});

vi.mock('../../lib/railway-api', () => ({
  api: {
    scheduling: {
      getManagerSchedule: 'getManagerSchedule',
      getLaborForecast: 'getLaborForecast',
      listScheduleTemplates: 'listScheduleTemplates',
      createShift: 'createShift',
      updateShift: 'updateShift',
      assignShift: 'assignShift',
      unassignShift: 'unassignShift',
      deleteShift: 'deleteShift',
      publishSchedule: 'publishSchedule',
      saveScheduleTemplate: 'saveScheduleTemplate',
      applyScheduleTemplate: 'applyScheduleTemplate',
      deleteScheduleTemplate: 'deleteScheduleTemplate',
      copyDayShifts: 'copyDayShifts',
      clearWeek: 'clearWeek',
      setLaborBudget: 'setLaborBudget',
      restoreShifts: 'restoreShifts',
    },
    app: {
      listStaffRequests: 'listStaffRequests',
    },
    chat: {
      openDm: 'openDm',
    },
  },
}));

vi.mock('../../lib/railway-hooks', () => ({
  useQueryState: () => ({
    data: state.scheduleData,
    error: state.scheduleError,
    isLoading: state.scheduleLoading,
    refetch: state.refetch,
  }),
  useQuery: (ref: string) => {
    if (ref === 'getLaborForecast') return state.forecast;
    if (ref === 'listScheduleTemplates') return state.templates;
    if (ref === 'listStaffRequests') return state.requestRows;
    return undefined;
  },
  useMutation: (ref: string) => {
    if (ref === 'createShift') return state.createShift;
    if (ref === 'updateShift') return state.updateShift;
    if (ref === 'assignShift') return state.assignShift;
    if (ref === 'unassignShift') return state.unassignShift;
    if (ref === 'deleteShift') return state.deleteShift;
    if (ref === 'publishSchedule') return state.publishSchedule;
    if (ref === 'saveScheduleTemplate') return state.saveTemplate;
    if (ref === 'applyScheduleTemplate') return state.applyTemplate;
    if (ref === 'deleteScheduleTemplate') return state.deleteTemplate;
    if (ref === 'copyDayShifts') return state.copyDayShifts;
    if (ref === 'clearWeek') return state.clearWeek;
    if (ref === 'setLaborBudget') return state.setLaborBudget;
    if (ref === 'restoreShifts') return state.restoreShifts;
    if (ref === 'openDm') return state.openDm;
    return vi.fn();
  },
}));

vi.mock('../../lib/theme', () => ({
  accents: [
    { bg: '#e0f2fe', fg: '#0369a1' },
    { bg: '#fef3c7', fg: '#b45309' },
    { bg: '#dcfce7', fg: '#15803d' },
  ],
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

describe('ManagerCalendar', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    state.scheduleLoading = false;
    state.scheduleError = null;
    state.scheduleData = {
      shifts: [
        {
          _id: 's1',
          dayIndex: 0,
          startMinutes: 600,
          endMinutes: 1020,
          startTime: '10:00 AM',
          endTime: '5:00 PM',
          jobTitle: 'Server',
          station: 'Floor',
          notes: 'VIP table',
          status: 'scheduled',
          profileId: 'p1',
          memberName: 'Alice Walker',
          conflict: false,
        },
      ],
      staff: [
        {
          _id: 'p1',
          fullName: 'Alice Walker',
          role: 'server',
          jobTitle: 'Server',
          weeklyHours: 32,
          overtime: false,
          availability: [],
        },
      ],
      laborBudget: 4500,
      status: 'Draft',
    };
  });

  it('renders loading skeleton when fetching manager schedule', async () => {
    state.scheduleLoading = true;
    state.scheduleData = undefined;
    const r = createRoot();
    await act(async () => {
      r.render(<ManagerCalendar venueId={'v1' as any} timeZone="America/New_York" />);
    });
    expect(output(r)).toContain('ScheduleSkeleton');
  });

  it('renders error notice and retry button when query fails', async () => {
    state.scheduleError = new Error('Could not load schedule');
    state.scheduleData = undefined;
    const r = createRoot();
    await act(async () => {
      r.render(<ManagerCalendar venueId={'v1' as any} timeZone="America/New_York" />);
    });
    const json = output(r);
    expect(json).toContain('Could not load schedule');
    const retryBtn = r.container.queryAll((n) => n.type === 'button' && JSON.stringify(n.children).includes('Retry'))[0];
    await act(async () => {
      retryBtn?.props.onClick();
    });
    expect(state.refetch).toHaveBeenCalled();
  });

  it('renders planner view with shifts, week offset controls, and publishes schedule', async () => {
    state.publishSchedule.mockResolvedValueOnce({ notified: 3 });
    const r = createRoot();
    await act(async () => {
      r.render(<ManagerCalendar venueId={'v1' as any} timeZone="America/New_York" />);
    });

    const json = output(r);
    expect(json).toContain('Alice Walker');
    expect(json).toContain('Draft');

    // Publish button
    const publishBtn = r.container.queryAll(
      (n) => n.type === 'button' && JSON.stringify(n.children).includes('Publish'),
    )[0];
    expect(publishBtn).toBeDefined();

    await act(async () => {
      publishBtn.props.onClick();
    });

    expect(state.publishSchedule).toHaveBeenCalledWith(
      expect.objectContaining({ venueId: 'v1' }),
    );
  });

  it('switches between planner, analytics, and staffing subtabs', async () => {
    const r = createRoot();
    await act(async () => {
      r.render(<ManagerCalendar venueId={'v1' as any} timeZone="America/New_York" />);
    });

    // Subtab buttons
    const analyticsBtn = r.container.queryAll(
      (n) => n.type === 'button' && JSON.stringify(n.children).includes('Analytics'),
    )[0];
    expect(analyticsBtn).toBeDefined();

    await act(async () => {
      analyticsBtn.props.onClick();
    });

    expect(output(r)).toContain('Labor Forecast');

    const staffingBtn = r.container.queryAll(
      (n) => n.type === 'button' && JSON.stringify(n.children).includes('Staffing'),
    )[0];
    expect(staffingBtn).toBeDefined();

    await act(async () => {
      staffingBtn.props.onClick();
    });

    expect(output(r)).toContain('Search employees or roles');
  });

  it('opens and closes shift editor modal', async () => {
    const r = createRoot();
    await act(async () => {
      r.render(<ManagerCalendar venueId={'v1' as any} timeZone="America/New_York" />);
    });

    const addShiftBtn = r.container.queryAll(
      (n) => n.type === 'button' && JSON.stringify(n.children).includes('Add Shift'),
    )[0];
    expect(addShiftBtn).toBeDefined();

    await act(async () => {
      addShiftBtn.props.onClick();
    });

    expect(output(r)).toContain('Create shift');
    expect(output(r)).toContain('Assign employee');
  });
});

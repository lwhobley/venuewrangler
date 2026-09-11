import React, { act } from 'react';
import { createRoot } from 'test-renderer';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { VenueSwitcher } from '../../components/VenueSwitcher';
import { ApiError } from '../../lib/api-client';

const mockRouter = vi.hoisted(() => ({
  push: vi.fn(),
}));

const state = vi.hoisted(() => ({
  activeVenue: { id: 'v1', name: 'Downtown Lounge', role: 'manager' } as any,
  venues: [
    { id: 'v1', name: 'Downtown Lounge', role: 'manager' },
    { id: 'v2', name: 'Uptown Bistro', role: 'staff' },
  ] as any[],
  user: { full_name: 'Jordan Smith' } as any,
  switchVenueAction: vi.fn(),
  setVenues: vi.fn(),
  switchVenueMutation: vi.fn(),
  registerVenueMutation: vi.fn(),
}));

vi.mock('expo-router', () => ({
  router: mockRouter,
}));

vi.mock('expo-constants', () => ({
  default: { expoConfig: { extra: {} } },
}));

vi.mock('react-native', () => {
  const R = require('react');
  return {
    Platform: { OS: 'web' },
    View: ({ children, style }: any) => R.createElement('View', { style }, children),
    StyleSheet: { create: (styles: any) => styles },
  };
});

vi.mock('react-native-paper', () => {
  const R = require('react');
  const element = (type: string) => ({ children, ...props }: any) =>
    R.createElement(type, props, children);
  const Card = Object.assign(element('Card'), { Content: element('Card.Content') });
  const Dialog = Object.assign(element('Dialog'), {
    Title: element('Dialog.Title'),
    Content: element('Dialog.Content'),
    Actions: element('Dialog.Actions'),
  });
  return {
    Button: ({ children, onPress, disabled, loading, ...props }: any) =>
      R.createElement('button', { onClick: onPress, disabled, 'data-loading': loading, ...props }, children),
    Card,
    Chip: ({ children, selected, icon, onPress, ...props }: any) =>
      R.createElement('div', { onClick: onPress, 'data-selected': selected, 'data-icon': icon, ...props }, children),
    Dialog,
    Portal: ({ children }: any) => R.createElement('div', { 'data-testid': 'portal' }, children),
    Text: element('Text'),
    TextInput: ({ value, onChangeText, label, ...props }: any) =>
      R.createElement('input', {
        value,
        placeholder: label,
        onChange: (e: any) => onChangeText(e.target.value),
        ...props,
      }),
  };
});

vi.mock('../../components/AppCard', () => {
  const R = require('react');
  return {
    AppCard: ({ children, style }: any) => R.createElement('div', { style }, children),
    SectionHeader: ({ title, subtitle, right }: any) =>
      R.createElement('div', null, title, subtitle, right),
  };
});

vi.mock('../../lib/auth-store', () => ({
  useAuthStore: Object.assign(
    (selector: any) =>
      selector({
        venue: state.activeVenue,
        venues: state.venues,
        switchVenue: state.switchVenueAction,
        user: state.user,
      }),
    {
      getState: () => ({
        setVenues: state.setVenues,
      }),
    },
  ),
}));

vi.mock('../../lib/railway-api', () => ({
  api: {
    app: {
      switchVenue: 'switchVenue',
      registerVenue: 'registerVenue',
    },
  },
}));

vi.mock('../../lib/railway-hooks', () => ({
  useMutation: (ref: string) => {
    if (ref === 'switchVenue') return state.switchVenueMutation;
    if (ref === 'registerVenue') return state.registerVenueMutation;
    return vi.fn();
  },
}));

vi.mock('../../lib/location', () => ({
  getPreciseLocation: async () => ({ latitude: 40.7128, longitude: -74.006 }),
}));

vi.mock('../../lib/session-from-auth', () => ({
  venueFromApi: (v: any) => ({ id: v._id || v.id, name: v.name }),
}));

vi.mock('../../lib/theme', () => ({
  colors: {
    background: '#fff',
    surface: '#fff',
    charcoal: '#111',
    muted: '#777',
    primary: '#007aff',
    border: '#eee',
    danger: '#ff3b30',
  },
  spacing: { sm: 8, md: 16, lg: 24 },
  type: { titleLarge: {} },
}));

function output(r: ReturnType<typeof createRoot>) {
  return JSON.stringify(r.container.toJSON());
}

describe('VenueSwitcher', () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it('renders all venues and marks the active venue as active', async () => {
    const r = createRoot();
    await act(async () => {
      r.render(<VenueSwitcher />);
    });

    const json = output(r);
    expect(json).toContain('Downtown Lounge');
    expect(json).toContain('Uptown Bistro');
    expect(json).toContain('Active');
  });

  it('switches venue when an inactive venue switch button is clicked', async () => {
    state.switchVenueMutation.mockResolvedValueOnce({
      venue: { _id: 'v2', name: 'Uptown Bistro' },
      venues: state.venues,
    });

    const r = createRoot();
    await act(async () => {
      r.render(<VenueSwitcher />);
    });

    const switchBtn = r.container.queryAll(
      (n) => n.type === 'button' && JSON.stringify(n.children).includes('Switch'),
    )[0];
    expect(switchBtn).toBeDefined();

    await act(async () => {
      switchBtn.props.onClick();
    });

    expect(state.switchVenueMutation).toHaveBeenCalledWith({ venueId: 'v2' });
    expect(state.switchVenueAction).toHaveBeenCalledWith({ id: 'v2', name: 'Uptown Bistro' });
  });

  it('handles registering a new venue and 402 upgrade error', async () => {
    const r = createRoot();
    await act(async () => {
      r.render(<VenueSwitcher />);
    });

    // Open register modal
    const addBtn = r.container.queryAll(
      (n) => n.type === 'button' && JSON.stringify(n.children).includes('Register Additional Venue'),
    )[0];
    expect(addBtn).toBeDefined();

    await act(async () => {
      addBtn.props.onClick();
    });

    // Try submitting without business name
    const registerConfirmBtn = r.container.queryAll(
      (n) => n.type === 'button' && JSON.stringify(n.children).includes('Create Venue'),
    )[0];
    expect(registerConfirmBtn).toBeDefined();

    await act(async () => {
      registerConfirmBtn.props.onClick();
    });

    expect(output(r)).toContain('Business name is required.');

    // Enter business name and simulate 402 ApiError
    const input = r.container.queryAll((n) => n.props.placeholder === 'Venue / Business Name')[0];
    await act(async () => {
      input.props.onChange({ target: { value: 'Rooftop Bar' } });
    });

    state.registerVenueMutation.mockRejectedValueOnce(new ApiError('payment_required', 402));

    await act(async () => {
      registerConfirmBtn.props.onClick();
    });

    expect(output(r)).toContain('Multi-Venue Pro subscription ($399/mo) required to register additional venues.');

    // Successful registration
    state.registerVenueMutation.mockResolvedValueOnce({
      venue: { _id: 'v3', name: 'Rooftop Bar' },
      venues: [...state.venues, { id: 'v3', name: 'Rooftop Bar', role: 'manager' }],
    });

    await act(async () => {
      registerConfirmBtn.props.onClick();
    });

    expect(state.switchVenueAction).toHaveBeenCalledWith({ id: 'v3', name: 'Rooftop Bar' });
    expect(mockRouter.push).toHaveBeenCalledWith('/venue/settings');
  });
});

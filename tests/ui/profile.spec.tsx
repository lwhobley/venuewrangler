import React, { act } from 'react';
import { createRoot } from 'test-renderer';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { ApiError } from '../../lib/api-client';

const state = vi.hoisted(() => ({
  deleteAccount: vi.fn(),
  clearSession: vi.fn().mockResolvedValue(undefined),
  signOut: vi.fn().mockResolvedValue(undefined),
  replace: vi.fn(),
  push: vi.fn(),
  auth: {
    user: { full_name: 'Venue Owner', email: 'owner@example.com', job_title: 'Owner' },
    venue: { id: 'venue-1', name: 'Main Venue' },
  },
  me: { profile: { role: 'owner', allAccess: false } },
}));

vi.mock('expo-router', () => ({ router: { replace: state.replace, push: state.push } }));
vi.mock('../../lib/api-client', () => ({
  ApiError: class ApiError extends Error {
    constructor(message: string, public status: number) {
      super(message);
      this.name = 'ApiError';
    }
  },
}));
vi.mock('react-native', () => ({
  Alert: { alert: vi.fn() },
  Platform: { OS: 'ios' },
  // ScreenErrorBoundary now renders DesktopFrame, which needs these.
  // Phone-sized so these specs keep exercising the mobile layout.
  useWindowDimensions: () => ({ width: 390, height: 844 }),
  ScrollView: 'ScrollView',
  View: 'View',
}));
vi.mock('react-native-paper', async () => {
  const ReactModule = await import('react');
  const element = (type: string) => ({ children, ...props }: any) =>
    ReactModule.createElement(type, props, children);
  const Card = Object.assign(element('Card'), { Content: element('Card.Content') });
  return { Button: element('Button'), Card, Text: element('Text') };
});
vi.mock('../../lib/railway-hooks', () => ({
  useMutation: () => state.deleteAccount,
  useQuery: () => state.me,
  useAuthActions: () => ({ signOut: state.signOut }),
}));
vi.mock('../../lib/railway-api', () => ({ api: { app: { deleteMyAccount: 'deleteMyAccount', getMe: 'getMe' } } }));
vi.mock('../../lib/auth-store', () => ({
  useAuthStore: (selector: (value: unknown) => unknown) => selector({ ...state.auth, clearSession: state.clearSession }),
}));
vi.mock('../../lib/auth-readiness', () => ({ useAuthenticatedSession: () => ({ isReady: true }) }));
vi.mock('../../lib/i18n', () => ({ useI18n: () => ({ t: (key: string) => key }) }));
vi.mock('../../lib/theme', () => ({
  colors: { background: '#000', danger: '#f00', muted: '#777', primary: '#fff', surface: '#111' },
  radius: { soft: 8 },
  spacing: { lg: 24, md: 16, sm: 8, xxl: 48 },
}));

import ProfileScreen from '../../app/(tabs)/profile';

function button(renderer: ReturnType<typeof createRoot>, label: string) {
  return renderer.container.queryAll((node) => node.type === 'Button')
    .find((node) => JSON.stringify(node.toJSON()).includes(label));
}

describe('Profile account deletion', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    state.deleteAccount.mockReset();
  });

  it('requires the server-driven second confirmation before deleting owned venues', async () => {
    state.deleteAccount.mockRejectedValueOnce(new ApiError('Deleting this account also deletes Main Venue', 409));
    const renderer = createRoot();
    await act(async () => renderer.render(<ProfileScreen />));

    await act(async () => button(renderer, 'profile.accountDeletion.startButton')?.props.onPress());
    await act(async () => button(renderer, 'profile.accountDeletion.confirmButton')?.props.onPress());

    expect(state.deleteAccount).toHaveBeenCalledWith({ deleteOwnedVenues: false });
    const output = JSON.stringify(renderer.container.toJSON());
    expect(output).toContain('Deleting this account also deletes Main Venue');
    expect(output).toContain('profile.accountDeletion.ownerWarning');
    expect(output).toContain('profile.accountDeletion.confirmVenueButton');
  });

  it('synchronously blocks a double-tap on the irreversible venue deletion', async () => {
    state.deleteAccount.mockRejectedValueOnce(new ApiError('Owned venue confirmation required', 409));
    const renderer = createRoot();
    await act(async () => renderer.render(<ProfileScreen />));
    await act(async () => button(renderer, 'profile.accountDeletion.startButton')?.props.onPress());
    await act(async () => button(renderer, 'profile.accountDeletion.confirmButton')?.props.onPress());

    let resolveDeletion!: () => void;
    state.deleteAccount.mockImplementationOnce(() => new Promise<void>((resolve) => { resolveDeletion = resolve; }));
    const destructive = button(renderer, 'profile.accountDeletion.confirmVenueButton');
    expect(destructive).toBeDefined();
    await act(async () => {
      destructive?.props.onPress();
      destructive?.props.onPress();
      await Promise.resolve();
    });

    expect(state.deleteAccount).toHaveBeenCalledTimes(2);
    expect(state.deleteAccount).toHaveBeenLastCalledWith({ deleteOwnedVenues: true });
    await act(async () => resolveDeletion());
    expect(state.clearSession).toHaveBeenCalledOnce();
    expect(state.replace).toHaveBeenCalledWith('/(auth)/welcome');
  });
});

import React, { act } from 'react';
import { createRoot } from 'test-renderer';
import { beforeEach, describe, expect, it, vi } from 'vitest';

const state = vi.hoisted(() => ({
  venue: { id: 'venue-1', name: 'The Fox & Vine' } as any,
  me: { profile: { role: 'owner', allAccess: true } } as any,
  canManage: true,
  profileLoading: false,
  staff: [] as any[],
  onboarding: undefined as any,
  auditLog: undefined as any,
  roles: [] as any[],
  upsertStaff: vi.fn(),
  deactivateStaff: vi.fn(),
  addVenueRole: vi.fn(),
  removeVenueRole: vi.fn(),
  createInvite: vi.fn(),
  parseStaffImport: vi.fn(),
  commitStaffImport: vi.fn(),
  updateOnboardingTask: vi.fn(),
  alert: vi.fn(),
  share: vi.fn(),
  push: vi.fn(),
}));

vi.mock('react-native', () => ({
  Alert: { alert: state.alert },
  FlatList: ({ ListHeaderComponent, data, renderItem, keyExtractor }: any) =>
    React.createElement(
      React.Fragment,
      null,
      ListHeaderComponent,
      ...(data ?? []).map((item: any, index: number) =>
        React.createElement(React.Fragment, { key: keyExtractor ? keyExtractor(item) : index }, renderItem({ item, index }))),
    ),
  ScrollView: 'ScrollView', Share: { share: state.share }, View: 'View',
}));
vi.mock('expo-router', () => ({ router: { push: state.push } }));
vi.mock('expo-document-picker', () => ({}));
vi.mock('react-native-paper', async () => {
  const R = await import('react');
  const element = (type: string) => ({ children, ...props }: any) => R.createElement(type, props, children);
  const Card = Object.assign(element('Card'), { Content: element('Card.Content') });
  const Menu = Object.assign(element('Menu'), { Item: element('Menu.Item') });
  return { Button: element('Button'), Card, Chip: element('Chip'), Menu, Text: element('Text'), TextInput: element('TextInput') };
});
vi.mock('../../components/ErrorBoundary', () => ({ ScreenErrorBoundary: ({ children }: any) => children }));
vi.mock('../../components/AppCard', () => ({ SectionHeader: ({ title }: any) => title }));
vi.mock('../../lib/useVenueAuth', () => ({
  useVenueAuth: () => ({
    venue: state.venue, isReady: true, me: state.me, profileLoading: state.profileLoading,
    profileError: null, refetchProfile: vi.fn(), canManage: state.canManage,
  }),
}));
vi.mock('../../lib/picked-file', () => ({ readPickedFileText: vi.fn() }));
vi.mock('../../lib/railway-api', () => ({
  api: {
    app: {
      listVenueStaff: 'listVenueStaff', listStaffOnboarding: 'listStaffOnboarding', listStaffAuditLog: 'listStaffAuditLog',
      upsertVenueStaff: 'upsertVenueStaff', deactivateVenueStaff: 'deactivateVenueStaff', updateStaffOnboardingTask: 'updateStaffOnboardingTask',
      parseStaffImport: 'parseStaffImport', commitStaffImport: 'commitStaffImport',
    },
    staffAuth: { listVenueRoles: 'listVenueRoles', addVenueRole: 'addVenueRole', removeVenueRole: 'removeVenueRole' },
    invites: { createInvite: 'createInvite' },
  },
}));
vi.mock('../../lib/railway-hooks', () => ({
  useQuery: (ref: string) => {
    if (ref === 'listVenueStaff') return state.staff;
    if (ref === 'listStaffOnboarding') return state.onboarding;
    if (ref === 'listStaffAuditLog') return state.auditLog;
    if (ref === 'listVenueRoles') return state.roles;
    return undefined;
  },
  useMutation: (ref: string) => {
    if (ref === 'upsertVenueStaff') return state.upsertStaff;
    if (ref === 'deactivateVenueStaff') return state.deactivateStaff;
    if (ref === 'addVenueRole') return state.addVenueRole;
    if (ref === 'removeVenueRole') return state.removeVenueRole;
    if (ref === 'createInvite') return state.createInvite;
    if (ref === 'updateStaffOnboardingTask') return state.updateOnboardingTask;
    return vi.fn();
  },
  useAction: (ref: string) => (ref === 'parseStaffImport' ? state.parseStaffImport : state.commitStaffImport),
}));
vi.mock('../../lib/theme', () => ({
  accents: Array.from({ length: 6 }, (_, i) => ({ bg: `#bg${i}`, fg: `#fg${i}`, icon: `#ic${i}` })),
  colors: { background: '#000', border: '#333', charcoal: '#222', danger: '#f00', muted: '#777', primary: '#0f0', surface: '#111' },
  radius: { sharp: 4 },
  spacing: { lg: 24, md: 16, sm: 8 },
}));
vi.mock('../../lib/format', () => ({ errorMessage: (e: any, fallback: string) => e?.message ?? fallback }));
vi.mock('../../lib/i18n', () => ({
  useI18n: () => ({
    t: (key: string, vars?: Record<string, unknown>) =>
      vars ? `${key}(${Object.entries(vars).map(([k, v]) => `${k}=${String(v)}`).join('|')})` : key,
  }),
}));

import StaffScreen from '../../app/(tabs)/staff';

function render() {
  return createRoot();
}
function output(r: ReturnType<typeof createRoot>) {
  return JSON.stringify(r.container.toJSON(), (key, value) => (key === 'anchor' ? '[Anchor]' : value));
}
function buttonByLabel(r: ReturnType<typeof createRoot>, label: string) {
  return r.container.queryAll((n) => n.type === 'Button').find((n) => JSON.stringify(n.toJSON(), (k, v) => (k === 'anchor' ? '[A]' : v)).includes(label));
}
function inputByPlaceholder(r: ReturnType<typeof createRoot>, placeholder: string) {
  return r.container.queryAll((n) => n.type === 'TextInput').find((n) => n.props.placeholder === placeholder);
}
function menuItemsByTitle(r: ReturnType<typeof createRoot>, title: string) {
  return r.container.queryAll((n) => n.type === 'Menu.Item').filter((n) => n.props.title === title);
}

describe('Staff screen', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    state.venue = { id: 'venue-1', name: 'The Fox & Vine' };
    state.me = { profile: { role: 'owner', allAccess: true } };
    state.canManage = true;
    state.profileLoading = false;
    state.staff = [];
    state.onboarding = undefined;
    state.auditLog = undefined;
    state.roles = [];
  });

  it('creates a staff member with the selected access level and trimmed phone', async () => {
    state.upsertStaff.mockResolvedValueOnce({});
    const r = render();
    await act(async () => r.render(<StaffScreen />));
    await act(async () => inputByPlaceholder(r, 'staff.fullNamePlaceholder')?.props.onChangeText('Jordan Lee'));
    await act(async () => inputByPlaceholder(r, 'staff.emailPlaceholder')?.props.onChangeText('jordan@example.com'));
    await act(async () => inputByPlaceholder(r, 'staff.phonePlaceholder')?.props.onChangeText('  555-0100  '));
    // Two dropdowns share the "staff.roleManager" option (invite link, then
    // the add-by-email access level) — the second is the one bound to `role`.
    await act(async () => menuItemsByTitle(r, 'staff.roleManager')[1]?.props.onPress());

    await act(async () => buttonByLabel(r, 'staff.addStaffMember')?.props.onPress());

    expect(state.upsertStaff).toHaveBeenCalledWith(expect.objectContaining({
      venueId: 'venue-1', fullName: 'Jordan Lee', email: 'jordan@example.com', role: 'manager', phone: '555-0100',
    }));
  });

  it('does not submit the staff form for a non-manager', async () => {
    state.canManage = false;
    const r = render();
    await act(async () => r.render(<StaffScreen />));
    await act(async () => inputByPlaceholder(r, 'staff.fullNamePlaceholder')?.props.onChangeText('Jordan Lee'));
    await act(async () => buttonByLabel(r, 'staff.addStaffMember')?.props.onPress());
    expect(state.upsertStaff).not.toHaveBeenCalled();
  });

  it('surfaces a failed staff save through an alert', async () => {
    state.upsertStaff.mockRejectedValueOnce(new Error('Email already in use'));
    const r = render();
    await act(async () => r.render(<StaffScreen />));
    await act(async () => inputByPlaceholder(r, 'staff.fullNamePlaceholder')?.props.onChangeText('Jordan Lee'));
    await act(async () => buttonByLabel(r, 'staff.addStaffMember')?.props.onPress());
    expect(state.alert).toHaveBeenCalledWith('staff.errorTitle', 'Email already in use');
  });

  it('adds a custom role and clears the input on success', async () => {
    state.addVenueRole.mockResolvedValueOnce({});
    const r = render();
    await act(async () => r.render(<StaffScreen />));
    await act(async () => inputByPlaceholder(r, 'staff.newRolePlaceholder')?.props.onChangeText('  Sommelier  '));
    await act(async () => buttonByLabel(r, 'staff.addRole')?.props.onPress());
    expect(state.addVenueRole).toHaveBeenCalledWith({ venueId: 'venue-1', name: 'Sommelier' });
    expect(inputByPlaceholder(r, 'staff.newRolePlaceholder')?.props.value).toBe('');
  });

  it('generates a staff invite link and shares it', async () => {
    state.createInvite.mockResolvedValueOnce({ inviteUrl: 'https://app.example.com/join?invite=abc' });
    state.share.mockResolvedValueOnce({});
    const r = render();
    await act(async () => r.render(<StaffScreen />));
    await act(async () => buttonByLabel(r, 'staff.generateShareLink')?.props.onPress());
    expect(state.createInvite).toHaveBeenCalledWith(expect.objectContaining({ venueId: 'venue-1', role: 'staff' }));
    expect(state.share).toHaveBeenCalledWith(expect.objectContaining({ message: expect.stringContaining('https://app.example.com/join?invite=abc') }));
    expect(output(r)).toContain('staff.inviteLinkGenerated');
  });

  it('restricts the invite link to staff access for a non-elevated manager', async () => {
    state.me = { profile: { role: 'manager', allAccess: false } };
    state.createInvite.mockResolvedValueOnce({ inviteUrl: 'https://app.example.com/x' });
    const r = render();
    await act(async () => r.render(<StaffScreen />));
    await act(async () => buttonByLabel(r, 'staff.generateShareLink')?.props.onPress());
    expect(state.createInvite).toHaveBeenCalledWith(expect.objectContaining({ role: 'staff' }));
  });

  it('confirms before deactivating a staff member and only deactivates after confirmation', async () => {
    state.staff = [{ _id: 's1', fullName: 'Casey Nguyen', email: 'casey@example.com', role: 'staff', jobTitle: 'Server', phone: null, altPhone: null, address: null, dateOfBirth: null, certifications: [], venueId: 'venue-1' }];
    state.deactivateStaff.mockResolvedValueOnce({});
    const r = render();
    await act(async () => r.render(<StaffScreen />));
    await act(async () => buttonByLabel(r, 'staff.deactivate')?.props.onPress());

    expect(state.alert).toHaveBeenCalled();
    expect(state.deactivateStaff).not.toHaveBeenCalled();
    const buttons = state.alert.mock.calls[0][2];
    const confirm = buttons.find((b: any) => b.style === 'destructive');
    await act(async () => confirm.onPress());
    expect(state.deactivateStaff).toHaveBeenCalledWith({ staffId: 's1' });
  });
});

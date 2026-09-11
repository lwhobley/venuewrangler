import React, { act } from 'react';
import { createRoot } from 'test-renderer';
import { beforeEach, describe, expect, it, vi } from 'vitest';

const mocks = vi.hoisted(() => ({
  state: { token: 'token-1', user: { email_verified: true }, setSession: vi.fn() },
  request: vi.fn(), t: (key: string) => key,
}));
vi.mock('../../lib/auth-store', () => ({ useAuthStore: Object.assign((select: any) => select(mocks.state), { getState: () => mocks.state }) }));
vi.mock('../../lib/api-client', () => ({ apiRequest: mocks.request }));
vi.mock('../../lib/i18n', () => ({ useI18n: () => ({ t: mocks.t }) }));
vi.mock('react-native-paper', async () => {
  const R = await import('react');
  const element = (name: string) => ({ children, ...props }: any) => R.createElement(name, props, children);
  return { Button: element('Button'), Text: element('Text'), Card: Object.assign(element('Card'), { Content: element('CardContent') }) };
});
import { WorkplaceAdoption } from '../../components/WorkplaceAdoption';

const candidate = { profileId: 'roster-1', venueName: 'Test Venue', role: 'staff' };
const response = { profile: { _id: 'roster-1', fullName: 'Test', email: 'test@example.test', emailVerified: true, role: 'staff', jobTitle: 'Staff', venueId: 'v1', allAccess: false }, venue: { _id: 'v1', name: 'Test Venue', latitude: 0, longitude: 0, geofenceRadiusM: 100 } };
const button = (root: any, suffix: string) => root.container.queryAll((node: any) => node.type === 'Button').find((node: any) => JSON.stringify(node.toJSON()).includes(suffix));

describe('workplace adoption consent', () => {
  beforeEach(() => { vi.clearAllMocks(); mocks.request.mockReset(); mocks.state.token = 'token-1'; mocks.request.mockResolvedValueOnce({ pendingAdoption: candidate }); });
  it('loads a candidate and refreshes the session only after explicit confirmation', async () => {
    const root = createRoot();
    await act(async () => root.render(<WorkplaceAdoption />));
    expect(mocks.state.setSession).not.toHaveBeenCalled();
    mocks.request.mockResolvedValueOnce(response);
    await act(async () => button(root, 'adoptionConfirm').props.onPress());
    expect(mocks.request).toHaveBeenLastCalledWith('/v1/auth/confirm-adoption', { method: 'POST', body: { profileId: 'roster-1' } });
    expect(mocks.state.setSession).toHaveBeenCalledWith(expect.objectContaining({ token: 'token-1', user: expect.objectContaining({ id: 'roster-1' }), venue: expect.objectContaining({ id: 'v1' }) }));
  });
  it('declines without mutating the server or session', async () => {
    const root = createRoot();
    await act(async () => root.render(<WorkplaceAdoption />));
    await act(async () => button(root, 'adoptionDecline').props.onPress());
    expect(mocks.request).toHaveBeenCalledTimes(1);
    expect(mocks.state.setSession).not.toHaveBeenCalled();
    expect(button(root, 'adoptionConfirm')).toBeUndefined();
  });
  it('keeps failed confirmation recoverable', async () => {
    const root = createRoot();
    await act(async () => root.render(<WorkplaceAdoption />));
    mocks.request.mockRejectedValueOnce(new Error('Connection no longer available'));
    await act(async () => button(root, 'adoptionConfirm').props.onPress());
    expect(JSON.stringify(root.container.toJSON())).toContain('Connection no longer available');
    expect(mocks.state.setSession).not.toHaveBeenCalled();
  });
});

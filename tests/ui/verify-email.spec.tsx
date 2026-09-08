import React, { act } from 'react';
import { createRoot } from 'test-renderer';
import { beforeEach, describe, expect, it, vi } from 'vitest';

const state = vi.hoisted(() => ({
  params: {} as Record<string, string>,
  user: { id: 'u1', email: 'operator@example.com', email_verified: false },
  venue: null as null | { id: string },
  verify: vi.fn(), redeem: vi.fn(), redeemMine: vi.fn(), resend: vi.fn(),
  setSession: vi.fn(), clearSession: vi.fn(), replace: vi.fn(), alert: vi.fn(),
}));
vi.mock('expo-router', () => ({ router: { replace: state.replace }, useLocalSearchParams: () => state.params }));
vi.mock('react-native', () => ({
  Alert: { alert: state.alert }, KeyboardAvoidingView: 'KeyboardAvoidingView',
  Platform: { OS: 'ios' }, ScrollView: 'ScrollView', View: 'View', StyleSheet: { create: (s: unknown) => s },
}));
vi.mock('react-native-paper', async () => {
  const R = await import('react');
  const element = (type: string) => ({ children, ...props }: any) => R.createElement(type, props, children);
  return { Button: element('Button'), Text: element('Text'), TextInput: element('TextInput'),
    Card: Object.assign(element('Card'), { Content: element('Card.Content') }) };
});
vi.mock('../../components/AppCard', () => ({ Kicker: 'Kicker' }));
vi.mock('../../lib/api-client', () => ({ appApi: {
  verifyEmail: state.verify, redeemInvite: state.redeem, redeemMyInvite: state.redeemMine, resendVerification: state.resend,
} }));
vi.mock('../../lib/session-from-auth', () => ({ userFromProfile: (p: unknown) => p, venueFromAuth: (_p: unknown, v: unknown) => v }));
vi.mock('../../lib/auth-store', () => ({ useAuthStore: (select: (s: any) => unknown) => select({
  user: state.user, venue: state.venue, token: 'test-token', setSession: state.setSession, clearSession: state.clearSession,
}) }));
vi.mock('../../lib/i18n', () => ({ useI18n: () => ({ t: (key: string) => key }) }));
vi.mock('../../lib/theme', () => ({ authCardStyle: {}, authColors: {}, authInputProps: {}, spacing: {}, type: {} }));
import VerifyEmailScreen from '../../app/(auth)/verify-email';

function button(r: ReturnType<typeof createRoot>, label: string) {
  const result = r.container.queryAll(n => n.type === 'Button').find(n => JSON.stringify(n.toJSON()).includes(label));
  expect(result, `Missing ${label} button`).toBeDefined();
  return result!;
}
async function render(code = '12345678') {
  const r = createRoot();
  await act(async () => r.render(<VerifyEmailScreen />));
  await act(async () => r.container.queryAll(n => n.type === 'TextInput')[0].props.onChangeText(code));
  return r;
}
describe('Email verification recovery', () => {
  beforeEach(() => {
    vi.resetAllMocks(); state.params = {}; state.venue = null;
    state.verify.mockResolvedValue({}); state.redeemMine.mockResolvedValue({ redeemed: false });
    state.resend.mockResolvedValue({});
  });
  it('does not send an empty verification code', async () => {
    const r = await render('  ');
    await act(async () => button(r, 'verifyEmail.verifyButton').props.onPress());
    expect(state.verify).not.toHaveBeenCalled();
    expect(state.alert).toHaveBeenCalledWith('verifyEmail.codeRequiredTitle', 'verifyEmail.codeRequiredMessage');
  });
  it('marks the session verified and sends an owner to team setup', async () => {
    const r = await render();
    await act(async () => button(r, 'verifyEmail.verifyButton').props.onPress());
    expect(state.verify).toHaveBeenCalledWith({ code: '12345678' });
    expect(state.setSession).toHaveBeenCalledWith(expect.objectContaining({ user: expect.objectContaining({ email_verified: true }) }));
    expect(state.replace).toHaveBeenCalledWith('/(auth)/team-choice');
  });
  it('does not redeem an invite after an invalid code', async () => {
    state.verify.mockRejectedValueOnce(new Error('Invalid code'));
    const r = await render();
    await act(async () => button(r, 'verifyEmail.verifyButton').props.onPress());
    expect(state.redeemMine).not.toHaveBeenCalled();
    expect(state.setSession).not.toHaveBeenCalled();
    expect(state.alert).toHaveBeenCalledWith('verifyEmail.verifyFailedTitle', 'Invalid code');
  });
  it('retries team joining without submitting an already-consumed code', async () => {
    state.verify.mockResolvedValueOnce({}).mockRejectedValue(new Error('Code already used'));
    state.redeemMine.mockRejectedValueOnce(new Error('Network interrupted')).mockResolvedValue({ redeemed: false });
    const r = await render();
    await act(async () => button(r, 'verifyEmail.verifyButton').props.onPress());
    expect(state.replace).not.toHaveBeenCalled();
    await act(async () => button(r, 'verifyEmail.verifyButton').props.onPress());
    expect(state.verify).toHaveBeenCalledTimes(1);
    expect(state.redeemMine).toHaveBeenCalledTimes(2);
    expect(state.replace).toHaveBeenCalledWith('/(auth)/team-choice');
  });
  it('preserves explicit invite redemption and the welcome action', async () => {
    state.params = { invite: 'invite-1' };
    state.redeem.mockResolvedValue({ redeemed: true, profile: { id: 'p1' }, venue: { id: 'v1', name: 'North Room' } });
    const r = await render();
    await act(async () => button(r, 'verifyEmail.verifyButton').props.onPress());
    expect(state.redeem).toHaveBeenCalledWith('invite-1');
    expect(state.redeemMine).not.toHaveBeenCalled();
    expect(state.setSession).toHaveBeenCalledWith(expect.objectContaining({ venue: { id: 'v1', name: 'North Room' } }));
    const actions = state.alert.mock.calls[0][2];
    actions[0].onPress();
    expect(state.replace).toHaveBeenCalledWith('/(tabs)/home');
  });
  it('blocks duplicate resend requests and permits retry after failure', async () => {
    let reject!: (error: Error) => void;
    state.resend.mockImplementationOnce(() => new Promise((_resolve, fail) => { reject = fail; }));
    const r = await render();
    await act(async () => { const b = button(r, 'verifyEmail.resendButton'); b.props.onPress(); b.props.onPress(); });
    expect(state.resend).toHaveBeenCalledTimes(1);
    await act(async () => reject(new Error('Offline')));
    await act(async () => button(r, 'verifyEmail.resendButton').props.onPress());
    expect(state.resend).toHaveBeenCalledTimes(2);
    expect(state.alert).toHaveBeenLastCalledWith('verifyEmail.resendSuccessTitle', 'verifyEmail.resendSuccessMessage');
  });
});

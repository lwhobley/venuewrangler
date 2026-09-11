import React, { act } from 'react';
import { createRoot } from 'test-renderer';
import { beforeEach, describe, expect, it, vi } from 'vitest';

const state = vi.hoisted(() => ({
  forgotPassword: vi.fn(),
  resetPassword: vi.fn(),
  replace: vi.fn(),
  back: vi.fn(),
  alert: vi.fn(),
}));

vi.mock('react-native', () => ({
  Alert: { alert: state.alert }, KeyboardAvoidingView: 'KeyboardAvoidingView', Platform: { OS: 'ios' },
  ScrollView: 'ScrollView', StyleSheet: { create: (s: unknown) => s }, View: 'View',
}));
vi.mock('expo-router', () => ({ router: { replace: state.replace, back: state.back } }));
vi.mock('react-native-paper', async () => {
  const R = await import('react');
  const element = (type: string) => ({ children, ...props }: any) => R.createElement(type, props, children);
  const Card = Object.assign(element('Card'), { Content: element('Card.Content') });
  return { Button: element('Button'), Card, Text: element('Text'), TextInput: element('TextInput') };
});
vi.mock('../../components/AppCard', () => ({ Kicker: ({ children }: any) => children }));
vi.mock('../../lib/api-client', () => ({ appApi: { forgotPassword: state.forgotPassword, resetPassword: state.resetPassword } }));
vi.mock('../../lib/theme', () => ({
  authCardStyle: {}, authColors: { background: '#000', text: '#fff', muted: '#777', primary: '#0f0', buttonText: '#fff' },
  authInputProps: {}, spacing: { lg: 24, md: 16 }, type: { title: {} },
}));
vi.mock('../../lib/i18n', () => ({
  useI18n: () => ({
    t: (key: string, vars?: Record<string, unknown>) =>
      vars ? `${key}(${Object.entries(vars).map(([k, v]) => `${k}=${String(v)}`).join('|')})` : key,
  }),
}));

import ResetPasswordScreen from '../../app/(auth)/reset-password';

function render() {
  return createRoot();
}
function buttonByLabel(r: ReturnType<typeof createRoot>, label: string) {
  return r.container.queryAll((n) => n.type === 'Button').find((n) => JSON.stringify(n.toJSON()).includes(label));
}
function inputByLabel(r: ReturnType<typeof createRoot>, label: string) {
  return r.container.queryAll((n) => n.type === 'TextInput').find((n) => n.props.label === label);
}

describe('Reset password screen', () => {
  beforeEach(() => vi.clearAllMocks());

  it('requires a valid email before sending a reset code', async () => {
    const r = render();
    await act(async () => r.render(<ResetPasswordScreen />));
    await act(async () => inputByLabel(r, 'resetPassword.emailLabel')?.props.onChangeText('not-an-email'));
    await act(async () => buttonByLabel(r, 'resetPassword.sendCodeButton')?.props.onPress());
    expect(state.forgotPassword).not.toHaveBeenCalled();
    expect(state.alert).toHaveBeenCalledWith('resetPassword.emailRequiredTitle', 'resetPassword.emailRequiredMessage');
  });

  it('sends a reset code for a valid email', async () => {
    state.forgotPassword.mockResolvedValueOnce({});
    const r = render();
    await act(async () => r.render(<ResetPasswordScreen />));
    await act(async () => inputByLabel(r, 'resetPassword.emailLabel')?.props.onChangeText(' person@example.com '));
    await act(async () => buttonByLabel(r, 'resetPassword.sendCodeButton')?.props.onPress());
    expect(state.forgotPassword).toHaveBeenCalledWith({ email: 'person@example.com' });
    expect(state.alert).toHaveBeenCalledWith('resetPassword.codeSentTitle', 'resetPassword.codeSentMessage');
  });

  it('blocks reset with a short password', async () => {
    const r = render();
    await act(async () => r.render(<ResetPasswordScreen />));
    await act(async () => inputByLabel(r, 'resetPassword.emailLabel')?.props.onChangeText('person@example.com'));
    await act(async () => inputByLabel(r, 'resetPassword.codeLabel')?.props.onChangeText('123456'));
    await act(async () => inputByLabel(r, 'resetPassword.newPasswordLabel')?.props.onChangeText('short'));
    await act(async () => buttonByLabel(r, 'resetPassword.resetButton')?.props.onPress());
    expect(state.resetPassword).not.toHaveBeenCalled();
    expect(state.alert).toHaveBeenCalledWith('resetPassword.resetRequiredTitle', 'resetPassword.resetRequiredMessage');
  });

  it('resets the password and navigates to welcome on success', async () => {
    state.resetPassword.mockResolvedValueOnce({});
    const r = render();
    await act(async () => r.render(<ResetPasswordScreen />));
    await act(async () => inputByLabel(r, 'resetPassword.emailLabel')?.props.onChangeText('person@example.com'));
    await act(async () => inputByLabel(r, 'resetPassword.codeLabel')?.props.onChangeText('123456'));
    await act(async () => inputByLabel(r, 'resetPassword.newPasswordLabel')?.props.onChangeText('newpassword123'));
    await act(async () => buttonByLabel(r, 'resetPassword.resetButton')?.props.onPress());
    expect(state.resetPassword).toHaveBeenCalledWith({ email: 'person@example.com', code: '123456', newPassword: 'newpassword123' });
    expect(state.replace).toHaveBeenCalledWith('/(auth)/welcome');
  });

  it('reports a failed reset rather than navigating away', async () => {
    state.resetPassword.mockRejectedValueOnce(new Error('Invalid or expired code'));
    const r = render();
    await act(async () => r.render(<ResetPasswordScreen />));
    await act(async () => inputByLabel(r, 'resetPassword.emailLabel')?.props.onChangeText('person@example.com'));
    await act(async () => inputByLabel(r, 'resetPassword.codeLabel')?.props.onChangeText('123456'));
    await act(async () => inputByLabel(r, 'resetPassword.newPasswordLabel')?.props.onChangeText('newpassword123'));
    await act(async () => buttonByLabel(r, 'resetPassword.resetButton')?.props.onPress());
    expect(state.alert).toHaveBeenCalledWith('resetPassword.resetFailedTitle', 'Invalid or expired code');
    expect(state.replace).not.toHaveBeenCalled();
  });

  it('navigates back', async () => {
    const r = render();
    await act(async () => r.render(<ResetPasswordScreen />));
    await act(async () => buttonByLabel(r, 'resetPassword.back')?.props.onPress());
    expect(state.back).toHaveBeenCalled();
  });
});

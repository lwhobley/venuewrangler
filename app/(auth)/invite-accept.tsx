import { useRef, useState } from 'react';
import {
  Alert,
  KeyboardAvoidingView,
  Linking,
  Platform,
  ScrollView,
  StyleSheet,
  View,
} from 'react-native';
import { router, useLocalSearchParams } from 'expo-router';
import { notifySuccess } from '../../lib/feedback';
import { Button, Card, Checkbox, Text, TextInput } from 'react-native-paper';
import { appApi } from '../../lib/api-client';
import { userFromProfile, venueFromAuth } from '../../lib/session-from-auth';
import { authCardStyle, authColors as colors, authInputProps as inputProps, spacing, type } from '../../lib/theme';
import { Kicker } from '../../components/AppCard';
import { useAuthStore, type AuthState } from '../../lib/auth-store';
import { useI18n } from '../../lib/i18n';

export default function InviteAcceptScreen() {
  const { t } = useI18n();
  const setSession = useAuthStore((s: AuthState) => s.setSession);
  const clearSession = useAuthStore((s: AuthState) => s.clearSession);

  const { token, venueName, jobTitle, phone } = useLocalSearchParams<{
    token: string;
    venueName: string;
    jobTitle: string;
    phone?: string;
  }>();

  const [fullName, setFullName] = useState('');
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [confirmPassword, setConfirmPassword] = useState('');
  const [termsAccepted, setTermsAccepted] = useState(false);
  const [submitting, setSubmitting] = useState(false);
  const submittingRef = useRef(false);
  const [error, setError] = useState<string | null>(null);

  const validate = (): string | null => {
    if (!fullName.trim()) return t('inviteAccept.errors.nameRequired');
    if (!email.trim().includes('@')) return t('inviteAccept.errors.invalidEmail');
    if (password.length < 8) return t('inviteAccept.errors.passwordLength');
    if (password !== confirmPassword) return t('inviteAccept.errors.passwordMismatch');
    if (!termsAccepted) return t('register.errors.termsRequired');
    return null;
  };

  const submit = async () => {
    if (submittingRef.current) return;
    const err = validate();
    if (err) { setError(err); return; }
    setError(null);
    submittingRef.current = true;
    setSubmitting(true);
    try {
      clearSession();
      const resp = await appApi.passwordAuth({
        email: email.trim(),
        phone,
        password,
        flow: 'signUp',
        fullName: fullName.trim(),
        inviteToken: token,
        termsAccepted,
      });
      const { profile, venue, token: authToken } = resp;
      setSession({
        user: userFromProfile(profile),
        venue: venueFromAuth(profile, venue),
        token: authToken,
      });
      notifySuccess();
      // Route to email verification — verify-email.tsx will call redeemInvite
      // with the invite token after code confirmation to finalize team membership.
      if (!profile.emailVerified) {
        const emailSendFailed = (resp as { verificationEmailSent?: boolean | null }).verificationEmailSent === false;
        router.replace({ pathname: '/(auth)/verify-email', params: {
          invite: token,
          ...(emailSendFailed ? { emailSendFailed: '1' } : {}),
        } });
      } else {
        router.replace('/(tabs)/home');
      }
    } catch (e) {
      const msg = e instanceof Error ? e.message : t('inviteAccept.genericError');
      setError(msg);
      Alert.alert(t('inviteAccept.createAccountFailedTitle'), msg);
    } finally {
      submittingRef.current = false;
      setSubmitting(false);
    }
  };

  return (
    <KeyboardAvoidingView
      style={{ flex: 1, backgroundColor: colors.background }}
      behavior={Platform.OS === 'ios' ? 'padding' : undefined}
    >
      <ScrollView
        contentContainerStyle={{
          flexGrow: 1,
          padding: spacing.lg,
          justifyContent: 'center',
          gap: spacing.md,
        }}
      >
        {/* Progress indicator */}
        <View style={styles.stepRow}>
          <View style={[styles.step, styles.stepDone]} />
          <View style={[styles.step, styles.stepActive]} />
        </View>

        <View style={{ gap: 6 }}>
          <Kicker>{t('inviteAccept.kicker')}</Kicker>
          <Text style={{ ...type.title, color: colors.text }}>
            {venueName}
          </Text>
          <Text variant="bodyMedium" style={{ color: colors.muted }}>
            {t('inviteAccept.roleLine', { jobTitle })}
          </Text>
        </View>

        <Card style={styles.card}>
          <Card.Content style={{ gap: spacing.md }}>
            {error ? (
              <Text style={{ color: colors.danger, textAlign: 'center' }}>{error}</Text>
            ) : null}

            <TextInput
              {...inputProps}
              label={t('inviteAccept.nameLabel')}
              value={fullName}
              onChangeText={setFullName}
              mode="outlined"
            />
            <TextInput
              {...inputProps}
              label={t('inviteAccept.emailLabel')}
              value={email}
              onChangeText={setEmail}
              autoCapitalize="none"
              keyboardType="email-address"
              mode="outlined"
            />
            <TextInput
              {...inputProps}
              label={t('inviteAccept.passwordLabel')}
              value={password}
              onChangeText={setPassword}
              secureTextEntry
              mode="outlined"
            />
            <TextInput
              {...inputProps}
              label={t('inviteAccept.confirmPasswordLabel')}
              value={confirmPassword}
              onChangeText={setConfirmPassword}
              secureTextEntry
              mode="outlined"
              returnKeyType="go"
              onSubmitEditing={() => void submit()}
            />
            <View style={{ flexDirection: 'row', alignItems: 'center', gap: 4 }}>
              <Checkbox status={termsAccepted ? 'checked' : 'unchecked'} onPress={() => setTermsAccepted((value) => !value)} color={colors.primary} />
              <Text style={{ color: colors.muted, fontSize: 12, flex: 1 }}>
                {t('register.termsPrefix')}{' '}
                <Text style={{ color: colors.primary }} onPress={() => void Linking.openURL('https://www.venuewrangler.com/terms')}>
                  {t('register.termsOfService')}
                </Text>{' '}{t('register.and')}{' '}
                <Text style={{ color: colors.primary }} onPress={() => void Linking.openURL('https://www.venuewrangler.com/privacy')}>
                  {t('register.privacyPolicy')}
                </Text>
              </Text>
            </View>

            <Button
              mode="contained"
              buttonColor={colors.primary}
              textColor={colors.buttonText}
              loading={submitting}
              disabled={submitting}
              onPress={() => void submit()}
            >
              {t('inviteAccept.acceptButton')}
            </Button>

            <Text style={{ color: colors.muted, fontSize: 12, textAlign: 'center' }}>
              {t('inviteAccept.alreadyHaveAccount')}{' '}
              <Text
                style={{ color: colors.primary, fontWeight: '600' }}
                onPress={() =>
                  router.replace({
                    pathname: '/(auth)/sign-in',
                    params: { invite: token, phone },
                  })
                }
              >
                {t('inviteAccept.signInInstead')}
              </Text>
            </Text>
          </Card.Content>
        </Card>

        <Button mode="text" textColor={colors.muted} onPress={() => router.back()}>
          {t('inviteAccept.back')}
        </Button>
      </ScrollView>
    </KeyboardAvoidingView>
  );
}

const styles = StyleSheet.create({
  stepRow: { flexDirection: 'row', gap: 6, marginBottom: 4 },
  step: { flex: 1, height: 4, borderRadius: 2, backgroundColor: colors.border },
  stepActive: { backgroundColor: colors.primary },
  stepDone: { backgroundColor: colors.primary, opacity: 0.45 },
  card: {
    ...authCardStyle,
  },
});

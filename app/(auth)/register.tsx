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
import { Redirect, router, useLocalSearchParams } from 'expo-router';
import { notifySuccess } from '../../lib/feedback';
import { Button, Card, Checkbox, Text, TextInput } from 'react-native-paper';
import { appApi } from '../../lib/api-client';
import { userFromProfile, venueFromAuth } from '../../lib/session-from-auth';
import { authCardStyle, authColors as colors, authInputProps as inputProps, spacing, type } from '../../lib/theme';
import { Kicker } from '../../components/AppCard';
import { useAuthStore, type AuthState } from '../../lib/auth-store';
import { useI18n } from '../../lib/i18n';

export default function RegisterScreen() {
  const { t } = useI18n();
  const setSession = useAuthStore((s: AuthState) => s.setSession);
  const clearSession = useAuthStore((s: AuthState) => s.clearSession);
  const params = useLocalSearchParams<{ email?: string; venueName?: string; inviteFound?: string; mobile?: string }>();

  const [firstName, setFirstName] = useState('');
  const [lastName, setLastName] = useState('');
  const [email, setEmail] = useState(typeof params.email === 'string' ? params.email : '');
  const [mobile, setMobile] = useState(typeof params.mobile === 'string' ? params.mobile : '');
  const [password, setPassword] = useState('');
  const [confirmPassword, setConfirmPassword] = useState('');
  const [termsAccepted, setTermsAccepted] = useState(false);
  const [submitting, setSubmitting] = useState(false);
  const submittingRef = useRef(false);
  const [errors, setErrors] = useState<Record<string, string>>({});
  const hasInvite = params.inviteFound === '1' && Boolean(params.email);

  if (!hasInvite) return <Redirect href="/(auth)/invite-check" />;

  const validate = (): boolean => {
    const next: Record<string, string> = {};
    if (!firstName.trim()) next.firstName = t('register.errors.required');
    if (!lastName.trim()) next.lastName = t('register.errors.required');
    if (!email.trim().includes('@')) next.email = t('register.errors.invalidEmail');
    if (password.length < 8) next.password = t('register.errors.passwordLength');
    if (password !== confirmPassword) next.confirmPassword = t('register.errors.passwordMismatch');
    if (!termsAccepted) next.terms = t('register.errors.termsRequired');
    setErrors(next);
    return Object.keys(next).length === 0;
  };

  const submit = async () => {
    // Ref, not state: two taps in one tick both passed the state check, and the
    // second hit an already-registered email — showing a "failed" alert over a
    // signup that had in fact succeeded and was already navigating away.
    if (submittingRef.current) return;
    if (!validate()) return;
    submittingRef.current = true;
    setSubmitting(true);
    try {
      clearSession();
      const resp = await appApi.passwordAuth({
        email: email.trim(),
        phone: mobile.trim() || undefined,
        password,
        flow: 'signUp',
        fullName: `${firstName.trim()} ${lastName.trim()}`.trim(),
        termsAccepted,
      });
      const { profile, venue, token } = resp;
      setSession({
        user: userFromProfile(profile),
        venue: venueFromAuth(profile, venue),
        token,
      });
      notifySuccess();
      // Always verify email first — verify-email.tsx calls redeemMyInvite after
      // the code is confirmed, which will automatically claim the unclaimed staff
      // profile and link this account to the venue.
      if (!profile.emailVerified) {
        // The server reports whether the code actually went out. It used to
        // swallow a delivery failure silently, so people were sent to wait for
        // an email that was never sent, with no way to tell that from a slow
        // one. `emailSendFailed` makes the next screen say so and lead with
        // Resend.
        const emailSendFailed = (resp as { verificationEmailSent?: boolean | null }).verificationEmailSent === false;
        router.replace(emailSendFailed ? '/(auth)/verify-email?emailSendFailed=1' : '/(auth)/verify-email');
      } else if (venue) {
        router.replace('/(tabs)/home');
      } else {
        router.replace('/(auth)/team-choice');
      }
    } catch (e) {
      const msg = e instanceof Error ? e.message : t('register.genericError');
      Alert.alert(t('register.createAccountFailedTitle'), msg);
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
          gap: spacing.md,
          paddingTop: spacing.xl,
        }}
      >
        {/* Progress */}
        <View style={styles.stepRow}>
          <View style={[styles.step, styles.stepActive]} />
          <View style={styles.step} />
        </View>

        <View style={{ gap: 4 }}>
          <Kicker>{t('register.kicker')}</Kicker>
          <Text style={{ ...type.title, color: colors.text }}>
            {t('register.title')}
          </Text>
          <Text variant="bodyMedium" style={{ color: colors.muted }}>
            {params.inviteFound === '1' && params.venueName
              ? t('register.subtitleInvite', { venueName: params.venueName })
              : t('register.subtitleDefault')}
          </Text>
        </View>

        <Card style={styles.card}>
          <Card.Content style={{ gap: spacing.sm }}>
            <View style={{ flexDirection: 'row', gap: spacing.sm }}>
              <View style={{ flex: 1 }}>
                <TextInput
                  {...inputProps}
                  label={t('register.firstNameLabel')}
                  value={firstName}
                  onChangeText={setFirstName}
                  mode="outlined"
                  error={Boolean(errors.firstName)}
                />
                {errors.firstName ? (
                  <Text style={styles.fieldError}>{errors.firstName}</Text>
                ) : null}
              </View>
              <View style={{ flex: 1 }}>
                <TextInput
                  {...inputProps}
                  label={t('register.lastNameLabel')}
                  value={lastName}
                  onChangeText={setLastName}
                  mode="outlined"
                  error={Boolean(errors.lastName)}
                />
                {errors.lastName ? (
                  <Text style={styles.fieldError}>{errors.lastName}</Text>
                ) : null}
              </View>
            </View>

            <View>
              <TextInput
                {...inputProps}
                label={t('register.emailLabel')}
                value={email}
                onChangeText={setEmail}
                autoCapitalize="none"
                keyboardType="email-address"
                mode="outlined"
                error={Boolean(errors.email)}
              />
              {errors.email ? (
                <Text style={styles.fieldError}>{errors.email}</Text>
              ) : null}
            </View>

            <TextInput
              {...inputProps}
              label={t('register.mobileLabel')}
              value={mobile}
              onChangeText={setMobile}
              keyboardType="phone-pad"
              mode="outlined"
            />

            <View>
              <TextInput
                {...inputProps}
                label={t('register.passwordLabel')}
                value={password}
                onChangeText={setPassword}
                secureTextEntry
                mode="outlined"
                error={Boolean(errors.password)}
              />
              {errors.password ? (
                <Text style={styles.fieldError}>{errors.password}</Text>
              ) : null}
            </View>

            <View>
              <TextInput
                {...inputProps}
                label={t('register.confirmPasswordLabel')}
                value={confirmPassword}
                onChangeText={setConfirmPassword}
                secureTextEntry
                mode="outlined"
                error={Boolean(errors.confirmPassword)}
                returnKeyType="go"
                onSubmitEditing={() => void submit()}
              />
              {errors.confirmPassword ? (
                <Text style={styles.fieldError}>{errors.confirmPassword}</Text>
              ) : null}
            </View>

            <View style={{ flexDirection: 'row', alignItems: 'center', gap: 4, marginTop: 4 }}>
              <Checkbox
                status={termsAccepted ? 'checked' : 'unchecked'}
                onPress={() => setTermsAccepted((v) => !v)}
                color={colors.primary}
              />
              <Text variant="bodySmall" style={{ flex: 1, color: colors.muted }}>
                {t('register.termsPrefix')}{' '}
                <Text
                  style={{ color: colors.primary }}
                  onPress={() => void Linking.openURL('https://www.venuewrangler.com/terms')}
                >
                  {t('register.termsOfService')}
                </Text>{' '}
                {t('register.and')}{' '}
                <Text
                  style={{ color: colors.primary }}
                  onPress={() => void Linking.openURL('https://www.venuewrangler.com/privacy')}
                >
                  {t('register.privacyPolicy')}
                </Text>
              </Text>
            </View>
            {errors.terms ? (
              <Text style={styles.fieldError}>{errors.terms}</Text>
            ) : null}

            <Button
              mode="contained"
              buttonColor={colors.primary}
              textColor={colors.buttonText}
              loading={submitting}
              disabled={submitting}
              onPress={() => void submit()}
              style={{ marginTop: spacing.sm }}
            >
              {t('register.createAccountButton')}
            </Button>
          </Card.Content>
        </Card>

        <Button mode="text" textColor={colors.muted} onPress={() => router.back()}>
          {t('register.back')}
        </Button>
      </ScrollView>
    </KeyboardAvoidingView>
  );
}

const styles = StyleSheet.create({
  stepRow: { flexDirection: 'row', gap: 6, marginBottom: 4 },
  step: { flex: 1, height: 4, borderRadius: 2, backgroundColor: colors.border },
  stepActive: { backgroundColor: colors.primary },
  fieldError: { color: colors.danger, fontSize: 12, marginTop: 2, marginLeft: 4 },
  card: {
    ...authCardStyle,
  },
});

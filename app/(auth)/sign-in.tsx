import { useEffect, useRef, useState } from 'react';
import { Alert, Image, KeyboardAvoidingView, Linking, Platform, ScrollView, StyleSheet, View } from 'react-native';
import { router, useLocalSearchParams } from 'expo-router';
import { notifySuccess } from '../../lib/feedback';
import { Button, Card, Checkbox, Chip, SegmentedButtons, Text, TextInput } from 'react-native-paper';
import { appApi } from '../../lib/api-client';
import { userFromProfile, venueFromAuth } from '../../lib/session-from-auth';
import { authCardStyle, authColors, spacing, type } from '../../lib/theme';
import { Kicker } from '../../components/AppCard';
import { useAuthStore, type AuthState } from '../../lib/auth-store';
import { useI18n } from '../../lib/i18n';

type InvitePreview = { expired?: boolean; venueName?: string };

const logoSource = require('../../assets/venue-wrangler-logo.jpg');

export default function SignInScreen() {
  const setSession = useAuthStore((state: AuthState) => state.setSession);
  const clearSession = useAuthStore((state: AuthState) => state.clearSession);
  const { t } = useI18n();

  const authInputProps = {
    outlineColor: authColors.border,
    activeOutlineColor: authColors.primary,
    textColor: authColors.text,
    placeholderTextColor: authColors.muted,
    style: { backgroundColor: authColors.surface },
  };
  const authControlTheme = {
    colors: {
      primary: authColors.primary,
      secondaryContainer: authColors.highlight,
      onSecondaryContainer: authColors.text,
      onSurface: authColors.text,
      outline: authColors.border,
    },
  };

  const { invite: inviteParam, phone: phoneParam, tab } = useLocalSearchParams<{ invite?: string; phone?: string; tab?: string }>();
  const inviteToken = typeof inviteParam === 'string' ? inviteParam : undefined;
  const invitePhone = typeof phoneParam === 'string' ? phoneParam : undefined;
  const [invitePreview, setInvitePreview] = useState<InvitePreview | null>(null);

  useEffect(() => {
    if (!inviteToken) {
      setInvitePreview(null);
      return;
    }
    let cancelled = false;
    appApi.previewInvite(inviteToken)
      .then((result) => {
        if (cancelled) return;
        setInvitePreview({ venueName: result.venueName });
      })
      .catch(() => {
        if (cancelled) return;
        setInvitePreview({ expired: true });
      });
    return () => {
      cancelled = true;
    };
  }, [inviteToken]);

  const [flow, setFlow] = useState<'signIn' | 'signUp'>(inviteToken && tab !== 'signIn' ? 'signUp' : 'signIn');
  const [fullName, setFullName] = useState('');
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [termsAccepted, setTermsAccepted] = useState(false);
  const [submitting, setSubmitting] = useState(false);
  const submittingRef = useRef(false);
  const [formError, setFormError] = useState<string | null>(null);

  const showError = (title: string, message: string) => {
    setFormError(message);
    Alert.alert(title, message);
  };

  const finishSession = async (options?: { inviteToken?: string }) => {
    const last = await appApi.passwordAuth({
      email: email.trim(),
      phone: invitePhone,
      password,
      flow,
      fullName: fullName.trim() || undefined,
      inviteToken: options?.inviteToken,
      termsAccepted: flow === 'signUp' ? termsAccepted : undefined,
    });

    const { profile, venue, token } = last;
    setSession({
      user: userFromProfile(profile),
      venue: venueFromAuth(profile, venue),
      token,
    });
    notifySuccess();
    // Any unverified account must return to verification, including a user who
    // closed the app midway through invited signup and signs in again later.
    // verify-email.tsx calls redeemInvite / redeemMyInvite after code entry
    // to finalize venue membership before taking the user into the app.
    if (!profile.emailVerified) {
      const emailSendFailed = (last as { verificationEmailSent?: boolean | null }).verificationEmailSent === false;
      if (options?.inviteToken || emailSendFailed) {
        router.replace({ pathname: '/(auth)/verify-email', params: {
          ...(options?.inviteToken ? { invite: options.inviteToken } : {}),
          ...(emailSendFailed ? { emailSendFailed: '1' } : {}),
        } });
      } else {
        router.replace('/(auth)/verify-email');
      }
    } else {
      router.replace(venue ? '/(tabs)/home' : '/(auth)/team-choice');
    }
  };

  const resetExistingSession = () => {
    clearSession();
  };

  const submit = async () => {
    if (submittingRef.current) return;
    const trimmed = email.trim();
    const minPasswordLength = flow === 'signUp' ? 8 : 6;
    if (!trimmed.includes('@') || password.trim().length < minPasswordLength) {
      Alert.alert(t('signIn.invalidDetailsTitle'), t('signIn.invalidDetailsMessage', { count: minPasswordLength }));
      return;
    }
    if (flow === 'signUp' && !fullName.trim()) {
      Alert.alert(t('signIn.nameRequiredTitle'), t('signIn.nameRequiredMessage'));
      return;
    }
    if (flow === 'signUp' && !termsAccepted) {
      Alert.alert(t('signIn.invalidDetailsTitle'), t('register.errors.termsRequired'));
      return;
    }
    submittingRef.current = true;
    setSubmitting(true);
    setFormError(null);
    try {
      resetExistingSession();
      await finishSession({ inviteToken });
    } catch (e) {
      showError(
        flow === 'signUp' ? t('signIn.createAccountFailedTitle') : t('signIn.signInFailedTitle'),
        e instanceof Error ? e.message : t('signIn.tryAgain'),
      );
    } finally {
      submittingRef.current = false;
      setSubmitting(false);
    }
  };

  const inviteBanner = inviteToken && invitePreview && !invitePreview.expired ? (
    <View style={{ alignItems: 'center', gap: 6, marginBottom: spacing.sm }}>
      <Text variant="titleMedium" style={{ fontWeight: '700', color: authColors.primary, textAlign: 'center' }}>
        {t('signIn.inviteBannerTitle')}
      </Text>
      <Text variant="titleLarge" style={{ fontWeight: '800', textAlign: 'center', color: authColors.text }}>
        {invitePreview.venueName}
      </Text>
    </View>
  ) : null;

  return (
    <KeyboardAvoidingView style={{ flex: 1, backgroundColor: authColors.background }} behavior={Platform.OS === 'ios' ? 'padding' : undefined}>
      <ScrollView contentContainerStyle={{ flexGrow: 1, padding: spacing.lg, justifyContent: 'center', gap: spacing.md }}>
        <View style={{ marginBottom: spacing.sm, alignItems: 'center', gap: 10 }}>
          <Image source={logoSource} style={styles.logo} />
          <Kicker>{flow === 'signUp' ? t('signIn.kickerSignUp') : t('signIn.kickerSignIn')}</Kicker>
          <Text style={{ ...type.title, color: authColors.text }}>{t('signIn.brand')}</Text>
          {!inviteToken ? (
            <Text variant="bodyMedium" style={{ color: authColors.muted, marginTop: 6, textAlign: 'center' }}>
              {t('signIn.subtitle')}
            </Text>
          ) : null}
        </View>

        <Card style={styles.authCard}>
          <Card.Content style={{ gap: spacing.md }}>
            {inviteBanner}
            {inviteToken ? (
              <Text style={{ color: authColors.muted, textAlign: 'center', marginBottom: spacing.sm }}>
                {t('signIn.inviteInstructions')}
              </Text>
            ) : null}
            {formError ? (
              <Text style={{ color: authColors.danger, textAlign: 'center' }}>{formError}</Text>
            ) : null}

            {inviteToken ? (
              <SegmentedButtons
                theme={authControlTheme}
                value={flow}
                onValueChange={(v) => setFlow(v as 'signIn' | 'signUp')}
                buttons={[{ value: 'signUp', label: t('signIn.tabCreateAccount') }, { value: 'signIn', label: t('signIn.tabSignIn') }]}
              />
            ) : null}

            {flow === 'signUp' ? (
              <TextInput {...authInputProps} label={t('signIn.nameLabel')} value={fullName} onChangeText={setFullName} mode="outlined" />
            ) : null}
            <TextInput {...authInputProps} label={t('signIn.emailLabel')} value={email} onChangeText={setEmail} autoCapitalize="none" keyboardType="email-address" mode="outlined" />
            <TextInput {...authInputProps} label={t('signIn.passwordLabel')} value={password} onChangeText={setPassword} secureTextEntry mode="outlined" />
            {flow === 'signIn' ? (
              <Button mode="text" compact textColor={authColors.primary} onPress={() => router.push('/(auth)/reset-password')}>
                {t('signIn.forgotPassword')}
              </Button>
            ) : null}

            <Button mode="contained" buttonColor={authColors.primary} textColor={authColors.buttonText} loading={submitting} disabled={submitting} onPress={() => void submit()}>
              {flow === 'signUp'
                ? (inviteToken && invitePreview && !invitePreview.expired ? t('signIn.joinVenueButton', { venueName: invitePreview.venueName ?? '' }) : t('signIn.createAccountButton'))
                : t('signIn.signInButton')}
            </Button>

            {flow === 'signUp' ? (
              <View style={{ flexDirection: 'row', alignItems: 'center', gap: 4 }}>
                <Checkbox status={termsAccepted ? 'checked' : 'unchecked'} onPress={() => setTermsAccepted((value) => !value)} color={authColors.primary} />
                <Text style={{ color: authColors.muted, fontSize: 12, flex: 1 }}>
                  {t('signIn.termsPrefix')}{' '}
                  <Text style={{ color: authColors.primary, fontSize: 12 }} onPress={() => void Linking.openURL('https://www.venuewrangler.com/terms')}>
                    {t('signIn.termsOfService')}
                  </Text>{' '}{t('signIn.and')}{' '}
                  <Text style={{ color: authColors.primary, fontSize: 12 }} onPress={() => void Linking.openURL('https://www.venuewrangler.com/privacy')}>
                    {t('signIn.privacyPolicy')}
                  </Text>.
                </Text>
              </View>
            ) : null}
          </Card.Content>
        </Card>

        {!inviteToken ? (
          <Button
            mode="outlined"
            textColor={authColors.primary}
            onPress={() => router.push('/(auth)/invite-check')}
          >
            {t('signIn.haveInviteButton')}
          </Button>
        ) : null}

        <View style={{ alignItems: 'center', marginTop: spacing.sm, gap: 6 }}>
          <Text style={{ color: authColors.muted, fontSize: 13, textAlign: 'center' }}>
            {t('signIn.footerNote')}
          </Text>
          <Text style={{ color: authColors.muted, fontSize: 12, fontWeight: '700' }}>{t('common.venueWrangler')}</Text>
          <Text style={{ color: authColors.muted, fontSize: 11 }}>{t('common.loungeability')}</Text>
        </View>
      </ScrollView>
    </KeyboardAvoidingView>
  );
}

const styles = StyleSheet.create({
  logo: {
    width: '100%',
    maxWidth: 340,
    aspectRatio: 1024 / 559,
    resizeMode: 'contain',
  },
  authCard: {
    ...authCardStyle,
  },
});

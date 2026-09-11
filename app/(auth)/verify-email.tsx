import { useRef, useState } from 'react';
import { Alert, KeyboardAvoidingView, Platform, ScrollView, StyleSheet, View } from 'react-native';
import { router, useLocalSearchParams } from 'expo-router';
import { Button, Card, Text, TextInput } from 'react-native-paper';
import { appApi } from '../../lib/api-client';
import { userFromProfile, venueFromAuth } from '../../lib/session-from-auth';
import { useAuthStore, type AuthState } from '../../lib/auth-store';
import { authCardStyle, authColors as colors, authInputProps as inputProps, spacing, type } from '../../lib/theme';
import { Kicker } from '../../components/AppCard';
import { useI18n } from '../../lib/i18n';

export default function VerifyEmailScreen() {
  const { t } = useI18n();
  const { invite, emailSendFailed } = useLocalSearchParams<{ invite?: string; emailSendFailed?: string }>();
  // Signup could not deliver the code. Say so plainly instead of leaving
  // someone waiting on an inbox that will never receive it.
  const deliveryFailed = emailSendFailed === '1';
  const user = useAuthStore((state: AuthState) => state.user);
  const setSession = useAuthStore((state: AuthState) => state.setSession);
  const clearSession = useAuthStore((state: AuthState) => state.clearSession);
  const venue = useAuthStore((state: AuthState) => state.venue);
  const token = useAuthStore((state: AuthState) => state.token);
  const [code, setCode] = useState('');
  const [submitting, setSubmitting] = useState(false);
  const [resending, setResending] = useState(false);
  const [codeVerified, setCodeVerified] = useState(false);
  const codeVerifiedRef = useRef(false);
  // Synchronous guards; "Resend" in particular sent two verification emails.
  const submittingRef = useRef(false);
  const resendingRef = useRef(false);

  const verify = async () => {
    if (submittingRef.current) return;
    if (!codeVerifiedRef.current && !code.trim()) {
      Alert.alert(t('verifyEmail.codeRequiredTitle'), t('verifyEmail.codeRequiredMessage'));
      return;
    }
    submittingRef.current = true;
    setSubmitting(true);
    try {
      // Verification consumes the code. A later network failure during invite
      // redemption must retry that step, not submit the consumed code again.
      if (!codeVerifiedRef.current) {
        await appApi.verifyEmail({ code: code.trim() });
        codeVerifiedRef.current = true;
        setCodeVerified(true);
      }
      const redemption = typeof invite === 'string' && invite
        ? await appApi.redeemInvite(invite)
        : await appApi.redeemMyInvite();
      if (redemption.redeemed && redemption.profile) {
        setSession({
          user: { ...userFromProfile(redemption.profile), email_verified: true },
          venue: venueFromAuth({ ...redemption.profile, emailVerified: true }, redemption.venue),
          token,
        });
        const venueName = redemption.venue?.name;
        if (venueName) {
          Alert.alert(
            t('verifyEmail.welcomeTitle'),
            t('verifyEmail.welcomeMessage', { venueName }),
            [{ text: t('verifyEmail.getStarted'), onPress: () => router.replace('/(tabs)/home') }],
          );
        } else {
          router.replace('/(tabs)/home');
        }
        return;
      }
      if (user) {
        setSession({
          user: { ...user, email_verified: true },
          venue,
          token,
        });
      }
      router.replace(venue ? '/(tabs)/home' : '/(auth)/team-choice');
    } catch (error) {
      Alert.alert(t('verifyEmail.verifyFailedTitle'), error instanceof Error ? error.message : t('verifyEmail.tryAgain'));
    } finally {
      submittingRef.current = false;
      setSubmitting(false);
    }
  };

  const resend = async () => {
    if (resendingRef.current || submittingRef.current || codeVerifiedRef.current) return;
    resendingRef.current = true;
    setResending(true);
    try {
      await appApi.resendVerification();
      Alert.alert(t('verifyEmail.resendSuccessTitle'), t('verifyEmail.resendSuccessMessage', { email: user?.email ?? t('verifyEmail.defaultEmail') }));
    } catch (error) {
      Alert.alert(t('verifyEmail.resendFailedTitle'), error instanceof Error ? error.message : t('verifyEmail.tryAgain'));
    } finally {
      resendingRef.current = false;
      setResending(false);
    }
  };

  return (
    <KeyboardAvoidingView style={{ flex: 1, backgroundColor: colors.background }} behavior={Platform.OS === 'ios' ? 'padding' : undefined}>
      <ScrollView contentContainerStyle={{ flexGrow: 1, padding: spacing.lg, justifyContent: 'center', gap: spacing.md }}>
        <View style={{ gap: 6, alignItems: 'center' }}>
          <Kicker>{t('verifyEmail.kicker')}</Kicker>
          <Text style={{ ...type.title, color: colors.text, textAlign: 'center' }}>
            {t('verifyEmail.title')}
          </Text>
          <Text variant="bodyMedium" style={{ color: colors.muted, textAlign: 'center' }}>
            {t('verifyEmail.subtitle', { email: user?.email ?? t('verifyEmail.defaultEmail') })}
          </Text>
        </View>

        <Card style={styles.card}>
          <Card.Content style={{ gap: spacing.md }}>
            {deliveryFailed ? (
              <View style={{ gap: 4, padding: spacing.sm, borderRadius: 8, backgroundColor: '#FDE7E9' }}>
                <Text style={{ fontWeight: '700', color: '#A81C24' }}>{t('verifyEmail.deliveryFailedTitle')}</Text>
                <Text variant="bodySmall" style={{ color: '#A81C24' }}>{t('verifyEmail.deliveryFailedMessage')}</Text>
              </View>
            ) : null}
            <TextInput
              {...inputProps}
              label={t('verifyEmail.codeLabel')}
              value={code}
              onChangeText={setCode}
              editable={!submitting && !codeVerified}
              keyboardType="number-pad"
              autoCapitalize="none"
              mode="outlined"
              maxLength={10}
              returnKeyType="go"
              onSubmitEditing={() => void verify()}
            />

            <Button mode="contained" buttonColor={colors.primary} textColor={colors.buttonText} loading={submitting} disabled={submitting} onPress={() => void verify()}>
              {t('verifyEmail.verifyButton')}
            </Button>
            <Button mode="text" textColor={colors.primary} loading={resending} disabled={resending || submitting || codeVerified} onPress={() => void resend()}>
              {t('verifyEmail.resendButton')}
            </Button>
          </Card.Content>
        </Card>

        <Button
          mode="text"
          textColor={colors.muted}
          onPress={() => {
            clearSession();
            router.replace('/(auth)/welcome');
          }}
        >
          {t('verifyEmail.signOut')}
        </Button>
      </ScrollView>
    </KeyboardAvoidingView>
  );
}

const styles = StyleSheet.create({
  card: {
    ...authCardStyle,
  },
});

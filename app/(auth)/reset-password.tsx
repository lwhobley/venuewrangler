import { Button } from '../../components/AppButton';
import { useRef, useState } from 'react';
import { Alert, KeyboardAvoidingView, Platform, ScrollView, StyleSheet, View } from 'react-native';
import { router } from 'expo-router';
import { Card, Text, TextInput } from 'react-native-paper';
import { appApi } from '../../lib/api-client';
import { authCardStyle, authColors as colors, authInputProps as inputProps, spacing, type } from '../../lib/theme';
import { Kicker } from '../../components/AppCard';
import { useI18n } from '../../lib/i18n';

export default function ResetPasswordScreen() {
  const { t } = useI18n();
  const [email, setEmail] = useState('');
  const [code, setCode] = useState('');
  const [newPassword, setNewPassword] = useState('');
  const [requesting, setRequesting] = useState(false);
  const [resetting, setResetting] = useState(false);
  // Synchronous guards. A double-tap on "Send code" issued two codes, and
  // because the second invalidates the first, the user typing the code from
  // the email that arrived first would fail to reset.
  const requestingRef = useRef(false);
  const resettingRef = useRef(false);

  const requestCode = async () => {
    if (requestingRef.current) return;
    if (!email.trim().includes('@')) {
      Alert.alert(t('resetPassword.emailRequiredTitle'), t('resetPassword.emailRequiredMessage'));
      return;
    }
    requestingRef.current = true;
    setRequesting(true);
    try {
      await appApi.forgotPassword({ email: email.trim() });
      Alert.alert(t('resetPassword.codeSentTitle'), t('resetPassword.codeSentMessage'));
    } catch (error) {
      Alert.alert(t('resetPassword.sendFailedTitle'), error instanceof Error ? error.message : t('resetPassword.tryAgain'));
    } finally {
      requestingRef.current = false;
      setRequesting(false);
    }
  };

  const reset = async () => {
    if (resettingRef.current) return;
    if (!email.trim().includes('@') || !code.trim() || newPassword.length < 8) {
      Alert.alert(t('resetPassword.resetRequiredTitle'), t('resetPassword.resetRequiredMessage'));
      return;
    }
    resettingRef.current = true;
    setResetting(true);
    try {
      await appApi.resetPassword({
        email: email.trim(),
        code: code.trim(),
        newPassword,
      });
      Alert.alert(t('resetPassword.successTitle'), t('resetPassword.successMessage'));
      router.replace('/(auth)/welcome');
    } catch (error) {
      Alert.alert(t('resetPassword.resetFailedTitle'), error instanceof Error ? error.message : t('resetPassword.tryAgain'));
    } finally {
      resettingRef.current = false;
      setResetting(false);
    }
  };

  return (
    <KeyboardAvoidingView style={{ flex: 1, backgroundColor: colors.background }} behavior={Platform.OS === 'ios' ? 'padding' : undefined}>
      <ScrollView contentContainerStyle={{ flexGrow: 1, padding: spacing.lg, justifyContent: 'center', gap: spacing.md }}>
        <View style={{ gap: 6, alignItems: 'center' }}>
          <Kicker>{t('resetPassword.kicker')}</Kicker>
          <Text style={{ ...type.title, color: colors.text, textAlign: 'center' }}>
            {t('resetPassword.title')}
          </Text>
          <Text variant="bodyMedium" style={{ color: colors.muted, textAlign: 'center' }}>
            {t('resetPassword.subtitle')}
          </Text>
        </View>

        <Card style={styles.card}>
          <Card.Content style={{ gap: spacing.md }}>
            <TextInput
              {...inputProps}
              label={t('resetPassword.emailLabel')}
              value={email}
              onChangeText={setEmail}
              autoCapitalize="none"
              keyboardType="email-address"
              mode="outlined"
            />
            <Button mode="outlined" textColor={colors.primary} loading={requesting} disabled={requesting} onPress={() => void requestCode()}>
              {t('resetPassword.sendCodeButton')}
            </Button>
            <TextInput
              {...inputProps}
              label={t('resetPassword.codeLabel')}
              value={code}
              onChangeText={setCode}
              keyboardType="number-pad"
              mode="outlined"
              maxLength={10}
            />
            <TextInput
              {...inputProps}
              label={t('resetPassword.newPasswordLabel')}
              value={newPassword}
              onChangeText={setNewPassword}
              secureTextEntry
              mode="outlined"
              returnKeyType="go"
              onSubmitEditing={() => void reset()}
            />
            <Button mode="contained" buttonColor={colors.primary} textColor={colors.buttonText} loading={resetting} disabled={resetting} onPress={() => void reset()}>
              {t('resetPassword.resetButton')}
            </Button>
          </Card.Content>
        </Card>

        <Button mode="text" textColor={colors.muted} onPress={() => router.back()}>
          {t('resetPassword.back')}
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

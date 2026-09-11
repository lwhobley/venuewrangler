import { useState } from 'react';
import {
  Alert,
  KeyboardAvoidingView,
  Platform,
  ScrollView,
  StyleSheet,
  View,
} from 'react-native';
import { router } from 'expo-router';
import { notifySuccess } from '../../lib/feedback';
import { Button, Card, Text, TextInput } from 'react-native-paper';
import { appApi } from '../../lib/api-client';
import { authCardStyle, authColors as colors, authInputProps as inputProps, spacing, type } from '../../lib/theme';
import { Kicker } from '../../components/AppCard';
import { useI18n } from '../../lib/i18n';

type Stage =
  | { kind: 'entry' }
  | { kind: 'submitted' };

export default function InviteCheckScreen() {
  const { t } = useI18n();
  const [contact, setContact] = useState('');
  const [loading, setLoading] = useState(false);
  const [stage, setStage] = useState<Stage>({ kind: 'entry' });

  const looksLikeEmail = contact.includes('@');

  const check = async () => {
    if (loading) return;
    const trimmed = contact.trim();
    if (!trimmed) {
      Alert.alert(t('inviteCheck.contactRequiredTitle'), t('inviteCheck.contactRequiredMessage'));
      return;
    }
    setLoading(true);
    try {
      const body = looksLikeEmail
        ? { email: trimmed }
        : { phone: trimmed };
      await appApi.inviteCheck(body);
      notifySuccess();
      setStage({ kind: 'submitted' });
    } catch (e) {
      Alert.alert(t('inviteCheck.errorTitle'), e instanceof Error ? e.message : t('inviteCheck.genericError'));
    } finally {
      setLoading(false);
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
          <View style={[styles.step, styles.stepActive]} />
          <View style={styles.step} />
        </View>

        <View style={{ gap: 6 }}>
          <Kicker>{t('inviteCheck.kicker')}</Kicker>
          <Text style={{ ...type.title, color: colors.text }}>
            {t('inviteCheck.title')}
          </Text>
          <Text variant="bodyMedium" style={{ color: colors.muted }}>
            {t('inviteCheck.subtitle')}
          </Text>
        </View>

        <Card style={styles.card}>
          <Card.Content style={{ gap: spacing.md }}>
            {stage.kind === 'entry' && (
              <>
                <TextInput
                  {...inputProps}
                  label={t('inviteCheck.contactLabel')}
                  value={contact}
                  onChangeText={(v) => {
                    setContact(v);
                    setStage({ kind: 'entry' });
                  }}
                  autoCapitalize="none"
                  keyboardType="email-address"
                  mode="outlined"
                  returnKeyType="go"
                  onSubmitEditing={() => void check()}
                />
                <Button
                  mode="contained"
                  buttonColor={colors.primary}
                  textColor={colors.buttonText}
                  loading={loading}
                  disabled={loading}
                  onPress={() => void check()}
                >
                  {t('inviteCheck.checkButton')}
                </Button>
              </>
            )}

            {stage.kind === 'submitted' && (
              <View style={{ gap: spacing.sm }}>
                <Text variant="bodyMedium" style={{ color: colors.text }}>
                  {t('inviteCheck.submitted.message')}
                </Text>
                <Text variant="bodySmall" style={{ color: colors.muted }}>
                  {t('inviteCheck.submitted.hint')}
                </Text>
                <Button
                  mode="text"
                  textColor={colors.muted}
                  onPress={() => {
                    setContact('');
                    setStage({ kind: 'entry' });
                  }}
                >
                  {t('inviteCheck.submitted.tryAgain')}
                </Button>
              </View>
            )}
          </Card.Content>
        </Card>

        <Button
          mode="text"
          textColor={colors.muted}
          onPress={() => router.back()}
        >
          {t('inviteCheck.back')}
        </Button>
      </ScrollView>
    </KeyboardAvoidingView>
  );
}

const styles = StyleSheet.create({
  stepRow: {
    flexDirection: 'row',
    gap: 6,
    marginBottom: 4,
  },
  step: {
    flex: 1,
    height: 4,
    borderRadius: 2,
    backgroundColor: colors.border,
  },
  stepActive: {
    backgroundColor: colors.primary,
  },
  card: {
    ...authCardStyle,
  },
});

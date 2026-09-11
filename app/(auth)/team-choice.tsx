import { KeyboardAvoidingView, Platform, ScrollView, StyleSheet, View } from 'react-native';
import { Redirect, router } from 'expo-router';
import { Button, Card, Text } from 'react-native-paper';
import { authCardStyle, authColors as colors, spacing, type } from '../../lib/theme';
import { Kicker } from '../../components/AppCard';
import { useAuthStore, type AuthState } from '../../lib/auth-store';
import { useI18n } from '../../lib/i18n';
import { WorkplaceAdoption } from '../../components/WorkplaceAdoption';

export default function TeamChoiceScreen() {
  const { t } = useI18n();
  const user = useAuthStore((s: AuthState) => s.user);
  const venue = useAuthStore((s: AuthState) => s.venue);
  const clearSession = useAuthStore((s: AuthState) => s.clearSession);

  const useDifferentAccount = () => {
    clearSession();
    router.replace('/(auth)/welcome');
  };

  if (user && !user.email_verified) return <Redirect href="/(auth)/verify-email" />;
  if (venue) return <Redirect href="/(tabs)/home" />;

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
        <View style={{ gap: 6, alignItems: 'center' }}>
          <Kicker>{t('teamChoice.kicker')}</Kicker>
          <Text style={{ ...type.title, color: colors.text, textAlign: 'center' }}>
            {t('teamChoice.title')}
          </Text>
          <Text variant="bodyMedium" style={{ color: colors.muted, textAlign: 'center' }}>
            {t('teamChoice.subtitle')}
          </Text>
        </View>

        <WorkplaceAdoption />
        <Card style={styles.card}>
          <Card.Content style={{ gap: spacing.sm }}>
            <Text variant="titleMedium" style={{ fontWeight: '700', color: colors.text }}>{t('teamChoice.cardTitle')}</Text>
            <Text style={{ color: colors.muted }}>
              {t('teamChoice.cardBody')}
            </Text>
            <Button
              mode="contained"
              buttonColor={colors.primary}
              textColor={colors.buttonText}
              icon="account-group-outline"
              onPress={() => router.push('/(auth)/invite-check')}
            >
              {t('teamChoice.findInviteButton')}
            </Button>
            <Button mode="outlined" textColor={colors.primary} onPress={() => router.push('/(auth)/workplace-search')}>
              Search for a workplace
            </Button>
          </Card.Content>
        </Card>

        <View style={{ alignItems: 'center', gap: 2, marginTop: spacing.sm }}>
          <Text style={{ color: colors.muted, textAlign: 'center' }}>
            {t('teamChoice.differentLoginQuestion')}
          </Text>
          <Button mode="text" textColor={colors.primary} onPress={useDifferentAccount}>
            {t('teamChoice.signInDifferentAccount')}
          </Button>
        </View>
      </ScrollView>
    </KeyboardAvoidingView>
  );
}

const styles = StyleSheet.create({
  card: {
    ...authCardStyle,
  },
});

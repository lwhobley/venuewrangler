import { Button } from '../../components/AppButton';
import { useRef, useState } from 'react';
import { Linking, View } from 'react-native';
import { Text } from 'react-native-paper';
import { router } from 'expo-router';
import { useQuery } from '../../lib/railway-hooks';
import { api } from '../../lib/railway-api';
import { colors, spacing } from '../../lib/theme';
import { AppCard, SectionHeader } from '../../components/AppCard';
import { ScreenErrorBoundary } from '../../components/ErrorBoundary';
import { useAuthStore, type AuthState } from '../../lib/auth-store';
import { useAuthenticatedSession } from '../../lib/auth-readiness';
import { canManageBilling } from '../../lib/permissions';
import { useI18n } from '../../lib/i18n';
import { appApi } from '../../lib/api-client';

const APPLE_SUBSCRIPTIONS_URL = 'https://apps.apple.com/account/subscriptions';
const MONTHLY_PLAN_LABEL = '$99.99 / month';

function BillingScreen() {
  const { t } = useI18n();
  const user = useAuthStore((state: AuthState) => state.user);
  const venue = useAuthStore((state: AuthState) => state.venue);
  const { isReady } = useAuthenticatedSession();
  const me = useQuery(api.app.getMe, isReady ? {} : 'skip');
  const billing = useQuery(api.app.getMyVenueBilling, isReady && user && venue?.id ? {} : 'skip');

  // Trial state is account-scoped. Drive the CTA off that, not off
  // "never subscribed".
  const trialEndsAt: number | null = me?.profile?.trialEndsAt ?? null;
  const inTrial = trialEndsAt != null && trialEndsAt > Date.now();
  const isPaid = billing?.status === 'active' || billing?.status === 'trialing';
  const trialDaysLeft = inTrial ? Math.max(0, Math.ceil((trialEndsAt - Date.now()) / (1000 * 60 * 60 * 24))) : 0;
  const upgradeLabel = inTrial ? t('settingsBilling.upgrade') : t('settingsBilling.subscribe');
  const canEditBilling = Boolean(me && canManageBilling(me.profile.role, me.profile.allAccess));
  const [managingSubscription, setManagingSubscription] = useState(false);
  const [manageError, setManageError] = useState<string | null>(null);
  // Synchronous guard: a useState check doesn't apply until the next render,
  // so a double-tap opened two Stripe portal sessions and two browser tabs.
  const managingRef = useRef(false);

  const manageSubscription = async () => {
    if (managingRef.current) return;
    managingRef.current = true;
    setManagingSubscription(true);
    setManageError(null);
    try {
      if (billing?.platform === 'stripe') {
        const { url } = await appApi.createStripePortal();
        await Linking.openURL(url);
        return;
      }
      await Linking.openURL(APPLE_SUBSCRIPTIONS_URL);
    } catch (e) {
      setManageError(e instanceof Error ? e.message : t('settingsBilling.manageSubscriptionFailed'));
    } finally {
      managingRef.current = false;
      setManagingSubscription(false);
    }
  };

  if (me === undefined) {
    return (
      <View style={{ flex: 1, backgroundColor: colors.background, padding: spacing.lg }}>
        <Text style={{ color: colors.muted }}>{t('settingsBilling.loadingAccess')}</Text>
      </View>
    );
  }

  if (!canEditBilling) {
    return (
      <View style={{ flex: 1, backgroundColor: colors.background, padding: spacing.lg }}>
        <Text style={{ color: colors.muted }}>{t('settingsBilling.ownerAdminOnly')}</Text>
      </View>
    );
  }

  return (
    <View style={{ flex: 1, backgroundColor: colors.background, padding: spacing.lg }}>
      <AppCard>
          <SectionHeader kicker={t('settingsBilling.kicker')} title={t('settingsBilling.title')} />
          <View style={{ gap: spacing.sm }}>
          <Text style={{ color: colors.muted }}>{venue?.name ?? t('settingsBilling.noVenueSelected')}</Text>
          <Text style={{ color: colors.muted }}>{t('settingsBilling.statusLabel', { status: billing?.status ?? t('settingsBilling.notConfigured') })}</Text>
          {inTrial ? <Text style={{ color: colors.muted }}>{t('settingsBilling.daysLeftIntro', { days: trialDaysLeft })}</Text> : null}
          <Text style={{ color: colors.muted }}>{t('settingsBilling.renewsMonthlyNotice')}</Text>
          <Text style={{ color: colors.muted }}>{t('settingsBilling.currentPlan', { plan: isPaid ? MONTHLY_PLAN_LABEL : inTrial ? t('settingsBilling.introAccess') : t('settingsBilling.notSubscribed') })}</Text>
          <Text style={{ color: colors.muted }}>{t('settingsBilling.loggedInAs', { email: user?.email ?? t('settingsBilling.unknownEmail') })}</Text>

          {!isPaid ? (
            <Button mode="contained" buttonColor={colors.primary} onPress={() => router.push('/billing/paywall')}>
              {upgradeLabel}
            </Button>
          ) : null}
          {manageError ? <Text style={{ color: colors.danger }}>{manageError}</Text> : null}
          <Button
            mode="outlined"
            textColor={colors.primary}
            loading={managingSubscription}
            disabled={managingSubscription}
            onPress={() => void manageSubscription()}
          >
            {t('settingsBilling.manageSubscription')}
          </Button>
          <Button mode="text" textColor={colors.primary} onPress={() => router.push('/(tabs)/profile')}>
            {t('settingsBilling.backToProfile')}
          </Button>
          </View>
      </AppCard>
    </View>
  );
}

export default function BillingScreenWrapper() {
  return <ScreenErrorBoundary withNavRail={false}><BillingScreen /></ScreenErrorBoundary>;
}

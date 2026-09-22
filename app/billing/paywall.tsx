import { useEffect, useRef, useState } from 'react';
import { Linking, ScrollView, StyleSheet, View } from 'react-native';
import { router } from 'expo-router';
import { Button, Card, Text } from 'react-native-paper';
import { appApi } from '../../lib/api-client';
import { useAuthenticatedSession } from '../../lib/auth-readiness';
import { colors, spacing, radius } from '../../lib/theme';
import { PageHeader } from '../../components/design-system';
import {
  PURCHASES_SUPPORTED,
  getOfferingPackages,
  purchasePackageById,
  restorePurchases,
  type PurchasePackage,
} from '../../lib/purchases';
import { useI18n } from '../../lib/i18n';

const TERMS_URL = 'https://www.venuewrangler.com/terms';
const PRIVACY_URL = 'https://www.venuewrangler.com/privacy';
const SINGLE_PRICE_LABEL = '$99.99';
const MULTI_PRICE_LABEL = '$399.00';

// Shown when RevenueCat returns no live offering yet — e.g. Expo Go / dev
// (no native key), or before the App Store subscription is approved. Keeps
// default plans visible so the screen is never blank. Real packages from
// getOfferingPackages() override this whenever they're available.
const FALLBACK_TIERS: (PurchasePackage & { planKey?: 'single' | 'multi_venue'; description?: string })[] = [
  {
    id: 'venueflow-monthly',
    title: 'Single Venue Standard',
    priceString: SINGLE_PRICE_LABEL,
    productId: 'com.venuewrangler.monthly',
    planKey: 'single',
    description: 'Everything you need to manage 1 venue with unlimited staff.',
  },
  {
    id: 'venueflow-multi-venue-5',
    title: 'Multi-Venue Pro (Up to 5 Venues)',
    priceString: MULTI_PRICE_LABEL,
    productId: 'com.venuewrangler.multivenue.399',
    planKey: 'multi_venue',
    description: 'Manage up to 5 venues seamlessly under 1 subscription.',
  },
];

function planKeyFor(pkg: Pick<PurchasePackage, 'id' | 'productId'>): 'single' | 'multi_venue' {
  return pkg.productId.includes('multivenue') || pkg.id.includes('multi') ? 'multi_venue' : 'single';
}

export default function PaywallScreen() {
  const { t } = useI18n();
  const { me } = useAuthenticatedSession();
  const [packages, setPackages] = useState<PurchasePackage[]>([]);
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  // Trial state is account-scoped. Anyone here is either already trialing
  // (action = upgrade to paid) or past it (action = subscribe).
  const trialEndsAt: number | null = me?.profile?.trialEndsAt ?? null;
  const inTrial = trialEndsAt != null && trialEndsAt > Date.now();
  const ctaLabel = inTrial ? t('paywall.ctaUpgrade') : t('paywall.ctaSubscribe');
  const livePackagesLoaded = packages.length > 0;

  useEffect(() => {
    let active = true;
    (async () => {
      try {
        const pkgs = await getOfferingPackages();
        if (active) setPackages(pkgs);
      } catch (e) {
        console.warn('[paywall] Could not load RevenueCat offerings:', e instanceof Error ? e.message : String(e));
      } finally {
        if (active) setLoading(false);
      }
    })();
    return () => {
      active = false;
    };
  }, []);

  // useState alone doesn't guard re-entry: setBusy(id) doesn't apply until the
  // next render, so two taps in the same tick both pass before `disabled`
  // flips. These call real purchase APIs (StoreKit / Stripe checkout), so a
  // race here can open two purchase sheets or two checkout sessions.
  const busyRef = useRef(false);

  const buy = async (id: string, productId?: string) => {
    if (busyRef.current) return;
    busyRef.current = true;
    setBusy(id);
    setError(null);
    try {
      const selected = (packages.length ? packages : FALLBACK_TIERS).find((pkg) => pkg.id === id);
      const targetProductId = selected?.productId || productId || 'com.venuewrangler.monthly';
      const active = await purchasePackageById(id, targetProductId);
      if (active) {
        const entitlementId = targetProductId.includes('multivenue') ? 'multi_venue' : 'pro';
        await appApi.syncAppleSubscription({ productId: targetProductId, entitlementId });
        router.replace('/(tabs)/home');
      }
    } catch (e) {
      const msg = e instanceof Error ? e.message : t('paywall.purchaseFailed');
      // Swallow the user-cancelled case quietly.
      if (!/cancel/i.test(msg)) setError(msg);
    } finally {
      busyRef.current = false;
      setBusy(null);
    }
  };

  const restore = async () => {
    if (busyRef.current) return;
    busyRef.current = true;
    setBusy('restore');
    setError(null);
    try {
      const restored = await restorePurchases();
      if (restored.active) {
        await appApi.syncAppleSubscription({
          productId: restored.productId || 'com.venuewrangler.monthly',
          entitlementId: restored.entitlementId || 'pro',
        });
        router.replace('/(tabs)/home');
      }
      else setError(t('paywall.restoreNoneFound'));
    } catch (e) {
      setError(e instanceof Error ? e.message : t('paywall.restoreFailed'));
    } finally {
      busyRef.current = false;
      setBusy(null);
    }
  };

  const buyWithStripe = async (plan: 'single' | 'multi_venue' = 'single') => {
    if (busyRef.current) return;
    busyRef.current = true;
    setBusy('stripe_' + plan);
    setError(null);
    try {
      const { url } = await appApi.createStripeCheckout({ plan });
      await Linking.openURL(url);
    } catch (e) {
      setError(e instanceof Error ? e.message : t('paywall.purchaseFailed'));
    } finally {
      busyRef.current = false;
      setBusy(null);
    }
  };

  const displayTiers = livePackagesLoaded
    ? [
        ...packages,
        ...FALLBACK_TIERS.filter(
          (fallback) => !packages.some((pkg) => planKeyFor(pkg) === planKeyFor(fallback)),
        ),
      ]
    : FALLBACK_TIERS;

  return (
    <ScrollView contentInsetAdjustmentBehavior="automatic" style={{ flex: 1, backgroundColor: colors.background }} contentContainerStyle={{ padding: spacing.lg, gap: spacing.md, paddingBottom: spacing.xxl }}>
      <PageHeader kicker={t('paywall.kicker')} title={t('paywall.title')} detail={t('paywall.subtitle')} />

      {!PURCHASES_SUPPORTED ? (
        <View style={{ gap: spacing.md }}>
          <Card style={{ backgroundColor: colors.surface, borderRadius: radius.sharp, borderWidth: StyleSheet.hairlineWidth, borderColor: colors.border }}>
            <Card.Content style={{ gap: spacing.sm }}>
              <Text variant="titleMedium" style={{ fontWeight: '800', color: colors.primary }}>Single Venue Standard</Text>
              <Text style={{ color: colors.charcoal, fontSize: 24, fontWeight: '800' }}>{SINGLE_PRICE_LABEL}<Text style={{ color: colors.muted, fontSize: 14, fontWeight: '400' }}> / month</Text></Text>
              <Text style={{ color: colors.muted }}>Manage 1 venue with full operational tools & unlimited staff.</Text>
              <Button mode="contained" buttonColor={colors.primary} loading={busy === 'stripe_single'} disabled={Boolean(busy)} onPress={() => void buyWithStripe('single')}>
                {ctaLabel} — Single Venue
              </Button>
            </Card.Content>
          </Card>

          <Card style={{ backgroundColor: colors.surface, borderRadius: radius.sharp, borderWidth: 1.5, borderColor: colors.primary }}>
            <Card.Content style={{ gap: spacing.sm }}>
              <View style={{ flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center' }}>
                <Text variant="titleMedium" style={{ fontWeight: '800', color: colors.primary }}>Multi-Venue Pro</Text>
                <Text style={{ fontSize: 12, fontWeight: '700', color: colors.primary, backgroundColor: colors.surface, paddingHorizontal: 8, paddingVertical: 2, borderRadius: 4 }}>UP TO 5 VENUES</Text>
              </View>
              <Text style={{ color: colors.charcoal, fontSize: 24, fontWeight: '800' }}>{MULTI_PRICE_LABEL}<Text style={{ color: colors.muted, fontSize: 14, fontWeight: '400' }}> / month</Text></Text>
              <Text style={{ color: colors.muted }}>Manage up to 5 venues under a single organization account.</Text>
              <Button mode="contained" buttonColor={colors.primary} loading={busy === 'stripe_multi_venue'} disabled={Boolean(busy)} onPress={() => void buyWithStripe('multi_venue')}>
                {ctaLabel} — Multi-Venue Pro ($399/mo)
              </Button>
            </Card.Content>
          </Card>
        </View>
      ) : loading ? (
        <Text style={{ color: colors.muted }}>{t('paywall.loadingPricing')}</Text>
      ) : (
        displayTiers.map((pkg) => {
          const isMulti = planKeyFor(pkg) === 'multi_venue';
          return (
            <Card key={pkg.id} style={{ backgroundColor: colors.surface, borderRadius: radius.soft, borderWidth: isMulti ? 1.5 : StyleSheet.hairlineWidth, borderColor: isMulti ? colors.primary : colors.border }}>
              <Card.Content style={{ gap: spacing.sm }}>
                <View style={{ flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center' }}>
                  <Text variant="titleMedium" style={{ fontWeight: '800', color: colors.primary }}>{pkg.title}</Text>
                  {isMulti ? <Text style={{ fontSize: 11, fontWeight: '700', color: colors.primary }}>UP TO 5 VENUES</Text> : null}
                </View>
                <Text style={{ color: colors.charcoal, fontSize: 24, fontWeight: '800' }}>{pkg.priceString}<Text style={{ color: colors.muted, fontSize: 14, fontWeight: '400' }}> / month</Text></Text>
                <Text style={{ color: colors.muted, fontWeight: '600' }}>
                  {isMulti ? 'Manage up to 5 venues seamlessly under 1 subscription.' : t('paywall.forTeamSize')}
                </Text>
                <Text style={{ color: colors.success, fontWeight: '600' }}>
                  {inTrial ? t('paywall.introActive') : t('paywall.monthlySubscription')}
                </Text>
                <Button
                  mode="contained"
                  buttonColor={colors.primary}
                  loading={busy === pkg.id}
                  disabled={!busy && !livePackagesLoaded ? false : !!busy}
                  onPress={() => void buy(pkg.id, pkg.productId)}
                >
                  {ctaLabel} {isMulti ? '— Multi-Venue ($399/mo)' : ''}
                </Button>
              </Card.Content>
            </Card>
          );
        })
      )}

      {!loading && PURCHASES_SUPPORTED && packages.length === 0 ? (
        <Text style={{ color: colors.muted, fontSize: 12, textAlign: 'center' }}>
          {t('paywall.appStorePendingNotice')}
        </Text>
      ) : null}

      {error ? <Text selectable style={{ color: colors.danger }}>{error}</Text> : null}

      {PURCHASES_SUPPORTED ? (
        <Button mode="text" textColor={colors.primary} loading={busy === 'restore'} disabled={!!busy} onPress={() => void restore()}>
          {t('paywall.restorePurchases')}
        </Button>
      ) : null}

      <Text style={{ color: colors.muted, fontSize: 12, textAlign: 'center' }}>
        {t('paywall.autoRenewNotice')}
      </Text>
      <View style={{ flexDirection: 'row', justifyContent: 'center', gap: spacing.md }}>
        <Button mode="text" compact textColor={colors.muted} onPress={() => void Linking.openURL(TERMS_URL)}>{t('paywall.terms')}</Button>
        <Button mode="text" compact textColor={colors.muted} onPress={() => void Linking.openURL(PRIVACY_URL)}>{t('paywall.privacy')}</Button>
      </View>
      <Button mode="text" textColor={colors.primary} onPress={() => router.back()}>{t('paywall.back')}</Button>
    </ScrollView>
  );
}

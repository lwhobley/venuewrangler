import { Alert, Platform, ScrollView, View } from 'react-native';
import { useRef, useState } from 'react';
import { router } from 'expo-router';
import { Button, Card, Text } from 'react-native-paper';
import { ScreenErrorBoundary } from '../../components/ErrorBoundary';
import { PageHeader } from '../../components/design-system';
import { useMutation, useQuery } from '../../lib/railway-hooks';
import { useAuthActions } from '../../lib/railway-hooks';
import { ApiError } from '../../lib/api-client';
import { api } from '../../lib/railway-api';
import { colors, radius, spacing } from '../../lib/theme';
import { useAuthStore, type AuthState } from '../../lib/auth-store';
import { useAuthenticatedSession } from '../../lib/auth-readiness';
import { canManageBilling, canManageVenue } from '../../lib/permissions';
import { useI18n } from '../../lib/i18n';

function ProfileScreen() {
  const { t } = useI18n();
  const user = useAuthStore((state: AuthState) => state.user);
  const venue = useAuthStore((state: AuthState) => state.venue);
  const clearSession = useAuthStore((state: AuthState) => state.clearSession);
  const { isReady } = useAuthenticatedSession();
  const me = useQuery(api.app.getMe, isReady ? {} : 'skip');
  const serverRole = me?.profile.role ?? null;
  const allAccess = me?.profile.allAccess ?? false;
  const canManage = Boolean(serverRole && canManageVenue(serverRole, allAccess));
  const canViewBilling = Boolean(serverRole && canManageBilling(serverRole, allAccess));
  const { signOut } = useAuthActions();
  const deleteAccount = useMutation(api.app.deleteMyAccount);
  const [confirmDelete, setConfirmDelete] = useState(false);
  const [deleting, setDeleting] = useState(false);
  const [ownedVenueBlock, setOwnedVenueBlock] = useState<string | null>(null);
  // Irreversible action: promote the guard from a useState check (which
  // doesn't apply until the next render, so two taps in one tick both pass)
  // to a ref that blocks re-entry synchronously.
  const deletingRef = useRef(false);

  const onLogout = async () => {
    try {
      await signOut();
    } finally {
      await clearSession();
      router.replace('/(auth)/welcome');
    }
  };

  const onOpenStaff = () => {
    router.push('/(tabs)/staff');
  };

  const onOpenBilling = () => {
    router.push(Platform.OS === 'web' ? '/billing' : '/billing/paywall');
  };

  // Two-step by design. Sending deleteOwnedVenues:true up front pre-authorises
  // destroying every venue where this account is the sole owner — including
  // ones the user isn't currently looking at. `serverRole` only describes the
  // ACTIVE venue, so the owner warning above cannot be trusted to have been
  // shown. Send false first and let the server tell us what is at risk.
  const onDeleteAccount = async (deleteOwnedVenues: boolean) => {
    if (deletingRef.current) return;
    deletingRef.current = true;
    setDeleting(true);
    try {
      await deleteAccount({ deleteOwnedVenues });
      await clearSession();
      router.replace('/(auth)/welcome');
    } catch (e) {
      // 409 means "you solely own at least one venue" — surface the server's
      // own explanation and require a second, explicit confirmation.
      if (!deleteOwnedVenues && e instanceof ApiError && e.status === 409) {
        setOwnedVenueBlock(e.message);
        return;
      }
      Alert.alert(t('profile.deleteError.title'), e instanceof Error ? e.message : t('profile.deleteError.default'));
    } finally {
      deletingRef.current = false;
      setDeleting(false);
    }
  };

  return (
    <ScrollView style={{ flex: 1, backgroundColor: colors.background }} contentContainerStyle={{ padding: spacing.lg, paddingBottom: spacing.xxl }}>
      <PageHeader title={t('profile.title')} detail={venue?.name ?? t('profile.individualAccount')} />
      <Card style={{ backgroundColor: colors.surface, marginBottom: spacing.md, borderRadius: radius.soft }}>
        <Card.Content style={{ gap: 6 }}>
          <Text>{user?.full_name}</Text>
          <Text style={{ color: colors.muted }}>{user?.email}</Text>
          <Text style={{ color: colors.muted }}>{user?.job_title}</Text>
          <Text style={{ color: colors.muted }}>{venue?.name ?? t('profile.individualAccount')}</Text>
        </Card.Content>
      </Card>

      {canManage ? (
        <Button mode="contained" buttonColor={colors.primary} onPress={onOpenStaff} style={{ marginBottom: spacing.sm }}>
          {t('profile.manageStaff')}
        </Button>
      ) : null}

      {canManage ? <Button mode="outlined" textColor={colors.primary} icon="clipboard-list-outline" onPress={() => router.push('/setup')} style={{ marginBottom: spacing.sm }}>Setup & imports</Button> : null}

      {canManage ? (
        <Button mode="outlined" textColor={colors.primary} icon="map-marker-radius" onPress={() => router.push('/venue/settings')} style={{ marginBottom: spacing.sm }}>
          {t('profile.venueLocation')}
        </Button>
      ) : null}

      {canViewBilling ? (
        <Button mode="outlined" textColor={colors.primary} onPress={onOpenBilling} style={{ marginBottom: spacing.sm }}>
          {t('profile.billing')}
        </Button>
      ) : null}

      <Button mode="outlined" textColor={colors.primary} icon="notebook-outline" onPress={() => router.push('/logbook')} style={{ marginBottom: spacing.sm }}>
        {t('profile.shiftLogbook')}
      </Button>

      <Button mode="outlined" textColor={colors.primary} icon="clipboard-check-outline" onPress={() => router.push('/checklist')} style={{ marginBottom: spacing.sm }}>
        {t('profile.checklist')}
      </Button>

      <Button mode="outlined" textColor={colors.primary} icon="help-circle-outline" onPress={() => router.push('/help')} style={{ marginBottom: spacing.sm }}>
        {t('profile.helpGuide')}
      </Button>

      <Button mode="outlined" textColor={colors.primary} onPress={onLogout} style={{ marginBottom: spacing.sm }}>
        {t('profile.signOut')}
      </Button>

      <Card style={{ backgroundColor: colors.surface, borderRadius: radius.soft, marginTop: spacing.md }}>
        <Card.Content style={{ gap: spacing.sm }}>
          <Text variant="titleMedium" style={{ fontWeight: '800', color: colors.danger }}>{t('profile.accountDeletion.title')}</Text>
          <Text style={{ color: colors.muted }}>
            {t('profile.accountDeletion.description')}
          </Text>
          {!confirmDelete ? (
            <Button mode="outlined" textColor={colors.danger} icon="delete-outline" onPress={() => setConfirmDelete(true)}>
              {t('profile.accountDeletion.startButton')}
            </Button>
          ) : (
            <View style={{ gap: spacing.sm }}>
              <Text style={{ color: colors.danger, fontWeight: '700' }}>
                {t('profile.accountDeletion.confirmWarning')}
              </Text>
              {ownedVenueBlock ? (
                <>
                  {/* Server-supplied: it knows every venue this account solely
                      owns, which the client's active-venue role cannot tell us. */}
                  <Text style={{ color: colors.danger, fontWeight: '700' }}>
                    {ownedVenueBlock}
                  </Text>
                  <Text style={{ color: colors.danger }}>
                    {t('profile.accountDeletion.ownerWarning')}
                  </Text>
                  <Button
                    mode="contained"
                    buttonColor={colors.danger}
                    icon="delete-forever-outline"
                    loading={deleting}
                    disabled={deleting}
                    onPress={() => void onDeleteAccount(true)}
                  >
                    {t('profile.accountDeletion.confirmVenueButton')}
                  </Button>
                </>
              ) : (
                <Button
                  mode="contained"
                  buttonColor={colors.danger}
                  icon="delete-forever-outline"
                  loading={deleting}
                  disabled={deleting}
                  onPress={() => void onDeleteAccount(false)}
                >
                  {t('profile.accountDeletion.confirmButton')}
                </Button>
              )}
              <Button
                mode="text"
                textColor={colors.primary}
                disabled={deleting}
                onPress={() => {
                  setConfirmDelete(false);
                  setOwnedVenueBlock(null);
                }}
              >
                {t('profile.accountDeletion.cancelButton')}
              </Button>
            </View>
          )}
        </Card.Content>
      </Card>
    </ScrollView>
  );
}

export default function ProfileScreenWrapper() {
  return <ScreenErrorBoundary><ProfileScreen /></ScreenErrorBoundary>;
}

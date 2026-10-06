import { Alert, Image, Platform, ScrollView, View } from 'react-native';
import * as ImagePicker from 'expo-image-picker';
import { useRef, useState } from 'react';
import { router } from 'expo-router';
import { Avatar, Button, Card, Text, TextInput as PaperTextInput } from 'react-native-paper';
import { ScreenErrorBoundary } from '../../components/ErrorBoundary';
import { PageHeader } from '../../components/design-system';
import { useMutation, useQuery } from '../../lib/railway-hooks';
import { useAuthActions } from '../../lib/railway-hooks';
import { ApiError, resolveMediaUrl } from '../../lib/api-client';
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
  const hrProfile = useQuery(api.app.getMyHrProfile, isReady ? {} : 'skip') as {
    fullName: string; preferredName: string | null; phone: string | null; altPhone: string | null;
    address: string | null; dateOfBirth: string | null; hireDate: string | null;
    employmentType: string | null; hourlyRateCents: number | null; certifications: string[];
    sickHoursAccrued: number; ptoHoursAccrued: number; emergencyContactName: string | null;
    emergencyContactRelationship: string | null; emergencyContactPhone: string | null; photoUrl: string | null;
  } | null | undefined;
  const updateHrProfile = useMutation(api.app.updateMyHrProfile);
  const uploadMyPhoto = useMutation(api.app.uploadMyPhoto);
  const [editingHr, setEditingHr] = useState(false);
  const [savingHr, setSavingHr] = useState(false);
  const [uploadingPhoto, setUploadingPhoto] = useState(false);
  const [hrForm, setHrForm] = useState({ preferredName: '', phone: '', altPhone: '', address: '', dateOfBirth: '', emergencyContactName: '', emergencyContactRelationship: '', emergencyContactPhone: '' });
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

  const editHrProfile = () => {
    if (!hrProfile) return;
    setHrForm({
      preferredName: hrProfile.preferredName ?? '', phone: hrProfile.phone ?? '', altPhone: hrProfile.altPhone ?? '',
      address: hrProfile.address ?? '', dateOfBirth: hrProfile.dateOfBirth?.slice(0, 10) ?? '',
      emergencyContactName: hrProfile.emergencyContactName ?? '',
      emergencyContactRelationship: hrProfile.emergencyContactRelationship ?? '',
      emergencyContactPhone: hrProfile.emergencyContactPhone ?? '',
    });
    setEditingHr(true);
  };

  const pickMyPhoto = async () => {
    const result = await ImagePicker.launchImageLibraryAsync({ mediaTypes: ImagePicker.MediaTypeOptions.Images, allowsEditing: true, quality: 0.7, base64: true });
    const asset = result.canceled ? null : result.assets[0];
    if (!asset?.base64) return;
    setUploadingPhoto(true);
    try {
      await uploadMyPhoto({ dataBase64: asset.base64, mimeType: asset.mimeType ?? 'image/jpeg' });
    } catch (error) {
      Alert.alert('Photo upload failed', error instanceof Error ? error.message : 'Please try again.');
    } finally {
      setUploadingPhoto(false);
    }
  };

  const saveHrProfile = async () => {
    setSavingHr(true);
    try {
      await updateHrProfile(hrForm);
      setEditingHr(false);
    } catch (error) {
      Alert.alert('Profile update failed', error instanceof Error ? error.message : 'Please try again.');
    } finally {
      setSavingHr(false);
    }
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
          <View style={{ flexDirection: 'row', alignItems: 'center', gap: spacing.md }}>
            {hrProfile?.photoUrl ? <Image source={{ uri: resolveMediaUrl(hrProfile.photoUrl) }} style={{ width: 68, height: 68, borderRadius: 34 }} /> : <Avatar.Text size={68} label={(hrProfile?.preferredName || user?.full_name || 'U').slice(0, 1).toUpperCase()} />}
            <View style={{ flex: 1 }}><Text variant="titleMedium">{hrProfile?.preferredName || user?.full_name}</Text><Text style={{ color: colors.muted }}>{user?.job_title}</Text></View>
          </View>
          <Text style={{ color: colors.muted }}>{user?.email}</Text>
          <Text style={{ color: colors.muted }}>{venue?.name ?? t('profile.individualAccount')}</Text>
          <Button mode="outlined" icon="camera-outline" loading={uploadingPhoto} disabled={uploadingPhoto} onPress={() => void pickMyPhoto()}>Upload my photo</Button>
        </Card.Content>
      </Card>

      <Card style={{ backgroundColor: colors.surface, marginBottom: spacing.md, borderRadius: radius.soft }}>
        <Card.Content style={{ gap: spacing.sm }}>
          <Text variant="titleMedium" style={{ fontWeight: '700' }}>My HR profile</Text>
          <Text style={{ color: colors.muted }}>Contact and emergency details are available to you and authorized managers.</Text>
          {editingHr ? <>
            {([
              ['preferredName', 'Preferred name'], ['phone', 'Phone'], ['altPhone', 'Alternate phone'],
              ['address', 'Address'], ['dateOfBirth', 'Date of birth (YYYY-MM-DD)'],
              ['emergencyContactName', 'Emergency contact name'], ['emergencyContactRelationship', 'Relationship'],
              ['emergencyContactPhone', 'Emergency contact phone'],
            ] as const).map(([key, label]) => <PaperTextInput key={key} label={label} value={hrForm[key]} onChangeText={(value) => setHrForm((current) => ({ ...current, [key]: value }))} mode="outlined" style={{ backgroundColor: colors.surface }} />)}
            <Button mode="contained" buttonColor={colors.primary} loading={savingHr} disabled={savingHr} onPress={() => void saveHrProfile()}>Save details</Button>
            <Button mode="text" onPress={() => setEditingHr(false)}>Cancel</Button>
          </> : <>
            <Text>Phone: {hrProfile?.phone || 'Not added'}</Text>
            <Text>Address: {hrProfile?.address || 'Not added'}</Text>
            <Text>Hire date: {hrProfile?.hireDate?.slice(0, 10) || 'Not added'}</Text>
            <Text>Employment: {hrProfile?.employmentType?.replace('_', ' ') || 'Not added'}</Text>
            <Text>Hourly rate: {hrProfile?.hourlyRateCents == null ? 'Not added' : `$${(hrProfile.hourlyRateCents / 100).toFixed(2)}`}</Text>
            <Text>Certifications: {hrProfile?.certifications?.join(', ') || 'Not added'}</Text>
            <Text>Leave balance: {hrProfile?.ptoHoursAccrued ?? 0} PTO hours · {hrProfile?.sickHoursAccrued ?? 0} sick hours</Text>
            <Text>Emergency contact: {hrProfile?.emergencyContactName || 'Not added'}{hrProfile?.emergencyContactPhone ? ` · ${hrProfile.emergencyContactPhone}` : ''}</Text>
            <Button mode="outlined" icon="pencil-outline" onPress={editHrProfile} disabled={!hrProfile}>Edit my details</Button>
          </>}
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

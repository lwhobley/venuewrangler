import { Button } from '../../components/AppButton';
import { useEffect, useRef, useState } from 'react';
import { Alert, ScrollView, View } from 'react-native';
import { FormScreen } from '../../components/FormScreen';
import { router } from 'expo-router';
import { IconButton, Text, TextInput } from 'react-native-paper';
import { useMutation, useQuery } from '../../lib/railway-hooks';
import { api } from '../../lib/railway-api';
import { colors, spacing, type } from '../../lib/theme';
import { AppCard, SectionHeader } from '../../components/AppCard';
import { ScreenErrorBoundary } from '../../components/ErrorBoundary';
import { VenueSwitcher } from '../../components/VenueSwitcher';
import { useAuthStore, type AuthState } from '../../lib/auth-store';
import { useAuthenticatedSession } from '../../lib/auth-readiness';
import { getPreciseLocation } from '../../lib/location';
import { canManageVenue } from '../../lib/permissions';
import { useI18n } from '../../lib/i18n';
import { venueFromApi } from '../../lib/session-from-auth';

function VenueSettingsScreen() {
  const { t } = useI18n();
  const venue = useAuthStore((state: AuthState) => state.venue);
  const setVenue = useAuthStore((state: AuthState) => state.setVenue);
  const updateVenue = useMutation(api.app.updateVenue);
  const rotateVenueJoinCode = useMutation(api.app.rotateVenueJoinCode);

  const { isReady, user } = useAuthenticatedSession();
  const me = useQuery(api.app.getMe, isReady ? {} : 'skip');
  const canManage = Boolean(me && canManageVenue(me.profile.role, me.profile.allAccess));
  const joinCode = useQuery<{ code: string }>(api.app.getVenueJoinCode, isReady && canManage ? {} : 'skip');

  const [name, setName] = useState(venue?.name ?? '');
  const [lat, setLat] = useState(venue ? String(venue.latitude) : '');
  const [lng, setLng] = useState(venue ? String(venue.longitude) : '');
  const [radius, setRadius] = useState(venue?.geofence_radius_m ?? 120);
  const [timezone, setTimezone] = useState(venue?.timezone ?? '');
  const [earlyClockInWindowMin, setEarlyClockInWindowMin] = useState(venue?.earlyClockInWindowMin ?? 10);
  const [locating, setLocating] = useState(false);
  const [saving, setSaving] = useState(false);
  const savingRef = useRef(false);
  const [rotatingCode, setRotatingCode] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [saved, setSaved] = useState(false);

  useEffect(() => {
    if (!venue) return;
    setName(venue.name);
    setLat(String(venue.latitude));
    setLng(String(venue.longitude));
    setRadius(venue.geofence_radius_m ?? 120);
    setTimezone(venue.timezone ?? '');
    setEarlyClockInWindowMin(venue.earlyClockInWindowMin ?? 10);
  }, [venue]);

  const useMyLocation = async () => {
    if (locating) return;
    setError(null);
    setLocating(true);
    try {
      const loc = await getPreciseLocation();
      setLat(loc.latitude.toFixed(6));
      setLng(loc.longitude.toFixed(6));
    } catch (e) {
      setError(e instanceof Error ? e.message : t('venueSettings.couldNotReadLocation'));
    } finally {
      setLocating(false);
    }
  };

  const onSave = async () => {
    if (savingRef.current) return;
    setError(null);
    setSaved(false);
    if (!venue?.id) {
      setError(t('venueSettings.noVenueAssigned'));
      return;
    }
    const latitude = Number(lat);
    const longitude = Number(lng);
    if (Number.isNaN(latitude) || Number.isNaN(longitude)) {
      setError(t('venueSettings.invalidCoordinates'));
      return;
    }
    if (latitude === 0 && longitude === 0) {
      setError('Set a real venue location. 0,0 is not a valid geofence.');
      return;
    }
    savingRef.current = true;
    setSaving(true);
    try {
      const updated = await updateVenue({ venueId: venue.id, name: name.trim() || undefined, latitude, longitude, geofenceRadiusM: radius, timezone: timezone.trim() || undefined, earlyClockInWindowMin });
      setVenue(venueFromApi(updated));
      setSaved(true);
      setTimeout(() => setSaved(false), 2500);
    } catch (e) {
      setError(e instanceof Error ? e.message : t('venueSettings.couldNotSaveVenue'));
    } finally {
      savingRef.current = false;
      setSaving(false);
    }
  };

  const rotateJoinCode = () => {
    Alert.alert(
      t('venueSettings.rotateJoinCodeTitle'),
      t('venueSettings.rotateJoinCodeWarning'),
      [
        { text: t('venueSettings.cancel'), style: 'cancel' },
        {
          text: t('venueSettings.rotateJoinCode'),
          style: 'destructive',
          onPress: () => {
            setError(null);
            setRotatingCode(true);
            void rotateVenueJoinCode({}).catch((e) => {
              setError(e instanceof Error ? e.message : t('venueSettings.couldNotRotateJoinCode'));
            }).finally(() => setRotatingCode(false));
          },
        },
      ],
    );
  };

  // Venue switching is not a manager-only operation: render the header and
  // switcher for everyone and gate only the editing cards below. Otherwise a
  // user who is staff in the active venue has no path back to a venue they
  // manage.
  if (!canManage) {
    return (
      <ScrollView
        style={{ flex: 1, backgroundColor: colors.background }}
        contentContainerStyle={{ padding: spacing.lg, gap: spacing.md, paddingBottom: spacing.xxl }}
      >
        <View style={{ flexDirection: 'row', alignItems: 'center', gap: 4 }}>
          <IconButton icon="arrow-left" onPress={() => router.back()} />
          <View>
            <Text style={{ ...type.title, color: colors.charcoal }}>{t('venueSettings.title')}</Text>
            <Text style={{ color: colors.muted }}>{t('venueSettings.subtitle')}</Text>
          </View>
        </View>
        <VenueSwitcher />
        <Text style={{ color: colors.muted }}>{t('venueSettings.onlyManagersCanEdit')}</Text>
      </ScrollView>
    );
  }

  return (
    <FormScreen contentContainerStyle={{ padding: spacing.lg, gap: spacing.md, paddingBottom: spacing.xxl }}>
      <View style={{ flexDirection: 'row', alignItems: 'center', gap: 4 }}>
        <IconButton icon="arrow-left" onPress={() => router.back()} />
        <View>
          <Text style={{ ...type.title, color: colors.charcoal }}>{t('venueSettings.title')}</Text>
          <Text style={{ color: colors.muted }}>{t('venueSettings.subtitle')}</Text>
        </View>
      </View>

      <VenueSwitcher />

      {venue && venue.latitude === 0 && venue.longitude === 0 ? (
        <Text style={{ color: colors.danger }}>
          This venue has no map location yet. Clock-in is blocked until you set coordinates.
        </Text>
      ) : null}

      <AppCard>
          <SectionHeader title={t('venueSettings.detailsSection')} />
          <TextInput label={t('venueSettings.venueNameLabel')} value={name} onChangeText={setName} mode="outlined" style={{ backgroundColor: colors.surface }} />
          <TextInput label="Timezone (IANA)" value={timezone} onChangeText={setTimezone} mode="outlined" autoCapitalize="none" placeholder="America/New_York" style={{ backgroundColor: colors.surface }} />
      </AppCard>

      <AppCard>
        <SectionHeader title="Sales sync" />
        <Text style={{ color: colors.muted }}>Not connected. Connect a supported POS later to compare last-night sales with labor.</Text>
      </AppCard>

      <AppCard>
        <SectionHeader title="Time clock" />
        <Text style={{ color: colors.muted }}>Allow staff to clock in before their scheduled shift.</Text>
        <TextInput label="Early clock-in window (minutes)" value={String(earlyClockInWindowMin)} onChangeText={(value) => setEarlyClockInWindowMin(Math.max(0, Math.min(120, Number(value) || 0)))} mode="outlined" keyboardType="number-pad" style={{ backgroundColor: colors.surface }} />
        <Text style={{ color: colors.muted, fontSize: 12 }}>Enables the shared-device flow when staff PIN authentication is configured.</Text>
      </AppCard>

      <AppCard>
        <SectionHeader title={t('venueSettings.joinCodeSection')} />
        <Text style={{ color: colors.muted }}>{t('venueSettings.joinCodeNotice')}</Text>
        <Text selectable style={{ ...type.title, color: colors.charcoal, letterSpacing: 2, textAlign: 'center' }}>
          {joinCode?.code ?? t('common.loading')}
        </Text>
        <Button mode="outlined" icon="refresh" loading={rotatingCode} disabled={rotatingCode} onPress={rotateJoinCode}>
          {t('venueSettings.rotateJoinCode')}
        </Button>
      </AppCard>

      <AppCard>
          <SectionHeader title={t('venueSettings.locationSection')} />
          <View style={{ gap: spacing.sm }}>
          <Text style={{ color: colors.muted }}>
            {t('venueSettings.geofenceNotice')}
          </Text>
          <Button mode="contained" buttonColor={colors.primary} icon="crosshairs-gps" loading={locating} disabled={locating} onPress={() => void useMyLocation()}>
            {t('venueSettings.useMyLocation')}
          </Button>
          <View style={{ flexDirection: 'row', gap: spacing.sm }}>
            <TextInput label={t('venueSettings.latitudeLabel')} value={lat} onChangeText={setLat} mode="outlined" keyboardType="numbers-and-punctuation" autoCapitalize="none" style={{ flex: 1, backgroundColor: colors.surface }} />
            <TextInput label={t('venueSettings.longitudeLabel')} value={lng} onChangeText={setLng} mode="outlined" keyboardType="numbers-and-punctuation" autoCapitalize="none" style={{ flex: 1, backgroundColor: colors.surface }} />
          </View>
          <View style={{ flexDirection: 'row', alignItems: 'center', gap: 8 }}>
            <Text style={{ width: 110 }}>{t('venueSettings.geofenceRadius')}</Text>
            <IconButton icon="minus" mode="outlined" size={16} onPress={() => setRadius((r) => Math.max(20, r - 20))} accessibilityLabel={t('venueSettings.decreaseGeofenceRadius')} />
            <Text style={{ minWidth: 56, textAlign: 'center' }}>{radius} m</Text>
            <IconButton icon="plus" mode="outlined" size={16} onPress={() => setRadius((r) => Math.min(2000, r + 20))} accessibilityLabel={t('venueSettings.increaseGeofenceRadius')} />
          </View>
          </View>
      </AppCard>

      {error ? <Text style={{ color: colors.danger }}>{error}</Text> : null}
      {saved ? <Text style={{ color: colors.success, textAlign: 'center' }}>{t('venueSettings.saved')}</Text> : null}
      <Button mode="contained" buttonColor={colors.primary} icon="content-save" loading={saving} disabled={saving} onPress={() => void onSave()}>
        {t('venueSettings.saveVenueLocation')}
      </Button>
    </FormScreen>
  );
}

export default function VenueSettingsScreenWrapper() {
  return <ScreenErrorBoundary withNavRail={false}><VenueSettingsScreen /></ScreenErrorBoundary>;
}

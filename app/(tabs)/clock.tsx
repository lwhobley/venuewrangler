import { useEffect, useMemo, useRef, useState } from 'react';
import { Alert, Pressable, ScrollView, View, Linking, TextInput } from 'react-native';
import { Card, Text } from 'react-native-paper';
import { notifySuccess } from '../../lib/feedback';
import { MaterialCommunityIcons } from '@expo/vector-icons';
import { ScreenErrorBoundary } from '../../components/ErrorBoundary';
import { accents, colors, radius, spacing } from '../../lib/theme';
import { useAuthStore, type AuthState } from '../../lib/auth-store';
import { useAuthenticatedSession } from '../../lib/auth-readiness';
import { canManageVenue } from '../../lib/permissions';
import { formatTime, errorMessage } from '../../lib/format';
import { getPreciseLocation, isWithinGeofence, type CurrentLocation } from '../../lib/location';
import { ApiError, appApi, useApiMutation, type ApiClockBreak } from '../../lib/api-client';
import { useMutation, useQuery } from '../../lib/railway-hooks';
import { api } from '../../lib/railway-api';
import { attestPayload, resetAttestationKey } from '../../lib/attestation';
import { overnightAwareRange } from '../../lib/zoned-datetime';
import { venueFromApi } from '../../lib/session-from-auth';
import { useI18n } from '../../lib/i18n';

type ActiveClockEntry = {
  _id: string;
  memberName: string;
  jobTitle: string;
  venueName: string;
  clockInAt: number;
  clockInLat?: number | null;
  clockInLng?: number | null;
  clockInAccuracyM?: number | null;
  breaks?: ApiClockBreak[];
};

type ManagerAlert = {
  kind: 'late_clock_in' | 'missed_clock_out';
  severity: 'warning' | 'danger';
  profileId: string;
  memberName: string;
  detail: string;
};

type PunchRow = {
  type: 'in' | 'out';
  at: number;
};

function fmtClock(d: Date) {
  let h = d.getHours();
  const m = d.getMinutes();
  const ampm = h >= 12 ? 'PM' : 'AM';
  h = h % 12 === 0 ? 12 : h % 12;
  return { time: `${h}:${m.toString().padStart(2, '0')}`, ampm };
}
function fmtDate(d: Date) {
  return d.toLocaleDateString(undefined, { weekday: 'short', year: 'numeric', month: 'short', day: 'numeric' });
}

function ClockScreen() {
  const { t } = useI18n();
  const user = useAuthStore((state: AuthState) => state.user);
  const venue = useAuthStore((state: AuthState) => state.venue);
  const { isReady } = useAuthenticatedSession();
  const [location, setLocation] = useState<CurrentLocation | null>(null);
  const [loadingLocation, setLoadingLocation] = useState(true);
  const [now, setNow] = useState(() => new Date());
  const [busy, setBusy] = useState(false);
  const busyRef = useRef(false);

  const clockBoard = useQuery(api.app.getClockBoard, isReady ? {} : 'skip') as any;
  const dashboard = useQuery(api.app.getDashboard, isReady ? {} : 'skip') as any;
  const timeClock = useQuery(api.app.getMyTimeClock, isReady ? {} : 'skip') as any;

  const clockIn = useMutation(api.app.clockIn);
  const clockOut = useMutation(api.app.clockOut);
  const breakStart = useMutation(api.app.breakStart);
  const breakEnd = useMutation(api.app.breakEnd);
  const createCorrectionRequest = useApiMutation(appApi.createStaffRequest, [['app', 'listStaffRequests']]);

  const [showCorrection, setShowCorrection] = useState(false);
  const [correctionDate, setCorrectionDate] = useState('');
  const [correctionInTime, setCorrectionInTime] = useState('');
  const [correctionOutTime, setCorrectionOutTime] = useState('');
  const [correctionReason, setCorrectionReason] = useState('');

  // Admin/owner/manager are salaried: they don't punch a time clock.
  const salaried = Boolean(dashboard?.profile && canManageVenue(dashboard.profile.role, dashboard.profile.allAccess));
  const isAdmin = salaried;

  const rawVenue = venue ?? clockBoard?.venue ?? dashboard?.venue ?? null;
  const activeVenue = useMemo(() => (rawVenue ? venueFromApi(rawVenue) : null), [rawVenue]);

  const activeClockEntries = (clockBoard?.activeClockEntries ?? []) as ActiveClockEntry[];
  const managerAlerts = (clockBoard?.managerAlerts ?? []) as ManagerAlert[];
  const isClockedIn = timeClock?.isClockedIn ?? Boolean(clockBoard?.employeeEntry);

  const employeeEntry = clockBoard?.employeeEntry;
  const breaks = (employeeEntry?.breaks || []) as ApiClockBreak[];
  const activeBreak = breaks.find((b) => b.endAt === null);
  const isOnBreak = Boolean(activeBreak);
  const breakType = activeBreak?.type;

  // Live ticking clock.
  useEffect(() => {
    const id = setInterval(() => setNow(new Date()), 1000);
    return () => clearInterval(id);
  }, []);

  useEffect(() => {
    let cancelled = false;
    setLoadingLocation(true);
    getPreciseLocation()
      .then((next) => !cancelled && setLocation(next))
      .catch((error) => {
        if (!cancelled) Alert.alert(t('clock.locationNeededTitle'), errorMessage(error, t('clock.locationUnavailable')));
      })
      .finally(() => !cancelled && setLoadingLocation(false));
    return () => {
      cancelled = true;
    };
  }, []);

  const canClock = Boolean(
    activeVenue &&
      location &&
      isWithinGeofence(location, {
        latitude: activeVenue.latitude,
        longitude: activeVenue.longitude,
        geofenceRadiusM: activeVenue.geofenceRadiusM ?? 120,
      })
  );

  const onPunch = async () => {
    if (!activeVenue || busyRef.current) return;
    busyRef.current = true;
    setBusy(true);
    try {
      const fresh = await getPreciseLocation();
      setLocation(fresh);
      if (
        !isWithinGeofence(fresh, {
          latitude: activeVenue.latitude,
          longitude: activeVenue.longitude,
          geofenceRadiusM: activeVenue.geofenceRadiusM ?? 120,
        })
      ) {
        Alert.alert(
          t('clock.punchFailedTitle'),
          t('clock.mustBeWithin', { radius: activeVenue.geofenceRadiusM ?? 120, venue: activeVenue.name ?? t('common.yourVenue') }),
        );
        return;
      }
      const punch = { lat: fresh.latitude, lng: fresh.longitude, accuracy: fresh.accuracy, mocked: fresh.mocked };
      const submit = async () => {
        // Prove this punch came from a genuine build on real hardware. Returns
        // null on devices that cannot attest; the server still accepts those
        // until ATTESTATION_ENFORCED is turned on.
        const attestation = await attestPayload(punch);
        const args = { ...punch, ...(attestation ? { attestation } : {}) };
        if (isClockedIn) await clockOut(args);
        else await clockIn(args);
      };
      try {
        await submit();
      } catch (error) {
        // A shared-device account switch can invalidate a previously cached
        // App Attest key. Re-enrol and retry exactly once on that server signal.
        if (!(error instanceof ApiError) || !/not registered for attestation/i.test(error.message)) throw error;
        await resetAttestationKey();
        await submit();
      }
      notifySuccess();
    } catch (error) {
      Alert.alert(t('clock.punchFailedTitle'), errorMessage(error, t('clock.punchFailedDefault')));
    } finally {
      busyRef.current = false;
      setBusy(false);
    }
  };

  const onStartBreak = async (type: 'paid' | 'unpaid') => {
    if (busyRef.current) return;
    busyRef.current = true;
    setBusy(true);
    try {
      await breakStart({ type });
      notifySuccess();
    } catch (error) {
      Alert.alert(t('clock.breakFailedTitle'), errorMessage(error, t('clock.breakFailedDefault')));
    } finally {
      busyRef.current = false;
      setBusy(false);
    }
  };

  const onEndBreak = async () => {
    if (busyRef.current) return;
    busyRef.current = true;
    setBusy(true);
    try {
      await breakEnd({});
      notifySuccess();
    } catch (error) {
      Alert.alert(t('clock.endBreakFailedTitle'), errorMessage(error, t('clock.endBreakFailedDefault')));
    } finally {
      busyRef.current = false;
      setBusy(false);
    }
  };

  const onSubmitCorrection = async () => {
    if (!correctionDate || !correctionInTime || !correctionOutTime || !correctionReason) {
      Alert.alert(t('clock.errorTitle'), t('clock.fillAllFields'));
      return;
    }
    if (!/^\d{4}-\d{2}-\d{2}$/.test(correctionDate)) {
      Alert.alert(t('clock.errorTitle'), t('clock.dateFormatError'));
      return;
    }
    if (!/^\d{2}:\d{2}$/.test(correctionInTime) || !/^\d{2}:\d{2}$/.test(correctionOutTime)) {
      Alert.alert(t('clock.errorTitle'), t('clock.timeFormatError'));
      return;
    }
    // Shares busyRef with the punch/break handlers on purpose: without it a
    // correction could be submitted twice (double-crediting hours once a
    // manager approves both), and a punch could run concurrently with it.
    if (busyRef.current) return;
    busyRef.current = true;
    setBusy(true);
    try {
      const { start: clockInAt, end: clockOutAt } = overnightAwareRange(
        correctionDate,
        correctionInTime,
        correctionOutTime,
        venue?.timezone,
      );
      if (isNaN(clockInAt) || isNaN(clockOutAt)) {
        Alert.alert(t('clock.errorTitle'), t('clock.invalidDateTime'));
        return;
      }
      if (clockOutAt <= clockInAt) {
        Alert.alert(t('clock.errorTitle'), t('clock.clockOutAfterClockIn'));
        return;
      }
      await createCorrectionRequest.mutateAsync({
        kind: 'time_correction',
        title: t('clock.correctionTitle', { date: correctionDate }),
        details: t('clock.correctionDetails', { date: correctionDate, inTime: correctionInTime, outTime: correctionOutTime, reason: correctionReason }),
        timeCorrection: {
          timeEntryId: null,
          clockInAt,
          clockOutAt,
          reason: correctionReason,
        },
      });
      Alert.alert(t('clock.successTitle'), t('clock.correctionSubmitted'));
      setShowCorrection(false);
      setCorrectionDate('');
      setCorrectionInTime('');
      setCorrectionOutTime('');
      setCorrectionReason('');
    } catch (error) {
      Alert.alert(t('clock.submissionFailedTitle'), errorMessage(error, t('clock.submissionFailedDefault')));
    } finally {
      busyRef.current = false;
      setBusy(false);
    }
  };

  const { time, ampm } = fmtClock(now);
  const punches = (timeClock?.punches ?? []) as PunchRow[];

  return (
    <ScrollView
      style={{ flex: 1, backgroundColor: colors.background }}
      contentContainerStyle={{ padding: spacing.lg, gap: spacing.md, paddingBottom: spacing.xxl }}
      showsVerticalScrollIndicator={false}
    >
      {/* Header: live time + date + venue pill */}
      <View style={{ backgroundColor: colors.primary, borderRadius: radius.soft, padding: spacing.xl, alignItems: 'center', gap: 6 }}>
        <Text style={{ color: 'rgba(255,255,255,0.85)', fontWeight: '700' }}>{user?.full_name ?? t('clock.defaultUserName')}</Text>
        <View style={{ flexDirection: 'row', alignItems: 'flex-end' }}>
          <Text style={{ color: '#fff', fontSize: 56, fontWeight: '800', lineHeight: 60 }}>{time}</Text>
          <Text style={{ color: '#fff', fontSize: 20, fontWeight: '700', marginBottom: 8, marginLeft: 4 }}>{ampm}</Text>
        </View>
        <Text style={{ color: 'rgba(255,255,255,0.9)', fontSize: 16, fontWeight: '600' }}>{fmtDate(now)}</Text>
        <View style={{ marginTop: 8, backgroundColor: 'rgba(255,255,255,0.18)', borderRadius: 999, paddingVertical: 8, paddingHorizontal: 18 }}>
          <Text style={{ color: '#fff', fontWeight: '600' }}>{activeVenue?.name ?? t('clock.noVenue')}</Text>
        </View>
      </View>

      {salaried ? (
        <Card style={{ backgroundColor: colors.surface, borderRadius: radius.sharp }}>
          <Card.Content style={{ gap: 4 }}>
            <Text variant="titleMedium" style={{ fontWeight: '700' }}>{t('clock.salariedTitle')}</Text>
            <Text style={{ color: colors.muted }}>
              {t('clock.salariedDesc', { role: ((r: string) => r.charAt(0).toUpperCase() + r.slice(1))(user?.role ?? 'manager') })}
            </Text>
          </Card.Content>
        </Card>
      ) : null}

      {!salaried ? (
        <>
          {/* Punch Now button */}
          {isClockedIn && isOnBreak ? (
            <Pressable
              onPress={() => void onEndBreak()}
              disabled={busy}
              accessibilityRole="button"
              accessibilityState={{ disabled: busy, busy }}
              style={{
                backgroundColor: accents[1].fg,
                borderRadius: radius.sharp,
                paddingVertical: 20,
                alignItems: 'center',
                opacity: busy ? 0.7 : 1,
              }}
            >
              <Text style={{ color: '#fff', fontSize: 18, fontWeight: '800' }}>
                {busy ? t('clock.working') : t('clock.endBreak', { type: breakType === 'paid' ? t('clock.paid') : t('clock.unpaid') })}
              </Text>
            </Pressable>
          ) : (
            <Pressable
              onPress={() => void onPunch()}
              disabled={!canClock || busy}
              accessibilityRole="button"
              accessibilityState={{ disabled: !canClock || busy, busy }}
              accessibilityHint={
                canClock
                  ? undefined
                  : t('clock.a11y.outsideGeofenceHint')
              }
              style={{
                backgroundColor: canClock ? (isClockedIn ? colors.danger : colors.secondary) : colors.border,
                borderRadius: radius.sharp,
                paddingVertical: 20,
                alignItems: 'center',
                opacity: busy ? 0.7 : 1,
              }}
            >
              <Text style={{ color: '#fff', fontSize: 18, fontWeight: '800' }}>
                {busy ? t('clock.working') : isClockedIn ? t('clock.punchOut') : t('clock.punchNow')}
              </Text>
            </Pressable>
          )}

          {isClockedIn && !isOnBreak && (
            <Pressable
              accessibilityRole="button"
              accessibilityState={{ disabled: busy }}
              onPress={() => {
                Alert.alert(
                  t('clock.takeBreakTitle'),
                  t('clock.takeBreakMessage'),
                  [
                    { text: t('clock.paidRestBreak'), onPress: () => void onStartBreak('paid') },
                    { text: t('clock.unpaidMealBreak'), onPress: () => void onStartBreak('unpaid') },
                    { text: t('clock.cancel'), style: 'cancel' }
                  ]
                );
              }}
              disabled={busy}
              style={{
                backgroundColor: colors.primary,
                borderRadius: radius.sharp,
                paddingVertical: 12,
                alignItems: 'center',
                marginTop: 4,
                opacity: busy ? 0.7 : 1,
              }}
            >
              <Text style={{ color: '#fff', fontSize: 16, fontWeight: '700' }}>{t('clock.takeBreak')}</Text>
            </Pressable>
          )}

          {!canClock ? (
            <Text style={{ color: colors.muted, textAlign: 'center', marginTop: -4 }}>
              {loadingLocation
                ? t('clock.checkingLocation')
                : !location
                  ? t('clock.locationUnavailableMsg')
                  : location.mocked
                    ? t('clock.mockedLocation')
                    : t('clock.mustBeWithin', { radius: activeVenue?.geofenceRadiusM ?? 120, venue: activeVenue?.name ?? t('common.yourVenue') })}
            </Text>
          ) : (
            <Text style={{ color: accents[2].fg, textAlign: 'center', marginTop: -4 }}>
              {t('clock.insideGeofence')}{timeClock?.openSince ? t('clock.inSince', { time: formatTime(timeClock.openSince) }) : ''}{isOnBreak ? t('clock.onBreakSuffix', { type: breakType === 'paid' ? t('clock.paid') : t('clock.unpaid') }) : ''}
            </Text>
          )}

          {/* Period totals */}
          <Card style={{ backgroundColor: colors.surface, borderRadius: radius.sharp }}>
            <Card.Content style={{ gap: spacing.sm }}>
              <View style={{ flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center' }}>
                <Text variant="titleMedium" style={{ fontWeight: '700' }}>{t('clock.periodTotals')}</Text>
                <Text style={{ color: colors.primary, fontWeight: '800' }}>{t('clock.totalWorked', { hours: timeClock?.totalHours ?? 0 })}</Text>
              </View>
              <View style={{ flexDirection: 'row', justifyContent: 'space-between', borderBottomWidth: 1, borderBottomColor: colors.border, paddingBottom: 8 }}>
                <View>
                  <Text style={{ color: colors.muted }}>{t('clock.regularHours')}</Text>
                  <Text style={{ fontWeight: '700' }}>{timeClock?.regularHours ?? 0}h</Text>
                </View>
              </View>
              <View style={{ flexDirection: 'row', gap: spacing.lg, paddingTop: 4 }}>
                <View>
                  <Text style={{ color: colors.muted }}>{t('clock.sickBalance')}</Text>
                  <Text style={{ fontWeight: '700', color: accents[1].fg }}>{timeClock?.sickHours ?? 0}h</Text>
                </View>
                <View>
                  <Text style={{ color: colors.muted }}>{t('clock.ptoAccrued')}</Text>
                  <Text style={{ fontWeight: '700', color: accents[2].fg }}>{timeClock?.ptoHours ?? 0}h</Text>
                </View>
              </View>
            </Card.Content>
          </Card>

          {/* Daily punches */}
          <Card style={{ backgroundColor: colors.surface, borderRadius: radius.sharp }}>
            <Card.Content style={{ gap: spacing.sm }}>
              <View style={{ flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center' }}>
                <Text variant="titleMedium" style={{ fontWeight: '700' }}>{t('clock.dailyPunches')}</Text>
                <Text style={{ color: colors.muted, fontSize: 12 }}>{fmtDate(now)}</Text>
              </View>
              {punches.length === 0 ? (
                <Text style={{ color: colors.muted }}>{t('clock.noPunchesYet')}</Text>
              ) : (
                punches.map((p, i) => (
                  <View key={i} style={{ flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', paddingVertical: 8, borderBottomWidth: i < punches.length - 1 ? 1 : 0, borderBottomColor: colors.border }}>
                    <View style={{ flexDirection: 'row', alignItems: 'center', gap: 8 }}>
                      <MaterialCommunityIcons name={p.type === 'in' ? 'login' : 'logout'} size={18} color={p.type === 'in' ? accents[2].fg : colors.danger} />
                      <Text>{p.type === 'in' ? t('clock.clockIn') : t('clock.clockOut')}</Text>
                    </View>
                    <Text style={{ color: colors.primary, fontWeight: '700' }}>{formatTime(p.at)}</Text>
                  </View>
                ))
              )}
            </Card.Content>
          </Card>

          {/* Time Correction Form */}
          <Card style={{ backgroundColor: colors.surface, borderRadius: radius.sharp }}>
            <Card.Content style={{ gap: spacing.sm }}>
              <Pressable
                accessibilityRole="button"
                accessibilityState={{ expanded: showCorrection }}
                onPress={() => setShowCorrection(!showCorrection)}
                style={{ flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center' }}
              >
                <Text variant="titleMedium" style={{ fontWeight: '700' }}>{t('clock.requestTimeCorrection')}</Text>
                <MaterialCommunityIcons
                  name={showCorrection ? 'chevron-up' : 'chevron-down'}
                  size={20}
                  color={colors.muted}
                />
              </Pressable>

              {showCorrection && (
                <View style={{ gap: spacing.sm, marginTop: spacing.xs }}>
                  <Text style={{ color: colors.muted, fontSize: 12 }}>
                    {t('clock.correctionHelp')}
                  </Text>
                  <View style={{ gap: spacing.xs }}>
                    <Text style={{ fontWeight: '600', fontSize: 12, color: colors.charcoal }}>{t('clock.dateLabel')}</Text>
                    <TextInput
                      placeholder={t('clock.datePlaceholder')}
                      value={correctionDate}
                      onChangeText={setCorrectionDate}
                      placeholderTextColor={colors.muted}
                      style={{
                        borderWidth: 1,
                        borderColor: colors.border,
                        borderRadius: radius.sharp,
                        padding: 10,
                        backgroundColor: colors.surface,
                        color: colors.charcoal,
                      }}
                    />
                  </View>
                  <View style={{ flexDirection: 'row', gap: spacing.sm }}>
                    <View style={{ flex: 1, gap: spacing.xs }}>
                      <Text style={{ fontWeight: '600', fontSize: 12, color: colors.charcoal }}>{t('clock.inTimeLabel')}</Text>
                      <TextInput
                        placeholder={t('clock.inTimePlaceholder')}
                        value={correctionInTime}
                        onChangeText={setCorrectionInTime}
                        placeholderTextColor={colors.muted}
                        style={{
                          borderWidth: 1,
                          borderColor: colors.border,
                          borderRadius: radius.sharp,
                          padding: 10,
                          backgroundColor: colors.surface,
                          color: colors.charcoal,
                        }}
                      />
                    </View>
                    <View style={{ flex: 1, gap: spacing.xs }}>
                      <Text style={{ fontWeight: '600', fontSize: 12, color: colors.charcoal }}>{t('clock.outTimeLabel')}</Text>
                      <TextInput
                        placeholder={t('clock.outTimePlaceholder')}
                        value={correctionOutTime}
                        onChangeText={setCorrectionOutTime}
                        placeholderTextColor={colors.muted}
                        style={{
                          borderWidth: 1,
                          borderColor: colors.border,
                          borderRadius: radius.sharp,
                          padding: 10,
                          backgroundColor: colors.surface,
                          color: colors.charcoal,
                        }}
                      />
                    </View>
                  </View>
                  <View style={{ gap: spacing.xs }}>
                    <Text style={{ fontWeight: '600', fontSize: 12, color: colors.charcoal }}>{t('clock.reasonLabel')}</Text>
                    <TextInput
                      placeholder={t('clock.reasonPlaceholder')}
                      value={correctionReason}
                      onChangeText={setCorrectionReason}
                      placeholderTextColor={colors.muted}
                      style={{
                        borderWidth: 1,
                        borderColor: colors.border,
                        borderRadius: radius.sharp,
                        padding: 10,
                        backgroundColor: colors.surface,
                        color: colors.charcoal,
                      }}
                    />
                  </View>
                  <Pressable
                    accessibilityRole="button"
                    accessibilityState={{ disabled: busy, busy }}
                    onPress={() => void onSubmitCorrection()}
                    disabled={busy}
                    style={{
                      backgroundColor: colors.primary,
                      borderRadius: radius.sharp,
                      paddingVertical: 12,
                      alignItems: 'center',
                      marginTop: 4,
                      opacity: busy ? 0.7 : 1,
                    }}
                  >
                    <Text style={{ color: '#fff', fontWeight: '800' }}>{t('clock.submitCorrection')}</Text>
                  </Pressable>
                </View>
              )}
            </Card.Content>
          </Card>
        </>
      ) : null}

      {/* Manager board */}
      {isAdmin ? (
        <>
          <Card style={{ backgroundColor: managerAlerts.length > 0 ? `${colors.danger}1A` : colors.surface, borderRadius: radius.sharp }}>
            <Card.Content style={{ gap: spacing.sm }}>
              <Text variant="titleMedium" style={{ fontWeight: '700' }}>{t('clock.managerAlerts')}</Text>
              {managerAlerts.length === 0 ? (
                <Text style={{ color: colors.muted }}>{t('clock.noAlerts')}</Text>
              ) : (
                managerAlerts.map((alert) => (
                  <View key={`${alert.kind}-${alert.profileId}`} style={{ gap: 2, paddingVertical: 8, borderBottomWidth: 1, borderBottomColor: colors.border }}>
                    <Text style={{ color: alert.severity === 'danger' ? colors.danger : accents[1].fg, fontWeight: '800' }}>{alert.memberName}</Text>
                    <Text style={{ color: colors.charcoal }}>{alert.detail}</Text>
                  </View>
                ))
              )}
            </Card.Content>
          </Card>
          <Card style={{ backgroundColor: colors.surface, borderRadius: radius.sharp }}>
            <Card.Content style={{ gap: spacing.sm }}>
              <Text variant="titleMedium" style={{ fontWeight: '700' }}>{t('clock.whosClockedIn')}</Text>
              {activeClockEntries.length === 0 ? (
                <Text style={{ color: colors.muted }}>{t('clock.noOneClockedIn')}</Text>
              ) : (
                activeClockEntries.map((e) => (
                  <View key={e._id} style={{ paddingVertical: 8, borderBottomWidth: 1, borderBottomColor: colors.border }}>
                    <View style={{ flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center' }}>
                      <View>
                        <Text style={{ fontWeight: '600' }}>{e.memberName}</Text>
                        <Text style={{ color: colors.muted }}>{e.jobTitle}</Text>
                      </View>
                      <Text style={{ color: colors.muted }}>{t('clock.inTimeValue', { time: formatTime(e.clockInAt) })}</Text>
                    </View>
                    {Number.isFinite(e.clockInLat) && Number.isFinite(e.clockInLng) && e.clockInLat !== 0 && e.clockInLng !== 0 && (
                      <Pressable
                        accessibilityRole="button"
                        accessibilityLabel={t('clock.a11y.openPunchLocation')}
                        onPress={() => {
                          const url = `https://www.google.com/maps/search/?api=1&query=${e.clockInLat},${e.clockInLng}`;
                          Linking.openURL(url).catch(() => Alert.alert(t('clock.errorTitle'), t('clock.mapError')));
                        }}
                        style={{ flexDirection: 'row', alignItems: 'center', gap: 4, marginTop: 4 }}
                      >
                        <MaterialCommunityIcons name="map-marker" size={14} color={colors.primary} />
                        <Text style={{ color: colors.primary, fontSize: 12, fontWeight: '600' }}>
                          {t('clock.punchLocation', { accuracy: Math.round(e.clockInAccuracyM ?? 0) })}
                        </Text>
                      </Pressable>
                    )}
                  </View>
                ))
              )}
            </Card.Content>
          </Card>
        </>
      ) : null}
    </ScrollView>
  );
}

export default function ClockScreenWrapper() {
  return <ScreenErrorBoundary><ClockScreen /></ScreenErrorBoundary>;
}

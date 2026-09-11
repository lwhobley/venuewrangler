import { useMemo, useRef, useState } from 'react';
import { ScrollView, View } from 'react-native';
import { Button, Card, SegmentedButtons, Snackbar, Text } from 'react-native-paper';
import { ScreenErrorBoundary } from '../../components/ErrorBoundary';
import { AnimatedTab, SectionHeader } from '../../components/AppCard';
import { useI18n } from '../../lib/i18n';
import { useMutation, useQuery } from '../../lib/railway-hooks';
import { api } from '../../lib/railway-api';
import type { Id } from '../../lib/ids';
import { colors, radius, spacing } from '../../lib/theme';
import { useDesktopContentStyle } from '../../lib/responsive';
import { useVenueAuth } from '../../lib/useVenueAuth';
import { errorMessage } from '../../lib/format';
import { correctionSummary } from '../../lib/staff-request-summary';
import { ManagerCalendar } from '../../components/schedule/ManagerCalendar';
import { MyShifts } from '../../components/schedule/MyShifts';
import { BlackoutManager } from '../../components/schedule/BlackoutManager';
import { LaborForecastPanel } from '../../components/schedule/LaborForecastPanel';

type StaffRequest = {
  _id: string;
  title: string;
  kind: 'add_shift' | 'drop_shift' | 'time_off' | 'sick_leave' | 'time_correction' | 'shift_swap' | 'open_shift' | 'other';
  status: 'pending' | 'approved' | 'denied' | 'cancelled';
  details: string;
  // The correction payload the server applies on approval. Rendered next to
  // `details` so the approver sees the times, not only the explanation.
  availability?: unknown;
};

type SwapRow = { _id: Id<'shiftSwaps'>; status: string; requesterName: string; targetName: string; requesterShift: string; targetShift: string | null };

function RequestQueue({ venueId, timeZone }: { venueId: Id<'venues'>; timeZone?: string | null }) {
  const { t } = useI18n();
  const queueQuery = useQuery(api.app.listStaffRequests, { venueId });
  const reviewRequest = useMutation(api.app.reviewStaffRequest);
  const queue = useMemo(() => (queueQuery ?? []) as StaffRequest[], [queueQuery]);
  const swapsQuery = useQuery(api.scheduling.listShiftSwaps, { venueId });
  const reviewSwap = useMutation(api.scheduling.reviewShiftSwap);
  const swaps = useMemo(() => (swapsQuery ?? []) as SwapRow[], [swapsQuery]);
  const [toast, setToast] = useState<string | null>(null);

  // react-native-paper's Button forwards `disabled` to the touchable but NOT
  // `loading`, so a spinner alone never blocks a second press. A ref (not
  // state) because the guard has to hold before the next render commits.
  const busyRef = useRef(false);
  const [busy, setBusy] = useState(false);

  const safe = async (action: () => Promise<unknown>, ok?: string) => {
    if (busyRef.current) return;
    busyRef.current = true;
    setBusy(true);
    try {
      await action();
      if (ok) setToast(ok);
    } catch (e) {
      setToast(errorMessage(e, t('schedule.actionFailed')));
    } finally {
      busyRef.current = false;
      setBusy(false);
    }
  };

  return (
    <>
    <Card style={{ backgroundColor: colors.surface, borderRadius: radius.sharp, marginBottom: spacing.md }}>
      <Card.Content style={{ gap: spacing.sm }}>
        <Text variant="titleMedium" style={{ fontWeight: '700' }}>{t('schedule.swapsTitle')}</Text>
        {swaps.length === 0 ? (
          <Text style={{ color: colors.muted }}>{t('schedule.noSwaps')}</Text>
        ) : (
          swaps.map((sw) => (
            <View key={sw._id} style={{ paddingVertical: 10, borderBottomWidth: 1, borderBottomColor: colors.border, gap: 6 }}>
              <Text>{sw.requesterName} → {sw.targetName}</Text>
              <Text style={{ color: colors.muted }}>{sw.requesterShift}{sw.targetShift ? ` ⇄ ${sw.targetShift}` : ` ${t('schedule.giveAway')}`} · {sw.status}</Text>
              <View style={{ flexDirection: 'row', gap: 8 }}>
                <Button compact mode="contained" buttonColor={colors.primary} disabled={busy} onPress={() => void safe(() => reviewSwap({ swapId: sw._id, approve: true }), t('schedule.swapApproved'))} accessibilityLabel={t('schedule.approveSwap')}>{t('schedule.approve')}</Button>
                <Button compact mode="outlined" textColor={colors.danger} disabled={busy} onPress={() => void safe(() => reviewSwap({ swapId: sw._id, approve: false }), t('schedule.swapDenied'))}>{t('schedule.deny')}</Button>
              </View>
            </View>
          ))
        )}
      </Card.Content>
    </Card>
    <Card style={{ backgroundColor: colors.surface, borderRadius: radius.sharp }}>
      <Card.Content style={{ gap: spacing.sm }}>
        <Text variant="titleMedium" style={{ fontWeight: '700' }}>{t('schedule.requestQueueTitle')}</Text>
        {queue.length === 0 ? (
          <Text style={{ color: colors.muted }}>{t('schedule.noPendingRequests')}</Text>
        ) : (
          queue.map((request) => (
            <View key={request._id} style={{ paddingVertical: 12, borderBottomWidth: 1, borderBottomColor: colors.border, gap: 8 }}>
              <Text style={{ fontWeight: '700' }}>{request.title}</Text>
              <Text style={{ color: colors.muted }}>{request.kind.replace('_', ' ')} · {request.status}</Text>
              <Text>{request.details}</Text>
              {correctionSummary(request, timeZone) ? (
                <Text style={{ fontWeight: '700', color: colors.charcoal }}>{correctionSummary(request, timeZone)}</Text>
              ) : null}
              {request.status === 'pending' ? (
                <View style={{ flexDirection: 'row', gap: 8, flexWrap: 'wrap' }}>
                  <Button compact mode="contained" buttonColor={colors.primary} disabled={busy} onPress={() => void safe(() => reviewRequest({ requestId: request._id as Id<'staffRequests'>, status: 'approved' }), t('schedule.requestApproved'))} accessibilityLabel={t('schedule.approveRequest')}>{t('schedule.approve')}</Button>
                  <Button compact mode="outlined" textColor={colors.danger} disabled={busy} onPress={() => void safe(() => reviewRequest({ requestId: request._id as Id<'staffRequests'>, status: 'denied' }), t('schedule.requestDenied'))}>{t('schedule.deny')}</Button>
                </View>
              ) : null}
            </View>
          ))
        )}
      </Card.Content>
    </Card>
    <Snackbar visible={Boolean(toast)} onDismiss={() => setToast(null)} duration={3000} action={{ label: t('schedule.dismiss'), onPress: () => setToast(null) }}>
      {toast ?? ''}
    </Snackbar>
    </>
  );
}

export default function ScheduleScreenWrapper() {
  return <ScreenErrorBoundary><ScheduleScreen /></ScreenErrorBoundary>;
}

function ScheduleScreen() {
  const { venue, canManage } = useVenueAuth();
  const { t } = useI18n();

  const [managerTab, setManagerTab] = useState<'calendar' | 'forecast' | 'requests' | 'blackouts'>('calendar');
  const contentContainerStyle = useDesktopContentStyle({ padding: spacing.lg, gap: spacing.md, paddingBottom: spacing.xxl });

  return (
    <ScrollView
      style={{ flex: 1, backgroundColor: colors.background }}
      contentContainerStyle={contentContainerStyle}
      showsVerticalScrollIndicator={false}
    >
      <SectionHeader
        kicker={t('schedule.kicker')}
        title={t('schedule.title')}
        subtitle={canManage ? t('schedule.subtitleManager') : t('schedule.subtitleStaff')}
      />

      {!venue?.id ? (
        <Card style={{ backgroundColor: colors.surface, borderRadius: radius.sharp }}>
          <Card.Content>
            <Text style={{ color: colors.muted }}>{t('schedule.noVenue')}</Text>
          </Card.Content>
        </Card>
      ) : canManage ? (
        <>
          <SegmentedButtons
            value={managerTab}
            onValueChange={(v) => setManagerTab(v as 'calendar' | 'forecast' | 'requests' | 'blackouts')}
            buttons={[
              { value: 'calendar', label: t('schedule.tabCalendar') },
              { value: 'forecast', label: t('schedule.tabForecast') },
              { value: 'requests', label: t('schedule.tabRequests') },
              { value: 'blackouts', label: t('schedule.tabBlackouts') },
            ]}
          />
          <AnimatedTab tabKey={managerTab}>
            {managerTab === 'calendar' ? (
              <ManagerCalendar venueId={venue.id} timeZone={venue.timezone ?? null} />
            ) : managerTab === 'forecast' ? (
              <LaborForecastPanel venueId={venue.id} />
            ) : managerTab === 'requests' ? (
              <RequestQueue venueId={venue.id} timeZone={venue.timezone ?? null} />
            ) : (
              <BlackoutManager venueId={venue.id} />
            )}
          </AnimatedTab>
        </>
      ) : <MyShifts />}
    </ScrollView>
  );
}

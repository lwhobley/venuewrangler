import { useMemo, useState } from 'react';
import { Pressable, ScrollView, StyleSheet, View } from 'react-native';
import { MaterialCommunityIcons } from '@expo/vector-icons';
import { router } from 'expo-router';
import { TextInput } from 'react-native-paper';
import { useMutation, useQuery, useQueryState } from '../../lib/railway-hooks';
import { api } from '../../lib/railway-api';
import type { Id } from '../../lib/ids';
import { ScreenErrorBoundary } from '../../components/ErrorBoundary';
import { CommandButton, CommandText } from '../../components/FutureUI';
import { HomeWranglerSurface } from '../../components/HomeWranglerSurface';
import { Skeleton } from '../../components/Skeleton';
import { useAuthStore } from '../../lib/auth-store';
import { usePushNotifications } from '../../lib/usePushNotifications';
import { useAuthenticatedSession } from '../../lib/auth-readiness';
import { spacing, useDesignTheme } from '../../lib/theme';
import { formatDuration, formatMoney } from '../../lib/format';
import { canManageVenue } from '../../lib/permissions';

type NotificationItem = {
  _id: Id<'notificationEvents'>;
  title: string;
  body: string;
  read: boolean;
};

const todayLabel = new Intl.DateTimeFormat('en-US', { weekday: 'short', month: 'short', day: 'numeric' });

// The API caps `limit` at 200; past that, notifications belong in a screen of
// their own rather than an ever-growing panel.
const NOTIFICATION_PAGE_SIZE = 20;
const NOTIFICATION_MAX = 200;

function HomeScreen() {
  usePushNotifications();
  const venue = useAuthStore((state) => state.venue);
  const venues = useAuthStore((state) => state.venues);
  const { isReady } = useAuthenticatedSession();
  const palette = useDesignTheme();
  const { data: dashboard, error: dashboardError, isLoading: dashboardLoading, refetch: refetchDashboard } = useQueryState(api.app.getDashboard, isReady ? {} : 'skip');
  // Only the newest few are shown, and older ones used to be unreachable
  // entirely — an unread notification past the newest 20 could not be read at
  // all. Both the fetch and the rendered slice grow together.
  const [notificationLimit, setNotificationLimit] = useState(NOTIFICATION_PAGE_SIZE);
  const notifications = useQuery(api.app.getNotifications, isReady ? { limit: notificationLimit } : 'skip');
  const markNotificationRead = useMutation(api.app.markNotificationRead);
  const upsertManagerGoal = useMutation(api.operations.upsertManagerGoal);
  const [showNotifications, setShowNotifications] = useState(false);
  const [goalTitle, setGoalTitle] = useState('');

  const venueName = dashboard?.venue.name ?? venue?.name ?? 'Venue Wrangler';
  const canManage = Boolean(dashboard && canManageVenue(dashboard.profile.role, dashboard.profile.allAccess));
  const managerDashboardQuery = useQueryState(api.operations.getManagerDashboard, isReady && canManage && venue?.id ? { venueId: venue.id } : 'skip');
  const dailyBriefQuery = useQueryState(api.operations.getDailyBrief, isReady && canManage && venue?.id ? { venueId: venue.id } : 'skip');
  const commandCenterQuery = useQueryState(api.operations.getCommandCenter, isReady && canManage && venue?.id ? { venueId: venue.id } : 'skip');
  const managerDashboard = managerDashboardQuery.data as any;
  const dailyBrief = dailyBriefQuery.data as any;
  const commandCenter = commandCenterQuery.data as any;
  // These three feed the readiness/flow/pulse cards below with fallbacks like
  // "Open checks: 0" and "No upcoming events" — indistinguishable from a
  // genuinely quiet day unless a fetch failure is called out separately.
  // Any one of the three failing is enough to make the cards below lie: they
  // fall back to "0" and "No upcoming events", which reads as a quiet venue.
  // The old condition required all three to be missing, so a single failed
  // fetch showed a confidently wrong readiness figure with no warning.
  const commandCenterLoadFailed =
    isReady && canManage && Boolean(venue?.id) &&
    ((!managerDashboardQuery.isLoading && managerDashboard === undefined && Boolean(managerDashboardQuery.error))
      || (!dailyBriefQuery.isLoading && dailyBrief === undefined && Boolean(dailyBriefQuery.error))
      || (!commandCenterQuery.isLoading && commandCenter === undefined && Boolean(commandCenterQuery.error)));
  const notificationsList = (notifications ?? []) as NotificationItem[];
  const unreadCount = notificationsList.filter((item) => !item.read).length;
  const readiness = commandCenter?.readiness;
  const pulse = dailyBrief?.profitabilityPulse;
  const events = commandCenter?.events?.slice(0, 4) ?? managerDashboard?.events?.slice(0, 4) ?? [];
  const loading = dashboardLoading || (isReady && dashboard === undefined);

  const currentDate = todayLabel.format(new Date());
  const readinessRows = useMemo(() => {
    const values = readiness?.categories ?? {};
    return [
      ['Staffing', values.staffing ?? values['staffing'] ?? 0],
      ['Setup', values.setup ?? values['setup'] ?? 0],
      ['Floor', values.floor ?? values['floor'] ?? 0],
      ['Approvals', values.approvals ?? values['approvals'] ?? 0],
    ] as const;
  }, [readiness?.categories]);

  const markAllRead = async () => {
    await Promise.all(notificationsList.filter((item) => !item.read).map((item) => markNotificationRead({ notificationId: item._id })));
  };

  const addGoal = async () => {
    if (!venue?.id || !goalTitle.trim()) return;
    const now = new Date();
    const date = `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, '0')}-${String(now.getDate()).padStart(2, '0')}`;
    await upsertManagerGoal({ venueId: venue.id, title: goalTitle.trim(), period: 'day', targetDate: date, status: 'open' });
    setGoalTitle('');
  };

  return (
    <ScrollView style={{ flex: 1, backgroundColor: palette.background }} contentContainerStyle={{ paddingBottom: spacing.xxl }} showsVerticalScrollIndicator={false}>
      <View style={{ backgroundColor: '#074426', paddingHorizontal: spacing.lg, paddingTop: spacing.xl, paddingBottom: spacing.lg, gap: spacing.md }}>
        <View style={{ flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', gap: spacing.md }}>
          <View style={{ flex: 1 }}>
            <Pressable
              accessibilityRole="button" onPress={() => router.push('/venue/settings')} style={({ pressed }) => ({ opacity: pressed ? 0.7 : 1, flexDirection: 'row', alignItems: 'center', gap: 4 })}>
              <CommandText palette={palette} variant="label" style={{ color: '#B6D6BE' }}>{venueName}</CommandText>
              {venues.length > 1 ? <MaterialCommunityIcons name="swap-horizontal" size={16} color="#B6D6BE" /> : null}
            </Pressable>
            <CommandText palette={palette} variant="hero" style={{ color: '#FFFFFF' }}>Operations command</CommandText>
          </View>
          <Pressable onPress={() => setShowNotifications((value) => !value)} accessibilityRole="button" accessibilityLabel="Open notifications" style={({ pressed }) => ({ opacity: pressed ? 0.65 : 1, padding: 8 })}>
            <View>
              <MaterialCommunityIcons name={unreadCount ? 'bell-ring-outline' : 'bell-outline'} size={24} color="#FFFFFF" />
              {unreadCount ? <View style={styles.notificationBadge}><CommandText palette={palette} variant="caption" style={{ color: '#FFFFFF' }}>{unreadCount}</CommandText></View> : null}
            </View>
          </Pressable>
        </View>
        <View style={{ flexDirection: 'row', alignItems: 'center', gap: spacing.md }}>
          <View style={{ flexDirection: 'row', alignItems: 'center', gap: 6 }}>
            <MaterialCommunityIcons name="calendar-blank-outline" size={16} color="#D9EBDD" />
            <CommandText palette={palette} variant="body" style={{ color: '#D9EBDD' }}>{currentDate}</CommandText>
          </View>
          <View style={{ width: StyleSheet.hairlineWidth, height: 20, backgroundColor: '#70A381' }} />
          <CommandText palette={palette} variant="body" style={{ color: '#D9EBDD' }}>
            {readiness?.status === 'blocked' ? 'Needs attention' : readiness?.status === 'at-risk' ? 'Watch service' : 'Service command ready'}
          </CommandText>
        </View>
      </View>

      <HomeWranglerSurface enabled={isReady && canManage && Boolean(venue?.id)} />

      <View style={{ paddingHorizontal: spacing.lg, paddingTop: spacing.xl, gap: spacing.xl }}>
        {dashboardError && !dashboard ? (
          <View style={{ padding: spacing.md, borderRadius: 8, backgroundColor: '#FDE7E9', borderWidth: 1, borderColor: '#F5A9AC', gap: spacing.xs }}>
            <CommandText palette={palette} variant="body" style={{ color: '#A81C24', fontWeight: '700' }}>Failed to load operations dashboard</CommandText>
            <CommandText palette={palette} variant="caption" style={{ color: '#A81C24' }}>{dashboardError instanceof Error ? dashboardError.message : 'Please check your connection.'}</CommandText>
            <CommandButton palette={palette} onPress={() => void refetchDashboard()} style={{ alignSelf: 'flex-start', marginTop: 4 }}>Retry</CommandButton>
          </View>
        ) : null}
        {commandCenterLoadFailed ? (
          <View style={{ padding: spacing.md, borderRadius: 8, backgroundColor: '#FDE7E9', borderWidth: 1, borderColor: '#F5A9AC', gap: spacing.xs }}>
            <CommandText palette={palette} variant="body" style={{ color: '#A81C24', fontWeight: '700' }}>Couldn't load today's readiness, flow, or pulse</CommandText>
            <CommandText palette={palette} variant="caption" style={{ color: '#A81C24' }}>The numbers below may be stale or blank. Check your connection.</CommandText>
            <CommandButton
              palette={palette}
              onPress={() => {
                void managerDashboardQuery.refetch();
                void dailyBriefQuery.refetch();
                void commandCenterQuery.refetch();
              }}
              style={{ alignSelf: 'flex-start', marginTop: 4 }}
            >
              Retry
            </CommandButton>
          </View>
        ) : null}
        {showNotifications ? (
          <View style={{ borderTopWidth: StyleSheet.hairlineWidth, borderBottomWidth: StyleSheet.hairlineWidth, borderColor: palette.divider, paddingVertical: spacing.md, gap: spacing.sm }}>
            <View style={{ flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between' }}>
              <CommandText palette={palette} variant="title">Notifications</CommandText>
              {unreadCount ? <CommandButton palette={palette} onPress={() => void markAllRead()}>Mark all read</CommandButton> : null}
            </View>
            {notificationsList.length ? notificationsList.map((item) => (
              <Pressable
                accessibilityRole="button" key={item._id} onPress={() => !item.read && void markNotificationRead({ notificationId: item._id })} style={{ paddingVertical: spacing.sm, borderTopWidth: StyleSheet.hairlineWidth, borderColor: palette.divider }}>
                <CommandText palette={palette} variant="body" style={{ fontWeight: item.read ? '500' : '800' }}>{item.title}</CommandText>
                <CommandText palette={palette} variant="caption">{item.body}</CommandText>
              </Pressable>
            )) : <CommandText palette={palette} variant="caption">You are all caught up.</CommandText>}
            {notificationsList.length >= notificationLimit && notificationLimit < NOTIFICATION_MAX ? (
              <CommandButton
                palette={palette}
                onPress={() => setNotificationLimit((limit) => Math.min(limit + NOTIFICATION_PAGE_SIZE, NOTIFICATION_MAX))}
              >
                Load more
              </CommandButton>
            ) : null}
          </View>
        ) : null}

        <View style={{ gap: spacing.md }}>
          <View style={{ flexDirection: 'row', alignItems: 'baseline', justifyContent: 'space-between' }}>
            <CommandText palette={palette} variant="title">Readiness snapshot</CommandText>
            <CommandText palette={palette} variant="body" style={{ color: readiness?.status === 'at-risk' ? palette.warning : palette.primary, fontWeight: '700' }}>
              {readiness ? `${readiness.score}% ready` : 'Loading'}
            </CommandText>
          </View>
          <View style={{ borderTopWidth: StyleSheet.hairlineWidth, borderColor: palette.divider }}>
            <View style={{ flexDirection: 'row', paddingVertical: spacing.xs, borderBottomWidth: StyleSheet.hairlineWidth, borderColor: palette.divider }}>
              <CommandText palette={palette} variant="label" style={{ flex: 1 }}>Area</CommandText>
              <CommandText palette={palette} variant="label" style={{ width: 88 }}>Status</CommandText>
              <CommandText palette={palette} variant="label" style={{ width: 80, textAlign: 'right' }}>Owner</CommandText>
            </View>
            {readinessRows.map(([label, value]) => {
              const state = value >= 100 ? 'Clear' : value > 0 ? `${value}% watch` : 'Pending';
              const color = value >= 100 ? palette.success : value > 0 ? palette.warning : palette.muted;
              return (
                <Pressable
                  accessibilityRole="button" key={label} onPress={() => router.push(label === 'Staffing' ? '/staff' : label === 'Floor' ? '/floor' : '/checklist')} style={({ pressed }) => ({ opacity: pressed ? 0.65 : 1, flexDirection: 'row', alignItems: 'center', paddingVertical: spacing.md, borderBottomWidth: StyleSheet.hairlineWidth, borderColor: palette.divider })}>
                  <CommandText palette={palette} variant="body" style={{ flex: 1 }}>{label}</CommandText>
                  <View style={{ width: 88, flexDirection: 'row', alignItems: 'center', gap: 6 }}><View style={{ width: 7, height: 7, borderRadius: 4, backgroundColor: color }} /><CommandText palette={palette} variant="caption" style={{ color, fontWeight: '700' }}>{state}</CommandText></View>
                  <CommandText palette={palette} variant="caption" style={{ width: 80, textAlign: 'right' }}>{label === 'Staffing' ? 'Manager' : 'Team'}</CommandText>
                </Pressable>
              );
            })}
          </View>
        </View>

        <View style={{ gap: spacing.md }}>
          <View style={{ flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between' }}>
            <CommandText palette={palette} variant="title">Today’s flow</CommandText>
            <CommandText palette={palette} variant="caption">Team on-site {dashboard?.analytics.clockedInCount ?? 0}</CommandText>
          </View>
          <View style={{ borderLeftWidth: 1, borderColor: palette.divider, marginLeft: 10, gap: 0 }}>
            {(events.length ? events : managerDashboard?.goals?.slice(0, 3) ?? []).map((item: any, index: number) => (
              <Pressable
                accessibilityRole="button" key={item._id ?? `${item.title}-${index}`} onPress={() => item._id && 'startsAt' in item ? router.push({ pathname: '/event-command-center', params: { eventId: item._id } }) : router.push('/schedule')} style={({ pressed }) => ({ opacity: pressed ? 0.65 : 1, marginLeft: -6, paddingLeft: spacing.lg, paddingBottom: spacing.lg, position: 'relative' })}>
                <View style={{ position: 'absolute', top: 4, left: -5, width: 9, height: 9, borderRadius: 5, backgroundColor: index === 0 ? palette.primary : '#A9B0AA' }} />
                <CommandText palette={palette} variant="caption">{'startsAt' in item ? new Intl.DateTimeFormat('en-US', { hour: 'numeric', minute: '2-digit' }).format(new Date(item.startsAt)) : item.targetDate ?? 'Today'}</CommandText>
                <CommandText palette={palette} variant="body" style={{ fontWeight: '700', marginTop: 2 }}>{item.title}</CommandText>
                <CommandText palette={palette} variant="caption">{'expectedGuests' in item ? `${item.expectedGuests ?? '—'} guests · ${item.readiness}` : item.status ?? 'Open goal'}</CommandText>
              </Pressable>
            ))}
            {!events.length && !(managerDashboard?.goals?.length) ? <CommandText palette={palette} variant="caption" style={{ paddingLeft: spacing.lg }}>No upcoming events or goals yet.</CommandText> : null}
          </View>
        </View>

        <View style={{ borderTopWidth: StyleSheet.hairlineWidth, borderBottomWidth: StyleSheet.hairlineWidth, borderColor: palette.divider, flexDirection: 'row', paddingVertical: spacing.md }}>
          {[
            ['Sales', pulse ? formatMoney(pulse.salesCents) : '$0.00'],
            ['Labor', pulse ? formatDuration(Math.round(pulse.laborHours * 60)) : '—'],
            ['Open checks', String(pulse?.openChecks ?? dailyBrief?.prepOpenCount ?? 0)],
            ['Active clocks', String(pulse?.activeClocks ?? dashboard?.analytics.clockedInCount ?? 0)],
          ].map(([label, value], index) => (
            <View key={label} style={{ flex: 1, paddingHorizontal: spacing.sm, gap: 3, borderLeftWidth: index ? StyleSheet.hairlineWidth : 0, borderColor: palette.divider }}>
              <CommandText palette={palette} variant="body" style={{ fontWeight: '800' }}>{value}</CommandText>
              <CommandText palette={palette} variant="caption">{label}</CommandText>
            </View>
          ))}
        </View>

        {canManage ? <View style={{ gap: spacing.sm, paddingBottom: spacing.md }}>
          <CommandText palette={palette} variant="title">Manager goal</CommandText>
          <TextInput value={goalTitle} onChangeText={setGoalTitle} placeholder="Add a goal for today" mode="outlined" dense outlineColor={palette.border} activeOutlineColor={palette.primary} textColor={palette.charcoal} style={{ backgroundColor: palette.surface }} />
          <CommandButton palette={palette} icon="plus" selected={Boolean(goalTitle.trim())} onPress={() => void addGoal()} style={{ alignSelf: 'flex-start' }}>Add goal</CommandButton>
        </View> : null}

        {loading ? <Skeleton height={60} /> : null}
      </View>
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  notificationBadge: {
    position: 'absolute',
    right: -8,
    top: -7,
    minWidth: 17,
    height: 17,
    borderRadius: 9,
    alignItems: 'center',
    justifyContent: 'center',
    backgroundColor: '#B8711B',
  },
});

export default function HomeScreenWrapper() {
  return <ScreenErrorBoundary><HomeScreen /></ScreenErrorBoundary>;
}
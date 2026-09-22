import { StyleSheet, View } from 'react-native';
import { ActivityIndicator } from 'react-native-paper';
import { ScreenErrorBoundary } from '../../components/ErrorBoundary';
import FullVenueHome from '../../components/FullVenueHome';
import { EmptyState, ListRow, Metric, PageHeader, ScreenShell, Section, StatusBadge } from '../../components/design-system';
import { QueryBoundary } from '../../components/QueryBoundary';
import { useAuthenticatedSession } from '../../lib/auth-readiness';
import { useAuthStore } from '../../lib/auth-store';
import { canManageVenue } from '../../lib/permissions';
import { useQueryState } from '../../lib/railway-hooks';
import { api } from '../../lib/railway-api';
import { colors, spacing } from '../../lib/theme';
import { config } from '../../lib/config';
import { usePushNotifications } from '../../lib/usePushNotifications';

type Dashboard = { profile: { role: string; allAccess: boolean } };
type Shift = { id: string; staffName: string | null; jobTitle: string; station: string; startMinutes: number; endMinutes: number; status: string };
type ManagerDashboard = { date: string; scheduledCount: number; clockedInCount: number; pendingRequestCount: number; shifts: Shift[] };
type ClockBoard = { managerAlerts: { detail: string }[] };

function TonightScreen() {
  usePushNotifications();
  const { isReady } = useAuthenticatedSession();
  const venue = useAuthStore((state) => state.venue);
  const dashboard = useQueryState<Dashboard>(api.app.getDashboard, isReady ? {} : 'skip');
  const canManage = Boolean(dashboard.data?.profile && canManageVenue(dashboard.data.profile.role, dashboard.data.profile.allAccess));
  const manager = useQueryState<ManagerDashboard>(api.operations.getDailyBrief, isReady && canManage ? {} : 'skip');
  const board = useQueryState<ClockBoard>(api.app.getClockBoard, isReady && canManage ? {} : 'skip');
  if (!isReady) return <View style={styles.center}><ActivityIndicator color={colors.primary} /></View>;
  return <ScreenShell>
    <QueryBoundary state={dashboard}>{() => <>
    <PageHeader kicker={venue?.name ?? 'Your restaurant'} title={canManage ? 'Tonight' : 'My schedule'} />
    {canManage ? <>
      <QueryBoundary state={manager} feature="Tonight’s team">{(data) => <>
        <View style={styles.metrics}>
          <Metric label="Scheduled" value={String(data.scheduledCount)} />
          <Metric label="Clocked in" value={String(data.clockedInCount)} />
          <Metric label="Needs action" value={String(data.pendingRequestCount)} />
        </View>
        <Section title="Who is on tonight" action={<StatusBadge label={data.date} />}>
          {!Array.isArray(data.shifts) ? <EmptyState title="Team details are unavailable" detail="Open Schedule to view assigned shifts." /> : data.shifts.length ? data.shifts.slice(0, 12).map((shift) => <ListRow key={shift.id} title={shift.staffName ?? 'Open shift'} detail={`${shift.jobTitle || shift.station || 'Team'} · ${formatMinutes(shift.startMinutes)}–${formatMinutes(shift.endMinutes)}`} trailing={<StatusBadge label={shift.status === 'open' ? 'Needs assignment' : 'Scheduled'} tone={shift.status === 'open' ? 'watch' : 'ok'} />} />) : <EmptyState title="No shifts scheduled tonight." detail="Add coverage in Schedule before service." />}
        </Section>
      </>}</QueryBoundary>
      <Section title="Needs attention">
        <QueryBoundary state={board}>{(data) => data.managerAlerts.length ? data.managerAlerts.slice(0, 4).map((alert, index) => <ListRow key={index} title={alert.detail} />) : <EmptyState title="No late or missed punches" detail="The clock board is clear." />}</QueryBoundary>
      </Section>
    </> : <Section title="Your shifts"><EmptyState title="Open Schedule" detail="Assigned shifts, requests, and swaps live there." /></Section>}
    </>}</QueryBoundary>
  </ScreenShell>;
}
function formatMinutes(value?: number) { if (value == null) return '—'; const h = Math.floor(value / 60) % 24; const m = value % 60; return `${h % 12 || 12}:${String(m).padStart(2, '0')} ${h >= 12 ? 'PM' : 'AM'}`; }
export default function HomeScreen() { return config.restaurantCoreOnly ? <ScreenErrorBoundary><TonightScreen /></ScreenErrorBoundary> : <FullVenueHome />; }
const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  content: { padding: spacing.lg, gap: spacing.md, paddingBottom: spacing.xxl },
  title: { color: colors.charcoal, fontFamily: 'Fraunces_600SemiBold', fontSize: 34, lineHeight: 40 },
  subtitle: { color: colors.muted, fontSize: 12, fontWeight: '600', letterSpacing: 0.6 },
  metrics: { flexDirection: 'row', borderTopWidth: 1, borderBottomWidth: 1, borderColor: colors.border, paddingVertical: spacing.md },
  metric: { flex: 1, paddingHorizontal: spacing.sm },
  metricValue: { color: colors.charcoal, fontWeight: '700', fontVariant: ['tabular-nums'] },
  muted: { color: colors.muted, marginTop: 4, fontSize: 12 },
  card: { backgroundColor: colors.surface, borderRadius: 12, borderWidth: StyleSheet.hairlineWidth, borderColor: colors.border, elevation: 0, shadowOpacity: 0 },
  row: { paddingVertical: spacing.md, gap: 4, borderBottomWidth: StyleSheet.hairlineWidth, borderBottomColor: colors.border },
  name: { fontWeight: '700', fontSize: 15 },
  center: { flex: 1, alignItems: 'center', justifyContent: 'center' },
});

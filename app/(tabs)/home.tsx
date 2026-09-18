import { ScrollView, StyleSheet, View } from 'react-native';
import { ActivityIndicator, Card, Text } from 'react-native-paper';
import { ScreenErrorBoundary } from '../../components/ErrorBoundary';
import FullVenueHome from '../../components/FullVenueHome';
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
  return <ScrollView style={styles.screen} contentContainerStyle={styles.content}>
    <QueryBoundary state={dashboard}>{() => <>
    <View style={styles.hero}>
    <Text variant="headlineMedium" style={styles.title}>{canManage ? 'Tonight' : 'My schedule'}</Text>
    <Text style={styles.heroSubtitle}>{venue?.name ?? 'Your restaurant'}</Text>
    </View>
    {canManage ? <>
      <QueryBoundary state={manager} feature="Tonight’s team">{(data) => <>
        <Text style={styles.subtitle}>{data.date}</Text>
        <View style={styles.metrics}><Metric label="Scheduled" value={String(data.scheduledCount)} /><Metric label="Clocked in" value={String(data.clockedInCount)} /><Metric label="Pending requests" value={String(data.pendingRequestCount)} /></View>
        <Card style={styles.card}><Card.Title title="Tonight’s team" subtitle="Scheduled people and live punches" /><Card.Content>{!Array.isArray(data.shifts) ? <Text>Team details are unavailable. Open Schedule to view assigned shifts.</Text> : data.shifts.length ? data.shifts.slice(0, 12).map((shift) => <View style={styles.row} key={shift.id}><Text style={styles.name}>{shift.staffName ?? 'Open shift'}</Text><Text>{shift.jobTitle || shift.station || 'Team'} · {formatMinutes(shift.startMinutes)}–{formatMinutes(shift.endMinutes)}</Text></View>) : <Text>No shifts scheduled tonight.</Text>}</Card.Content></Card>
      </>}</QueryBoundary>
      <Card style={styles.card}><Card.Title title="Live clock board" /><Card.Content><QueryBoundary state={board}>{(data) => <Text style={styles.muted}>{data.managerAlerts.length} late or missed punch alerts</Text>}</QueryBoundary></Card.Content></Card>
    </> : <Card style={styles.card}><Card.Title title="Your shifts" /><Card.Content><Text>Open Schedule to see your assigned shifts, requests, and swaps.</Text></Card.Content></Card>}
    </>}</QueryBoundary>
  </ScrollView>;
}
function Metric({ label, value }: { label: string; value: string }) { return <View style={styles.metric}><Text variant="headlineSmall" style={styles.metricValue}>{value}</Text><Text style={styles.muted}>{label}</Text></View>; }
function formatMinutes(value?: number) { if (value == null) return '—'; const h = Math.floor(value / 60) % 24; const m = value % 60; return `${h % 12 || 12}:${String(m).padStart(2, '0')} ${h >= 12 ? 'PM' : 'AM'}`; }
export default function HomeScreen() { return config.restaurantCoreOnly ? <ScreenErrorBoundary><TonightScreen /></ScreenErrorBoundary> : <FullVenueHome />; }
const styles = StyleSheet.create({ screen: { flex: 1, backgroundColor: colors.background }, content: { padding: spacing.lg, gap: spacing.md, paddingBottom: spacing.xxl }, hero: { backgroundColor: colors.primary, borderRadius: 28, padding: 28, gap: 8, shadowColor: colors.shadow, shadowOpacity: 0.16, shadowRadius: 18, shadowOffset: { width: 0, height: 8 }, elevation: 4 }, title: { color: colors.buttonText, fontSize: 40, lineHeight: 46, letterSpacing: -1.2, fontWeight: '800' }, heroSubtitle: { color: '#D3F6B0', fontSize: 16, fontWeight: '600' }, subtitle: { color: colors.muted }, metrics: { flexDirection: 'row', gap: spacing.sm }, metric: { flex: 1, backgroundColor: colors.surface, padding: spacing.lg, borderRadius: 20, borderWidth: 1, borderColor: colors.border }, metricValue: { color: colors.primary, fontWeight: '700' }, muted: { color: colors.muted, marginTop: 4 }, card: { backgroundColor: colors.surface, borderRadius: 24, paddingVertical: 8 }, row: { paddingVertical: spacing.sm, borderBottomWidth: StyleSheet.hairlineWidth, borderBottomColor: colors.border }, name: { fontWeight: '700' }, center: { flex: 1, alignItems: 'center', justifyContent: 'center' } });

import { ScrollView, View } from 'react-native';
import { Button, Chip, Text } from 'react-native-paper';
import { useRouter } from 'expo-router';
import { useQuery } from '../lib/railway-hooks';
import { api } from '../lib/railway-api';
import { colors, spacing } from '../lib/theme';
import { AppCard, SectionHeader } from '../components/AppCard';
import { PageHeader } from '../components/design-system';
import { ScreenErrorBoundary } from '../components/ErrorBoundary';
import { useAuthStore, type AuthState } from '../lib/auth-store';
import { useI18n } from '../lib/i18n';

function HostStandScreen() {
  const router = useRouter();
  const { t } = useI18n();
  const venue = useAuthStore((state: AuthState) => state.venue);
  const floor = useQuery(api.floor.getActiveFloorPlan, venue?.id ? { venueId: venue.id } : 'skip');
  const stats = useQuery(api.floor.getFloorStats, venue?.id ? { venueId: venue.id } : 'skip');

  return (
    <ScrollView contentContainerStyle={{ flexGrow: 1, backgroundColor: colors.background, padding: spacing.lg, gap: spacing.md }}>
      <PageHeader title={t('host.title')} detail={t('host.subtitle')} />

      <AppCard>
          <View style={{ flexDirection: 'row', justifyContent: 'space-between', flexWrap: 'wrap', gap: 12 }}>
          <Chip>{t('host.occupied', { count: stats?.occupiedCount ?? 0 })}</Chip>
          <Chip>{t('host.waitlist', { count: stats?.waitlistSize ?? 0 })}</Chip>
          <Chip>{t('host.dirty', { count: stats?.dirtyCount ?? 0 })}</Chip>
          <Chip>{t('host.available', { count: stats?.availableCount ?? 0 })}</Chip>
          </View>
      </AppCard>

      {floor ? (
        <AppCard>
            <SectionHeader title={t('host.quickSeatMap')} />
            {((floor.tables ?? []) as any[]).slice(0, 10).map(({ table, state }: { table: any; state: any }) => (
              <View key={table._id} style={{ paddingVertical: 10, borderBottomWidth: 1, borderBottomColor: colors.border }}>
                <View style={{ flexDirection: 'row', justifyContent: 'space-between' }}>
                  <Text style={{ fontWeight: '700' }}>{table.label}</Text>
                  <Chip compact>{state?.status ?? t('host.statusAvailable')}</Chip>
                </View>
                <Text style={{ color: colors.muted }}>{t('host.tableSummary', { section: table.section, seats: table.seats, party: state?.partySize ?? 0 })}</Text>
              </View>
            ))}
        </AppCard>
      ) : null}

      <Button mode="contained" onPress={() => router.back()}>
        {t('host.backToFloor')}
      </Button>
    </ScrollView>
  );
}

export default function HostStandScreenWrapper() {
  return <ScreenErrorBoundary withNavRail={false}><HostStandScreen /></ScreenErrorBoundary>;
}

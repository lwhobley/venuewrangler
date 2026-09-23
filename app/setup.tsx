import { useState } from 'react';
import { ScrollView, View } from 'react-native';
import { Button, Card, Text } from 'react-native-paper';
import { router } from 'expo-router';
import { api } from '../lib/railway-api';
import { useQueryState } from '../lib/railway-hooks';
import { useVenueAuth } from '../lib/useVenueAuth';
import { colors, radius, spacing } from '../lib/theme';
import { ManagerGate } from '../components/ManagerGate';
import { PageHeader } from '../components/design-system';

type Connection = { provider: string; status: string; lastSyncAt?: number | null };
type Staff = { _id: string; role: string };
type Item = { _id: string };

function SetupScreen() {
  const [showMoreSteps, setShowMoreSteps] = useState(false);
  const { venue, isReady, canManage, profileLoading, profileError, refetchProfile } = useVenueAuth();
  const staffState = useQueryState<Staff[]>(api.app.listVenueStaff, isReady && canManage ? {} : 'skip');
  const stockState = useQueryState<{ items: Item[] }>(api.barInventory.getBarStock, isReady && venue?.id ? { venueId: venue.id } : 'skip');
  const posState = useQueryState<{ connections: Connection[]; lastSyncAt: number | null; recentChecks: unknown[] }>(api.pos.getPosOverview, isReady && canManage ? { venueId: venue?.id } : 'skip');
  const reservationsState = useQueryState<{ connections: Connection[]; recentEvents: unknown[]; processedProviders: string[] }>(api.reservationIntegrations.getReservationIntegrationOverview, isReady && canManage ? { venueId: venue?.id } : 'skip');
  const menuItemsState = useQueryState<Array<{ name: string; quantity: number }>>(api.pos.getTopMenuItems, isReady && canManage ? { windowDays: 30, limit: 50 } : 'skip');
  const recipesState = useQueryState<Array<{ _id: string }>>(api.barInventory.listRecipes, isReady && canManage ? {} : 'skip');
  const states = [staffState, stockState, posState, reservationsState, menuItemsState, recipesState];
  const staff = staffState.data;
  const stock = stockState.data;
  const pos = posState.data;
  const reservations = reservationsState.data;
  const menuItems = menuItemsState.data;
  const recipes = recipesState.data;

  const posConnected = Boolean(pos?.connections?.some((connection) => connection.status === 'connected'));
  const reservationsConnected = Boolean(reservations?.connections?.some((connection) => connection.status === 'connected'));
  const reservationsReceiving = Boolean(reservations?.connections?.some((connection) =>
    connection.status === 'connected' && reservations.processedProviders?.includes(connection.provider),
  ));
  const tasks = [
    { title: 'Bring in your team', detail: `${Math.max(0, (staff?.length ?? 1) - 1)} staff profiles beyond your manager account. Import a CSV and review names before adding them.`, complete: (staff?.length ?? 0) > 1, action: 'Open team import', route: '/(tabs)/staff' },
    { title: 'Load your inventory', detail: `${stock?.items?.length ?? 0} stock items. Import a CSV or start with a focused list; counts can be corrected later.`, complete: (stock?.items?.length ?? 0) > 0, action: 'Open inventory', route: '/(tabs)/bar-stock' },
    { title: 'Connect a POS feed', detail: posConnected ? `${pos?.recentChecks?.length ?? 0} recent checks are visible. Last received: ${relativeAge(pos?.lastSyncAt ?? null)}.` : 'Create a webhook connection to receive sales data while your current POS remains in place.', complete: posConnected && (pos?.recentChecks?.length ?? 0) > 0, action: 'Configure POS feed', route: '/(tabs)/integrations' },
    { title: 'Review your POS menu', detail: `${menuItems?.length ?? 0} menu items seen in recent POS sales; ${recipes?.length ?? 0} recipes mapped. Map a menu item to a recipe to deplete ingredients on future sales.`, complete: (recipes?.length ?? 0) > 0, action: 'Map recipes', route: '/inventory-recipes' },
    { title: 'Bring in reservations', detail: reservationsReceiving ? 'Reservation updates have arrived. Review them before relying on this feed.' : reservationsConnected ? 'Connection saved. Waiting for its first reservation update; check the provider setup in Integrations.' : 'Connect a reservation webhook, or start by managing bookings in Venue Wrangler alongside your current reservation system.', complete: reservationsReceiving, action: reservationsReceiving ? 'Review bookings' : 'Configure reservation feed', route: reservationsReceiving ? '/(tabs)/reservations' : '/(tabs)/integrations' },
  ];
  const completed = tasks.filter((task) => task.complete).length;
  const nextTask = tasks.find((task) => !task.complete);
  const otherTasks = tasks.filter((task) => task !== nextTask);
  const remainingCount = otherTasks.filter((task) => !task.complete).length;

  return <ManagerGate canManage={canManage} profileLoading={profileLoading} profileError={profileError} onRetry={refetchProfile} feature="Venue setup">
    <ScrollView style={{ flex: 1, backgroundColor: colors.background }} contentContainerStyle={{ padding: spacing.lg, gap: spacing.md, paddingBottom: spacing.xxl }}>
      <PageHeader kicker={venue?.name ?? 'Venue'} title="Get started" detail={`${completed} of ${tasks.length} steps ready · you can finish setup later`} />
      {states.some((state) => state.error) && <Card><Card.Content><Text>Some setup progress could not load. Check your connection and try again.</Text><Button onPress={() => states.forEach((state) => { void state.refetch(); })}>Retry</Button></Card.Content></Card>}
      {states.some((state) => state.isLoading) && <Text>Loading setup progress…</Text>}
      {states.some((state) => state.subscriptionRequired) && <Text>An active subscription is required to view all setup steps.</Text>}
      <Card style={{ backgroundColor: colors.surface, borderRadius: radius.sharp }}><Card.Content style={{ gap: spacing.xs }}>
        <Text variant="titleMedium" style={{ fontWeight: '800' }}>Start with one useful step</Text>
        <Text style={{ color: colors.muted }}>Keep your current POS and reservation tools running. Set up only what you need today; you can connect systems and import more data later.</Text>
      </Card.Content></Card>
      {nextTask ? <Card style={{ backgroundColor: colors.surface, borderRadius: radius.sharp, borderWidth: 1, borderColor: colors.primary }}><Card.Content style={{ gap: spacing.sm }}>
        <Text style={{ color: colors.primary, fontWeight: '800' }}>YOUR NEXT STEP</Text>
        <Text variant="titleLarge" style={{ fontWeight: '800' }}>{nextTask.title}</Text>
        <Text style={{ color: colors.muted }}>{nextTask.detail}</Text>
        <Button mode="contained" buttonColor={colors.primary} onPress={() => router.push(nextTask.route as never)}>{nextTask.action}</Button>
      </Card.Content></Card> : <Card style={{ backgroundColor: colors.surface, borderRadius: radius.sharp }}><Card.Content style={{ gap: spacing.xs }}>
        <Text variant="titleMedium" style={{ color: colors.success, fontWeight: '800' }}>You’re ready to go</Text>
        <Text style={{ color: colors.muted }}>The main setup steps are complete. You can revisit imports and integrations whenever you need them.</Text>
      </Card.Content></Card>}

      {otherTasks.length > 0 ? <Card style={{ backgroundColor: colors.surface, borderRadius: radius.sharp }}><Card.Content style={{ gap: spacing.sm }}>
        <Button mode="text" textColor={colors.primary} icon={showMoreSteps ? 'chevron-up' : 'chevron-down'} onPress={() => setShowMoreSteps((value) => !value)}>
          {showMoreSteps ? 'Hide other steps' : remainingCount > 0 ? `More setup steps (${remainingCount} optional)` : 'Review completed steps'}
        </Button>
        {showMoreSteps ? otherTasks.map((task) => <View key={task.title} style={{ gap: spacing.xs, borderTopWidth: 1, borderTopColor: colors.border, paddingTop: spacing.sm }}>
          <Text variant="titleMedium" style={{ fontWeight: '700' }}>{task.title} · {task.complete ? 'Ready' : 'Optional'}</Text>
          <Text style={{ color: colors.muted }}>{task.detail}</Text>
          <Button mode="outlined" onPress={() => router.push(task.route as never)}>{task.action}</Button>
        </View>) : null}
      </Card.Content></Card> : null}

      <Button mode="text" textColor={colors.muted} onPress={() => router.replace('/(tabs)/home')}>Not now · go to my venue</Button>

      <Card style={{ backgroundColor: colors.surface, borderRadius: radius.sharp }}><Card.Content style={{ gap: spacing.sm }}>
        <Text variant="titleMedium" style={{ fontWeight: '800' }}>Your data stays portable</Text>
        <Text style={{ color: colors.muted }}>Export reservation, time, payroll, and inventory CSVs from Reports and Bar Stock. Use them for reconciliation or to keep copies with your existing systems.</Text>
        <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: spacing.sm }}>
          <Button mode="outlined" onPress={() => router.push('/(tabs)/reports')}>Reports & exports</Button>
          <Button mode="outlined" onPress={() => router.push('/(tabs)/bar-stock')}>Inventory exports</Button>
        </View>
      </Card.Content></Card>
    </ScrollView>
  </ManagerGate>;
}

function relativeAge(timestamp: number | null) {
  if (!timestamp) return 'no data received yet';
  const minutes = Math.max(0, Math.floor((Date.now() - timestamp) / 60_000));
  if (minutes < 1) return 'just now';
  if (minutes < 60) return `${minutes} min ago`;
  const hours = Math.floor(minutes / 60);
  return hours < 24 ? `${hours} hr ago` : `${Math.floor(hours / 24)} days ago`;
}

export default function SetupRoute() { return <SetupScreen />; }

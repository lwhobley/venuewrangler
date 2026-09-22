import { Redirect, Tabs } from 'expo-router';
import { MaterialCommunityIcons } from '@expo/vector-icons';
import type { ColorValue } from 'react-native';
import { useQueryState } from '../../lib/railway-hooks';
import { api } from '../../lib/railway-api';
import { useDesignTheme } from '../../lib/theme';
import { useAuthStore, type AuthState } from '../../lib/auth-store';
import { CarouselTabBar } from '../../components/CarouselTabBar';
import { useI18n } from '../../lib/i18n';
import { canManageVenue } from '../../lib/permissions';
import { useAuthenticatedSession } from '../../lib/auth-readiness';
import { config } from '../../lib/config';

const icon = (name: keyof typeof MaterialCommunityIcons.glyphMap) =>
  ({ color, size }: { color: ColorValue; size: number }) => <MaterialCommunityIcons name={name} size={size} color={String(color)} />;

export default function TabsLayout() {
  const localUser = useAuthStore((state: AuthState) => state.user);
  const venue = useAuthStore((state: AuthState) => state.venue);
  const hydrated = useAuthStore((state: AuthState) => state.hydrated);
  const { t } = useI18n();
  const palette = useDesignTheme();
  // Server-authoritative role so a stale/incorrect persisted role can never
  // expose manager-only tabs. While loading, hide gated tabs.
  const { isReady } = useAuthenticatedSession();
  const { data: me } = useQueryState(api.app.getMe, isReady ? {} : 'skip');
  const canManage = Boolean(me && canManageVenue(me.profile.role, me.profile.allAccess));

  // Render-gate the whole tab tree: an unauthenticated deep link must not
  // mount tab screens at all (even one render) before auth redirects fire.
  // <Redirect> is render-safe (no navigate-before-mount), unlike an
  // imperative router.replace here.
  if (hydrated && !localUser) {
    return <Redirect href="/(auth)/welcome" />;
  }

  if (hydrated && localUser && !localUser.email_verified) {
    return <Redirect href="/(auth)/verify-email" />;
  }

  // Enforce venue membership: a signed-in user without a venue can't use the
  // app and is sent to choose or join a team.
  if (hydrated && localUser && !venue) {
    return <Redirect href="/(auth)/team-choice" />;
  }

  return (
    <Tabs
      tabBar={(props) => <CarouselTabBar {...props} />}
      screenOptions={{
        headerShown: false,
        tabBarActiveTintColor: String(palette.primary),
        tabBarInactiveTintColor: String(palette.muted),
      }}
    >
      <Tabs.Screen name="home" options={{ title: canManage ? 'Tonight' : t('nav.home'), tabBarIcon: icon('view-dashboard') }} />
      <Tabs.Screen name="clock" options={{ title: t('nav.clock'), tabBarIcon: icon('clock-outline') }} />
      <Tabs.Screen name="schedule" options={{ title: t('nav.schedule'), tabBarIcon: icon('calendar-week') }} />
      <Tabs.Screen name="staff" options={{ title: 'Team', href: canManage ? '/staff' : null, tabBarIcon: icon('account-group') }} />
      <Tabs.Screen name="chat" options={{ title: 'Inbox', tabBarIcon: icon('bullhorn-outline') }} />
      <Tabs.Screen name="profile" options={{ title: 'Settings', tabBarIcon: icon('cog-outline') }} />
      <Tabs.Screen name="floor" options={{ title: t('nav.floor'), tabBarIcon: icon('floor-plan') }} />
      <Tabs.Screen name="reservations" options={{ title: t('nav.reservations'), tabBarIcon: icon('book-clock-outline') }} />
      <Tabs.Screen
        name="guests"
        options={{ title: 'CRM', href: canManage ? '/guests' : null, tabBarIcon: icon('account-heart-outline') }}
      />
      <Tabs.Screen
        name="integrations"
        options={{ title: t('nav.integrations'), href: canManage && !config.restaurantCoreOnly ? '/integrations' : null, tabBarIcon: icon('connection') }}
      />
      <Tabs.Screen
        name="sales"
        options={{ title: t('nav.sales'), href: canManage && !config.restaurantCoreOnly ? '/sales' : null, tabBarIcon: icon('chart-line') }}
      />
      <Tabs.Screen
        name="bar-stock"
        options={{ title: t('nav.inventory'), href: config.restaurantCoreOnly ? null : '/bar-stock', tabBarIcon: icon('clipboard-text-outline') }}
      />
      <Tabs.Screen
        name="documents"
        options={{ title: t('nav.documents'), href: config.restaurantCoreOnly ? null : '/documents', tabBarIcon: icon('file-document-multiple-outline') }}
      />
      <Tabs.Screen
        name="reports"
        options={{ title: t('nav.reports'), href: canManage && !config.restaurantCoreOnly ? '/reports' : null, tabBarIcon: icon('chart-box-outline') }}
      />
    </Tabs>
  );
}

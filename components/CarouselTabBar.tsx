import { useState, type ComponentProps } from 'react';
import type { Tabs } from 'expo-router';
import { Pressable, ScrollView, StyleSheet, Text, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { useDesignTheme } from '../lib/theme';
import { useI18n } from '../lib/i18n';
import { DESKTOP_NAV_WIDTH, useIsDesktop } from '../lib/responsive';

type ExpoTabBarProps = Parameters<NonNullable<ComponentProps<typeof Tabs>['tabBar']>>[0];
type TabRoute = ExpoTabBarProps['state']['routes'][number];

// The tab navigator still owns every route so deep links and contextual
// navigation keep working. On phones, however, only the four jobs people use
// during a shift belong in persistent navigation. Administrative and
// specialist tools remain available from the role-filtered More drawer.
const MANAGER_MOBILE_ROUTES = new Set(['home', 'schedule', 'staff', 'chat']);
const STAFF_MOBILE_ROUTES = new Set(['home', 'clock', 'schedule', 'chat']);

const DESKTOP_GROUPS: Array<{ label: string; routes: string[] }> = [
  { label: 'Operations', routes: ['home', 'clock', 'schedule', 'staff', 'chat', 'floor', 'bar-stock'] },
  { label: 'Guests', routes: ['reservations', 'guests'] },
  { label: 'Revenue', routes: ['sales', 'reports', 'integrations'] },
  { label: 'Administration', routes: ['documents', 'profile'] },
];

// Editorial tab bar: no filled pill indicator — the active tab is marked by
// a hairline underline and the accent color, like a masthead nav rather than
// a row of chips. Separated from content by a single top rule, not a shadow.
//
// At desktop-web widths the same items render as a persistent left rail
// instead. A fourteen-item horizontally-scrolling strip pinned to the bottom
// of a 1680px window is a phone affordance: the labels are unreadable at that
// distance and reaching the later tabs means scrolling a nav bar, which no
// desktop user expects.
export function CarouselTabBar({ state, descriptors, navigation }: ExpoTabBarProps) {
  const insets = useSafeAreaInsets();
  const palette = useDesignTheme();
  const { t } = useI18n();
  const isDesktop = useIsDesktop();
  const [moreOpen, setMoreOpen] = useState(false);

  const visible = state.routes.filter((route: TabRoute) => {
    const opts = descriptors[route.key].options as { href?: string | null };
    return opts.href !== null;
  });

  const items = visible.map((route: TabRoute) => {
    const { options } = descriptors[route.key];
    const activeIndex = state.routes.findIndex((r: TabRoute) => r.key === route.key);
    const isFocused = state.index === activeIndex;
    return {
      key: route.key,
      name: route.name,
      label: (options.title ?? route.name) as string,
      icon: options.tabBarIcon,
      isFocused,
      onPress: () => {
        const event = navigation.emit({ type: 'tabPress', target: route.key, canPreventDefault: true });
        if (!isFocused && !event.defaultPrevented) {
          navigation.navigate(route.name);
        }
      },
    };
  });
  const mobilePrimaryRoutes = items.some((item) => item.name === 'staff')
    ? MANAGER_MOBILE_ROUTES
    : STAFF_MOBILE_ROUTES;
  const secondaryItems = items.filter((item) => !mobilePrimaryRoutes.has(item.name));

  const wordmark = (
    <View style={{ paddingHorizontal: 16, alignItems: 'flex-start', justifyContent: 'center', minHeight: 54 }}>
      <Text style={{ color: palette.charcoal, fontWeight: '700', fontSize: 13 }}>
        {t('common.venueWrangler')}
      </Text>
      <Text style={{ color: palette.muted, fontSize: 9, fontStyle: 'italic' }}>{t('common.loungeability')}</Text>
    </View>
  );

  if (isDesktop) {
    return (
      <View
        // Absolute rather than part of the navigator's flex row: expo-router's
        // bundled Tabs always renders the tabBar below the scene, and it has no
        // supported "left" placement. Screens reserve this width through
        // useDesktopContentStyle, so nothing renders underneath it.
        style={{
          position: 'absolute',
          top: 0,
          bottom: 0,
          left: 0,
          width: DESKTOP_NAV_WIDTH,
          backgroundColor: palette.backgroundAlt,
          borderRightWidth: StyleSheet.hairlineWidth,
          borderRightColor: palette.divider,
          zIndex: 10,
        }}
      >
        {wordmark}
        <ScrollView
          showsVerticalScrollIndicator={false}
          contentContainerStyle={{ paddingVertical: 8, paddingHorizontal: 10, gap: 2 }}
        >
          {DESKTOP_GROUPS.map((group) => {
            const groupItems = group.routes.map((name) => items.find((item) => item.name === name)).filter(Boolean) as typeof items;
            if (!groupItems.length) return null;
            return (
              <View key={group.label} style={{ gap: 2, marginBottom: 14 }}>
                <Text style={{ color: palette.muted, fontSize: 10, fontWeight: '700', letterSpacing: 0.8, textTransform: 'uppercase', paddingHorizontal: 12, paddingBottom: 4 }}>
                  {group.label}
                </Text>
                {groupItems.map((item) => (
                  <Pressable
                    key={item.key}
                    onPress={item.onPress}
                    accessibilityRole="tab"
                    accessibilityLabel={item.label}
                    accessibilityState={item.isFocused ? { selected: true } : {}}
                    style={({ pressed }) => ({
                      flexDirection: 'row', alignItems: 'center', gap: 12,
                      paddingVertical: 10, paddingHorizontal: 12, borderRadius: 8,
                      backgroundColor: item.isFocused ? palette.cream : 'transparent',
                      opacity: pressed ? 0.66 : 1,
                    })}
                  >
                    {item.icon?.({ focused: item.isFocused, color: item.isFocused ? palette.primary : palette.muted, size: 19 })}
                    <Text numberOfLines={1} style={{ flex: 1, color: item.isFocused ? palette.primary : palette.charcoal, fontSize: 13.5, fontWeight: item.isFocused ? '700' : '500' }}>
                      {item.label}
                    </Text>
                  </Pressable>
                ))}
              </View>
            );
          })}
        </ScrollView>
      </View>
    );
  }

  return (
    <View
      style={{
        backgroundColor: palette.backgroundAlt,
        borderTopWidth: StyleSheet.hairlineWidth,
        borderTopColor: palette.divider,
        paddingBottom: insets.bottom,
      }}
    >
      {moreOpen ? (
        <View style={{ borderBottomWidth: StyleSheet.hairlineWidth, borderBottomColor: palette.divider, padding: 16 }}>
          <View style={{ flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between' }}>
            <Text style={{ fontSize: 20, fontWeight: '700', color: palette.charcoal }}>More tools</Text>
            <Pressable accessibilityRole="button" accessibilityLabel="Close more tools" onPress={() => setMoreOpen(false)} style={{ minHeight: 44, justifyContent: 'center', paddingHorizontal: 12 }}>
              <Text style={{ color: palette.primary, fontWeight: '600' }}>Close</Text>
            </Pressable>
          </View>
          <ScrollView style={{ maxHeight: 280 }}>
            {secondaryItems.map((item) => (
              <Pressable key={item.key} accessibilityRole="button" accessibilityLabel={item.label} onPress={() => { item.onPress(); setMoreOpen(false); }} style={({ pressed }) => ({ flexDirection: 'row', gap: 12, alignItems: 'center', minHeight: 48, paddingHorizontal: 12, borderRadius: 8, backgroundColor: item.isFocused ? palette.cream : 'transparent', opacity: pressed ? 0.65 : 1 })}>
                {item.icon?.({ focused: item.isFocused, color: palette.primary, size: 20 })}
                <Text style={{ color: palette.charcoal, fontSize: 14, fontWeight: item.isFocused ? '700' : '500' }}>{item.label}</Text>
              </Pressable>
            ))}
          </ScrollView>
        </View>
      ) : null}
      <View style={{ flexDirection: 'row', alignItems: 'center', paddingHorizontal: 8 }}>
        {items.filter((item) => mobilePrimaryRoutes.has(item.name)).map((item) => {
          const color = item.isFocused ? palette.primary : palette.muted;
          return (
            <Pressable
              key={item.key}
              onPress={() => { setMoreOpen(false); item.onPress(); }}
              accessibilityRole="tab"
              accessibilityLabel={item.label}
              accessibilityState={item.isFocused ? { selected: true } : {}}
              style={{
                flex: 1,
                paddingTop: 9,
                paddingBottom: 7,
                paddingHorizontal: 8,
                alignItems: 'center',
                gap: 3,
                borderBottomWidth: 2,
                borderBottomColor: item.isFocused ? palette.primary : 'transparent',
              }}
            >
              {item.icon?.({ focused: item.isFocused, color, size: 21 })}
              <Text
                numberOfLines={1}
                style={{ color, fontSize: 10.5, fontWeight: item.isFocused ? '700' : '500', letterSpacing: 0.1 }}
              >
                {item.label}
              </Text>
            </Pressable>
          );
        })}
        {secondaryItems.length ? <Pressable accessibilityRole="button" accessibilityLabel="More tools" accessibilityState={{ expanded: moreOpen }} onPress={() => setMoreOpen((open) => !open)} style={{ flex: 1, minHeight: 54, alignItems: 'center', justifyContent: 'center', gap: 3, borderBottomWidth: 2, borderBottomColor: moreOpen || secondaryItems.some((item) => item.isFocused) ? palette.primary : 'transparent' }}>
          <Text style={{ color: palette.primary, fontSize: 21, lineHeight: 24, fontWeight: '700' }}>···</Text>
          <Text style={{ color: palette.muted, fontSize: 10.5, fontWeight: '600' }}>More</Text>
        </Pressable> : null}
      </View>
    </View>
  );
}

import React, { act } from 'react';
import { createRoot } from 'test-renderer';
import { beforeEach, describe, expect, it, vi } from 'vitest';

/**
 * Desktop-web layout parity.
 *
 * lib/responsive.ts shipped with the calendar port and then reached three files
 * out of forty, so on a wide monitor most screens stretched cards, inputs and
 * buttons edge to edge while two did not. The fix applies the column centrally
 * (ScreenErrorBoundary -> DesktopFrame) and turns the bottom tab strip into a
 * left rail at the same breakpoint.
 *
 * These assert the behaviour directly because an end-to-end visual check is not
 * available in this environment: `expo start --web` needs a TTY, and
 * `expo export -p web` fails to resolve expo-router/entry on this machine.
 */

const env = vi.hoisted(() => ({ os: 'web' as string, width: 1680 }));

vi.mock('react-native', () => ({
  Platform: { get OS() { return env.os; } },
  useWindowDimensions: () => ({ width: env.width, height: 1000 }),
  View: 'View',
  Text: 'Text',
  Pressable: 'Pressable',
  ScrollView: 'ScrollView',
  StyleSheet: { hairlineWidth: 1 },
}));
vi.mock('react-native-safe-area-context', () => ({ useSafeAreaInsets: () => ({ bottom: 0 }) }));
vi.mock('../../lib/theme', () => ({
  useDesignTheme: () => ({
    background: '#fff', backgroundAlt: '#f6f6f6', divider: '#ddd',
    primary: '#0a0', muted: '#777', charcoal: '#222',
  }),
  spacing: { xs: 4, sm: 8, md: 16, lg: 24, xl: 32, xxl: 48 },
}));
vi.mock('../../lib/i18n', () => ({ useI18n: () => ({ t: (k: string) => k }) }));

const { View } = await import('react-native');
const { DesktopFrame } = await import('../../components/DesktopFrame');
const { CarouselTabBar } = await import('../../components/CarouselTabBar');
const { DESKTOP_NAV_WIDTH, DESKTOP_CONTENT_MAX_WIDTH, DESKTOP_BREAKPOINT } =
  await import('../../lib/responsive');

/** The rendered root element (test-renderer wraps output in an empty host). */
function render(node: React.ReactElement) {
  const renderer = createRoot();
  act(() => { renderer.render(node); });
  const root = renderer.container.toJSON() as any;
  return root?.type ? root : root?.children?.[0];
}

describe('DesktopFrame', () => {
  beforeEach(() => { env.os = 'web'; env.width = 1680; });

  it('constrains a screen to the content column and reserves the nav rail', () => {
    const tree = render(<DesktopFrame><View /></DesktopFrame>);
    expect(tree.type).toBe('View');
    expect(tree.props.style).toMatchObject({
      maxWidth: DESKTOP_NAV_WIDTH + DESKTOP_CONTENT_MAX_WIDTH,
      paddingLeft: DESKTOP_NAV_WIDTH,
      alignSelf: 'center',
    });
  });

  it('adds no wrapper at all on a phone', () => {
    env.os = 'ios';
    const tree = render(<DesktopFrame><View /></DesktopFrame>);
    // The child renders directly — a phone build must get the tree it had
    // before, not an inert view around every screen.
    expect(tree.type).toBe('View');
    expect(tree.props.style).toBeUndefined();
  });

  it('adds no wrapper just below the breakpoint', () => {
    env.width = DESKTOP_BREAKPOINT - 1;
    const tree = render(<DesktopFrame><View /></DesktopFrame>);
    expect(tree.props.style).toBeUndefined();
  });

  it('leaves spatial canvases full width', () => {
    const tree = render(<DesktopFrame fullBleed><View /></DesktopFrame>);
    expect(tree.props.style).toBeUndefined();
  });

  it('reserves no rail space for screens outside the tab navigator', () => {
    const tree = render(<DesktopFrame withNavRail={false}><View /></DesktopFrame>);
    expect(tree.props.style).toMatchObject({
      maxWidth: DESKTOP_CONTENT_MAX_WIDTH,
      paddingLeft: 0,
    });
  });
});

describe('CarouselTabBar', () => {
  it('keeps secondary destinations reachable and excludes role-hidden routes', () => {
    env.os = 'ios';
    const navigate = vi.fn();
    const routeNames = ['home', 'schedule', 'staff', 'chat', 'clock', 'profile', 'reports'];
    const root = createRoot();
    const descriptors = Object.fromEntries(routeNames.map((name) => [name, { options: { title: name, ...(name === 'reports' ? { href: null } : {}) } }]));
    act(() => root.render(<CarouselTabBar {...({ state: { routes: routeNames.map((name) => ({ key: name, name })), index: 0 }, descriptors, navigation: { emit: () => ({ defaultPrevented: false }), navigate } } as any)} />));
    const byLabel = (label: string) => root.container.queryAll((node) => node.type === 'Pressable' && node.props.accessibilityLabel === label)[0];
    expect(byLabel('clock')).toBeUndefined();
    act(() => byLabel('More tools').props.onPress());
    expect(byLabel('clock')).toBeDefined();
    expect(byLabel('profile')).toBeDefined();
    expect(byLabel('reports')).toBeUndefined();
    act(() => byLabel('clock').props.onPress());
    expect(navigate).toHaveBeenCalledWith('clock');
    expect(byLabel('More tools').props.accessibilityState.expanded).toBe(false);
  });

  const routes = [
    { key: 'home', name: 'home' },
    { key: 'clock', name: 'clock' },
  ];
  const props = {
    state: { routes, index: 0 },
    descriptors: {
      home: { options: { title: 'Home', tabBarIcon: () => null } },
      clock: { options: { title: 'Clock', tabBarIcon: () => null } },
    },
    navigation: { emit: () => ({ defaultPrevented: false }), navigate: vi.fn() },
  } as any;

  beforeEach(() => { env.os = 'web'; env.width = 1680; });

  it('renders a fixed left rail on desktop', () => {
    const tree = render(<CarouselTabBar {...props} />);
    expect(tree.props.style).toMatchObject({
      position: 'absolute',
      left: 0,
      width: DESKTOP_NAV_WIDTH,
    });
  });

  it('reserves exactly the width the screen frame insets by', () => {
    // The rail is absolutely positioned, so the two are only kept apart by
    // sharing this constant. If they drift, content slides under the nav.
    const rail = render(<CarouselTabBar {...props} />);
    const frame = render(<DesktopFrame><View /></DesktopFrame>);
    expect(rail.props.style.width).toBe(frame.props.style.paddingLeft);
  });

  it('keeps the bottom strip on a phone', () => {
    env.os = 'ios';
    const tree = render(<CarouselTabBar {...props} />);
    expect(tree.props.style.position).toBeUndefined();
    expect(tree.props.style).toMatchObject({ borderTopWidth: 1 });
  });

  it('keeps the bottom strip on narrow web', () => {
    env.width = DESKTOP_BREAKPOINT - 1;
    const tree = render(<CarouselTabBar {...props} />);
    expect(tree.props.style.position).toBeUndefined();
  });
});

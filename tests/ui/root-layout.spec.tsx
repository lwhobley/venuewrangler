import React, { act } from 'react';
import { createRoot } from 'test-renderer';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

const mocks = vi.hoisted(() => ({
  platform: { OS: 'ios' },
  fonts: [false, undefined] as [boolean, Error | undefined],
  auth: { authEpoch: 1, user: null, venue: null, token: null },
  cancelQueries: vi.fn().mockResolvedValue(undefined),
  clear: vi.fn(),
  configurePurchases: vi.fn().mockResolvedValue(undefined),
  logoutPurchases: vi.fn().mockResolvedValue(undefined),
}));

// Preserve native exports used by the layout tree; override only the behavior
// pinned by these bootstrap tests.
vi.mock('react-native', async (importOriginal) => ({
  ...(await importOriginal<typeof import('react-native')>()),
  Platform: mocks.platform,
  View: 'View',
}));
vi.mock('expo-router', () => ({ Stack: 'Stack' }));
vi.mock('react-native-gesture-handler', () => ({ GestureHandlerRootView: 'GestureHandlerRootView' }));
vi.mock('@tanstack/react-query', () => ({ QueryClientProvider: 'QueryClientProvider' }));
vi.mock('react-native-paper', () => ({ PaperProvider: 'PaperProvider' }));
vi.mock('@expo/vector-icons', () => ({ MaterialCommunityIcons: { font: { MaterialCommunityIcons: 'font' } } }));
vi.mock('@sentry/react-native', () => ({ init: vi.fn(), captureException: vi.fn(), wrap: (component: unknown) => component }));
vi.mock('expo-font', () => ({ useFonts: () => mocks.fonts }));
vi.mock('@expo-google-fonts/fraunces', () => ({
  Fraunces_500Medium: 'Fraunces_500Medium',
  Fraunces_600SemiBold: 'Fraunces_600SemiBold',
  Fraunces_600SemiBold_Italic: 'Fraunces_600SemiBold_Italic',
}));
vi.mock('../../lib/a0-purchases-stub', () => ({ A0PurchaseProvider: 'A0PurchaseProvider' }));
vi.mock('react-native-safe-area-context', () => ({ SafeAreaProvider: 'SafeAreaProvider', SafeAreaView: 'SafeAreaView' }));
vi.mock('../../lib/theme', () => ({
  makePaperTheme: () => ({}),
  useAppearanceStore: (selector: (state: { mode: string }) => unknown) => selector({ mode: 'light' }),
  designPalettes: { light: { background: '#fff' } },
}));
vi.mock('../../components/SubscriptionGate', () => ({ SubscriptionGate: 'SubscriptionGate' }));
vi.mock('../../components/ErrorBoundary', () => ({ ErrorBoundary: 'ErrorBoundary' }));
vi.mock('../../lib/auth-store', () => ({ useAuthStore: (selector: (state: typeof mocks.auth) => unknown) => selector(mocks.auth) }));
vi.mock('../../lib/purchases', () => ({
  configurePurchases: mocks.configurePurchases,
  logoutPurchases: mocks.logoutPurchases,
}));
vi.mock('../../lib/query-client', () => ({ queryClient: { cancelQueries: mocks.cancelQueries, clear: mocks.clear } }));
vi.mock('../../lib/report-error', () => ({ setFatalErrorReporter: vi.fn() }));

vi.stubGlobal('__DEV__', true);
vi.stubGlobal('IS_REACT_ACT_ENVIRONMENT', true);

import { RootLayout } from '../../app/_layout';

describe('RootLayout bootstrap', () => {
  beforeEach(() => {
    mocks.platform.OS = 'ios';
    mocks.fonts = [false, undefined];
    vi.clearAllMocks();
  });

  it('mounts native navigation without waiting indefinitely for fonts', async () => {
    const renderer = createRoot();
    await act(async () => renderer.render(<RootLayout />));
    expect(JSON.stringify(renderer.container.toJSON())).toContain('Stack');
  });

  it('holds web first paint until fonts load or fail explicitly', async () => {
    mocks.platform.OS = 'web';
    const renderer = createRoot();
    await act(async () => renderer.render(<RootLayout />));
    expect(JSON.stringify(renderer.container.toJSON())).not.toContain('Stack');

    mocks.fonts = [true, undefined];
    await act(async () => renderer.render(<RootLayout />));
    expect(JSON.stringify(renderer.container.toJSON())).toContain('Stack');
  });
});

// The DSN-conditional Sentry.init / setFatalErrorReporter wiring runs once at
// module scope on import, not on render — so exercising both branches needs a
// fresh module graph per test (vi.resetModules + dynamic import) rather than
// the static import + render used above. lib/report-error.ts's own comment
// claims this wiring exists; nothing previously asserted it does.
describe('RootLayout Sentry wiring', () => {
  const ORIGINAL_DSN = process.env.EXPO_PUBLIC_SENTRY_DSN;

  beforeEach(() => {
    // The @sentry/react-native and report-error mocks are singletons that
    // vi.resetModules() does not re-create, so call history from one test
    // (e.g. the DSN-present branch's Sentry.init call) otherwise leaks into
    // the next.
    vi.clearAllMocks();
  });

  afterEach(() => {
    if (ORIGINAL_DSN === undefined) delete process.env.EXPO_PUBLIC_SENTRY_DSN;
    else process.env.EXPO_PUBLIC_SENTRY_DSN = ORIGINAL_DSN;
  });

  it('initializes Sentry and registers a reporter that forwards to captureException when a DSN is configured', async () => {
    process.env.EXPO_PUBLIC_SENTRY_DSN = 'https://examplePublicKey@o0.ingest.sentry.io/0';
    vi.resetModules();
    const Sentry = await import('@sentry/react-native');
    const { setFatalErrorReporter } = await import('../../lib/report-error');

    await import('../../app/_layout');

    expect(Sentry.init).toHaveBeenCalledWith(
      expect.objectContaining({ dsn: 'https://examplePublicKey@o0.ingest.sentry.io/0' }),
    );
    expect(setFatalErrorReporter).toHaveBeenCalledWith(expect.any(Function));

    const reporter = vi.mocked(setFatalErrorReporter).mock.calls[0]?.[0] as
      | ((error: Error, componentStack: string | null) => void)
      | null;
    expect(reporter).not.toBeNull();
    const boom = new Error('boom');
    reporter?.(boom, 'at Component (App.tsx:1)');

    expect(Sentry.captureException).toHaveBeenCalledWith(
      boom,
      expect.objectContaining({ contexts: { react: { componentStack: 'at Component (App.tsx:1)' } } }),
    );
  });

  it('does not initialize Sentry and clears the reporter when no DSN is configured', async () => {
    delete process.env.EXPO_PUBLIC_SENTRY_DSN;
    vi.resetModules();
    const Sentry = await import('@sentry/react-native');
    const { setFatalErrorReporter } = await import('../../lib/report-error');

    await import('../../app/_layout');

    expect(Sentry.init).not.toHaveBeenCalled();
    expect(setFatalErrorReporter).toHaveBeenCalledWith(null);
  });
});

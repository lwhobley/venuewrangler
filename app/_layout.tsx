import { useEffect, useRef } from 'react';
import { Platform, View } from 'react-native';
import { Stack } from 'expo-router';
import { GestureHandlerRootView } from 'react-native-gesture-handler';
import { QueryClientProvider } from '@tanstack/react-query';
import { PaperProvider } from 'react-native-paper';
import { MaterialCommunityIcons } from '@expo/vector-icons';
import * as Sentry from '@sentry/react-native';
import { useFonts } from 'expo-font';
import {
  Fraunces_500Medium,
  Fraunces_600SemiBold,
  Fraunces_600SemiBold_Italic,
} from '@expo-google-fonts/fraunces';
import { A0PurchaseProvider } from '../lib/a0-purchases-stub';
import { SafeAreaProvider, SafeAreaView } from 'react-native-safe-area-context';
import { makePaperTheme, useAppearanceStore, designPalettes } from '../lib/theme';
import { SubscriptionGate } from '../components/SubscriptionGate';
import { ErrorBoundary } from '../components/ErrorBoundary';
import { useAuthStore, type AuthState } from '../lib/auth-store';
import { configurePurchases, logoutPurchases } from '../lib/purchases';
import { queryClient } from '../lib/query-client';
import { setFatalErrorReporter } from '../lib/report-error';
import { fontsReadyForPlatform } from '../lib/app-bootstrap';

const sentryDsn = process.env.EXPO_PUBLIC_SENTRY_DSN?.trim();

if (sentryDsn) {
  Sentry.init({
    dsn: sentryDsn,
    enabled: !__DEV__,
    sendDefaultPii: false,
    tracesSampleRate: 0,
    beforeSend(event) {
      const strip = (value?: string) => value?.replace(/([?&])token=[^&]*/g, '$1token=redacted');
      if (event.request?.url) event.request.url = strip(event.request.url);
      return event;
    },
  });
  setFatalErrorReporter((error, componentStack) => {
    Sentry.captureException(error, {
      contexts: componentStack
        ? { react: { componentStack } }
        : undefined,
    });
  });
} else {
  setFatalErrorReporter(null);
}

const shouldIgnoreWebError = (message: string) =>
  message.includes('ResizeObserver loop completed with undelivered notifications') ||
  message.includes('ResizeObserver loop limit exceeded') ||
  message.includes("Failed to execute 'importScripts' on 'WorkerGlobalScope'") ||
  message.includes('monaco-editor') ||
  message.includes('ts.worker');

export function RootLayout() {
  const themeMode = useAppearanceStore((state) => state.mode);
  const palette = designPalettes[themeMode];
  // Preload the MaterialCommunityIcons glyph font so icons render on web (Paper
  // and the nav use it). We hold the first paint until it's loaded, otherwise
  // web shows blank "tofu" squares. A load error still lets the app through.
  const [fontsLoaded, fontError] = useFonts({
    ...MaterialCommunityIcons.font,
    Fraunces_500Medium,
    Fraunces_600SemiBold,
    Fraunces_600SemiBold_Italic,
  });

  // Native bundles package these fonts locally, so never hold the complete
  // navigation tree behind the asynchronous loader. Web waits to avoid a
  // first paint containing missing glyphs.
  const fontsReady = fontsReadyForPlatform(Platform.OS, fontsLoaded, fontError);
  const debug = __DEV__;
  const venueId = useAuthStore((state: AuthState) => state.venue?.id ?? null);
  const userId = useAuthStore((state: AuthState) => state.user?.id ?? null);
  const token = useAuthStore((state: AuthState) => state.token);
  const authScopeKey = useAuthStore(
    (state: AuthState) => `${state.authEpoch}:${state.user?.id ?? 'anon'}:${state.venue?.id ?? 'none'}`,
  );
  const lastAuthScopeKey = useRef<string | null>(null);

  useEffect(() => {
    if (lastAuthScopeKey.current === authScopeKey) return;
    lastAuthScopeKey.current = authScopeKey;
    void queryClient.cancelQueries();
    queryClient.clear();
  }, [authScopeKey]);

  useEffect(() => {
    if (!token) {
      void logoutPurchases();
      return;
    }
    void configurePurchases(userId ?? undefined);
  }, [token, userId]);

  useEffect(() => {
    if (Platform.OS !== 'web') return;

    const globalObject = globalThis as {
      addEventListener?: (type: string, listener: (event: any) => void) => void;
      removeEventListener?: (type: string, listener: (event: any) => void) => void;
    };

    const handleError = (event: any) => {
      const message = String(event?.message ?? event?.error?.message ?? '');
      if (shouldIgnoreWebError(message)) {
        event?.preventDefault?.();
        event?.stopPropagation?.();
      }
    };

    const handleUnhandledRejection = (event: any) => {
      const message = String(event?.reason?.message ?? event?.reason ?? '');
      if (shouldIgnoreWebError(message)) {
        event?.preventDefault?.();
        event?.stopPropagation?.();
      }
    };

    globalObject.addEventListener?.('error', handleError);
    globalObject.addEventListener?.('unhandledrejection', handleUnhandledRejection);

    return () => {
      globalObject.removeEventListener?.('error', handleError);
      globalObject.removeEventListener?.('unhandledrejection', handleUnhandledRejection);
    };
  }, []);

  if (!fontsReady) {
    return <View style={{ flex: 1, backgroundColor: palette.background }} />;
  }

  return (
    <GestureHandlerRootView style={{ flex: 1 }}>
      <SafeAreaProvider>
        <QueryClientProvider client={queryClient}>
          <PaperProvider theme={makePaperTheme(themeMode)}>
            <A0PurchaseProvider config={{ appUserId: userId ?? undefined, debug }}>
              {/* Top inset keeps content below the status bar / notch; the tab
                  bar and screens handle the bottom inset. */}
              <SafeAreaView style={{ flex: 1, backgroundColor: palette.background }} edges={['top', 'left', 'right']}>
                <ErrorBoundary>
                  <SubscriptionGate>
                    <Stack screenOptions={{ headerShown: false, contentStyle: { backgroundColor: palette.background } }} />
                  </SubscriptionGate>
                </ErrorBoundary>
              </SafeAreaView>
            </A0PurchaseProvider>
          </PaperProvider>
        </QueryClientProvider>
      </SafeAreaProvider>
    </GestureHandlerRootView>
  );
}

export default Sentry.wrap(RootLayout);

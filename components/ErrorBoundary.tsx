import { Button } from './AppButton';
import { Component, type ErrorInfo, type ReactNode } from 'react';
import { View, ScrollView } from 'react-native';
import { Text } from 'react-native-paper';
import { router } from 'expo-router';
import { colors, spacing, radius } from '../lib/theme';
import { queryClient } from '../lib/query-client';
import { reportFatalError } from '../lib/report-error';
import { useAuthStore } from '../lib/auth-store';
import { DesktopFrame } from './DesktopFrame';

type Props = { children: ReactNode };
type State = { error: Error | null; componentStack: string | null };

// App-wide error boundary. A failed async data hook would otherwise unmount the
// whole tree, which is a hard
// crash in a release build. This catches it and shows a recoverable screen
// instead, so a single screen's data error never takes down the app.
//
// It also carries the desktop-web frame. Nearly every screen already routes
// through here, which makes it the one place the content column can be applied
// consistently — the previous per-screen approach reached three files out of
// forty and then stopped. DesktopFrame is inert on native and narrow web.
export function ScreenErrorBoundary({
  children,
  fullBleed = false,
  withNavRail = true,
}: {
  children: ReactNode;
  /** Spatial canvases (floor plan, editor) keep the full window width. */
  fullBleed?: boolean;
  /** False for screens rendered outside the tab navigator. */
  withNavRail?: boolean;
}) {
  return (
    <ErrorBoundary>
      <DesktopFrame fullBleed={fullBleed} withNavRail={withNavRail}>
        {children}
      </DesktopFrame>
    </ErrorBoundary>
  );
}

export class ErrorBoundary extends Component<Props, State> {
  state: State = { error: null, componentStack: null };

  static getDerivedStateFromError(error: Error): Partial<State> {
    return { error };
  }

  componentDidCatch(error: Error, errorInfo: ErrorInfo) {
    if (typeof __DEV__ !== 'undefined' && __DEV__) console.error('[ErrorBoundary] caught:', error);
    // Release builds previously swallowed every caught crash: no console, no
    // telemetry. A whitescreen in production produced zero signal.
    reportFatalError(error, errorInfo.componentStack ?? null);
    this.setState({ componentStack: errorInfo.componentStack ?? null });
  }

  private reset = (goHome: boolean) => {
    void queryClient.resetQueries({
      predicate: (query) => query.state.status === 'error',
    });
    this.setState({ error: null, componentStack: null });
    if (goHome) {
      try {
        router.replace('/(tabs)/home');
      } catch {
        // ignore navigation errors
      }
    }
  };

  private signOut = () => {
    void useAuthStore.getState().clearSession();
    this.setState({ error: null, componentStack: null });
    try {
      router.replace('/(auth)/welcome');
    } catch {
      // ignore navigation errors
    }
  };

  render() {
    const { error } = this.state;
    if (!error) return this.props.children;
    return (
      <ScrollView
        style={{ flex: 1, backgroundColor: colors.background }}
        contentContainerStyle={{ flexGrow: 1, justifyContent: 'center', padding: spacing.xl, gap: spacing.md }}
      >
        <View style={{ backgroundColor: colors.surface, borderRadius: radius.lg, padding: spacing.xl, gap: spacing.md }}>
          <Text variant="headlineSmall" style={{ color: colors.primary, fontWeight: '800' }}>
            Something went wrong
          </Text>
          <Text style={{ color: colors.muted }}>
            This screen hit an error and couldn’t load. Your data is safe — try again or head back home.
          </Text>
          {typeof __DEV__ !== 'undefined' && __DEV__ ? (
            <View style={{ gap: 4 }}>
              <Text style={{ color: colors.danger, fontSize: 12, fontWeight: '700' }}>
                {error.name}: {error.message}
              </Text>
              {this.state.componentStack ? (
                <Text style={{ color: colors.muted, fontSize: 11 }} numberOfLines={8}>
                  {this.state.componentStack.trim()}
                </Text>
              ) : null}
            </View>
          ) : null}
          <Button mode="contained" buttonColor={colors.primary} accessibilityLabel="Back to Home" onPress={() => this.reset(true)}>
            Back to Home
          </Button>
          <Button mode="text" textColor={colors.primary} accessibilityLabel="Try again" onPress={() => this.reset(false)}>
            Try again
          </Button>
          <Button mode="text" textColor={colors.muted} accessibilityLabel="Sign out" onPress={this.signOut}>
            Sign out
          </Button>
        </View>
      </ScrollView>
    );
  }
}

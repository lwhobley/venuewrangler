import { Button } from './AppButton';
/**
 * Shared component for screens that require manager/admin access.
 * Renders a permission message when the user lacks access, or the
 * children when they do.
 *
 * Previously every manager-only screen duplicated its own gate UI.
 */
import type { ReactNode } from 'react';
import { ScrollView } from 'react-native';
import { Text } from 'react-native-paper';
import { colors, spacing } from '../lib/theme';

type ManagerGateProps = {
  canManage: boolean;
  profileLoading: boolean;
  /** Set when the profile fetch failed after retries — distinct from still loading. */
  profileError?: unknown;
  onRetry?: () => void;
  feature: string;
  children: ReactNode;
};

export function ManagerGate({ canManage, profileLoading, profileError, onRetry, feature, children }: ManagerGateProps) {
  if (profileLoading) {
    return (
      <ScrollView
        style={{ flex: 1, backgroundColor: colors.background }}
        contentContainerStyle={{ padding: spacing.lg }}
      >
        <Text style={{ color: colors.muted }}>Loading…</Text>
      </ScrollView>
    );
  }

  if (profileError) {
    return (
      <ScrollView
        style={{ flex: 1, backgroundColor: colors.background }}
        contentContainerStyle={{ padding: spacing.lg, gap: spacing.sm }}
      >
        <Text style={{ color: colors.muted }}>
          Couldn't load your profile. Check your connection and try again.
        </Text>
        {onRetry ? (
          <Button mode="outlined" onPress={onRetry}>
            Retry
          </Button>
        ) : null}
      </ScrollView>
    );
  }

  if (!canManage) {
    return (
      <ScrollView
        style={{ flex: 1, backgroundColor: colors.background }}
        contentContainerStyle={{ padding: spacing.lg }}
      >
        <Text style={{ color: colors.muted }}>
          {feature} is available to managers and admins.
        </Text>
      </ScrollView>
    );
  }

  return <>{children}</>;
}

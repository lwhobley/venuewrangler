import type { ReactNode } from 'react';
import { Pressable, View } from 'react-native';
import { Text } from 'react-native-paper';
import { router } from 'expo-router';
import { ActionButton, EmptyState, RowSkeleton } from './design-system';
import { colors, spacing } from '../lib/theme';
import { useI18n } from '../lib/i18n';

/**
 * One place to render the four states a server-backed panel can be in.
 *
 * The dominant data hook (`useQuery`) returns only `.data`, so a screen sees
 * `undefined` for "not started", "in flight", "failed" and "refused" alike —
 * which is why panels could sit on a loading skeleton indefinitely and why a
 * failed background refetch showed stale data with no indication. `useQueryState`
 * distinguishes them; this renders them consistently rather than each screen
 * reinventing the four branches.
 *
 * Usage (route reference written without the `api.` prefix so the route-parity
 * spec does not read this example as a real registry entry):
 *
 *   const state = useQueryState<Shape>(<namespace>.<fn>, args);
 *   <QueryBoundary state={state} isEmpty={(d) => d.rows.length === 0}>
 *     {(data) => <Panel data={data} />}
 *   </QueryBoundary>
 */

export type QueryBoundaryState<T> = {
  data: T | undefined;
  error: unknown;
  subscriptionRequired?: boolean;
  isLoading: boolean;
  refetch: () => unknown;
};

export function QueryBoundary<T>({
  state,
  children,
  isEmpty,
  emptyMessage,
  feature,
  skeleton,
}: {
  state: QueryBoundaryState<T>;
  children: (data: T) => ReactNode;
  /** Treat a successful-but-empty response as its own state. */
  isEmpty?: (data: T) => boolean;
  emptyMessage?: string;
  /** Feature name shown by the upgrade prompt on a 402. */
  feature?: string;
  skeleton?: ReactNode;
}) {
  const { t } = useI18n();

  // Checked before loading: a 402 is a settled answer, not a pending one.
  // Rendered inline rather than through PremiumFeatureGate, which is a
  // full-screen takeover and would swallow the rest of the screen.
  if (state.subscriptionRequired) {
    return (
      <View style={{ gap: spacing.sm, paddingVertical: spacing.sm }}>
        <Text style={{ color: colors.muted }}>
          {t('queryBoundary.upgradeRequired', { feature: feature ?? t('queryBoundary.thisFeature') })}
        </Text>
        <ActionButton label={t('queryBoundary.viewPlans')} onPress={() => router.push('/billing')} />
      </View>
    );
  }

  if (state.isLoading && state.data === undefined) {
    return <>{skeleton ?? <RowSkeleton />}</>;
  }

  if (state.error && state.data === undefined) {
    return (
      <View style={{ gap: spacing.sm, paddingVertical: spacing.sm }}>
        <Text style={{ color: colors.danger }}>
          {state.error instanceof Error ? state.error.message : t('queryBoundary.error')}
        </Text>
        <ActionButton label={t('queryBoundary.retry')} onPress={() => void state.refetch()} />
      </View>
    );
  }

  if (state.data === undefined) return null;

  if (isEmpty?.(state.data)) {
    return (
      <EmptyState title={emptyMessage ?? t('queryBoundary.empty')} />
    );
  }

  // Data is present but a background refetch failed. Keep showing it — it is
  // still the last known good state — while saying plainly that it is stale,
  // which is what the previous silent behaviour got wrong.
  return (
    <>
      {state.error ? (
        <Text style={{ color: colors.muted, fontSize: 12 }}>{t('queryBoundary.stale')}</Text>
      ) : null}
      {children(state.data)}
    </>
  );
}

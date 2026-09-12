import { StyleSheet, View } from 'react-native';
import { MaterialCommunityIcons } from '@expo/vector-icons';
import { CommandText } from './FutureUI';
import { spacing, useDesignTheme } from '../lib/theme';
import type { WranglerPriority, WranglerSnapshot } from '../lib/useWrangler';

type Props = {
  snapshot: WranglerSnapshot;
};

function storyLabel(priority: WranglerPriority) {
  if (priority.kind === 'floor') return 'Floor';
  if (priority.kind === 'coverage') return 'Team';
  if (priority.kind === 'stock') return 'Bar';
  if (priority.kind === 'event') return 'Guest';
  if (priority.kind === 'requests') return 'Team';
  return 'Service';
}

function storyIcon(priority: WranglerPriority) {
  if (priority.kind === 'floor') return 'table-chair' as const;
  if (priority.kind === 'coverage') return 'account-group-outline' as const;
  if (priority.kind === 'stock') return 'bottle-wine-outline' as const;
  if (priority.kind === 'event') return 'account-star-outline' as const;
  if (priority.kind === 'requests') return 'clipboard-clock-outline' as const;
  return 'check-circle-outline' as const;
}

export function WranglerShiftStory({ snapshot }: Props) {
  const palette = useDesignTheme();
  const story = snapshot.priorities.filter((priority) => priority.kind !== 'steady').slice(0, 4);

  if (!story.length) {
    return (
      <View style={{ borderTopWidth: StyleSheet.hairlineWidth, borderBottomWidth: StyleSheet.hairlineWidth, borderColor: palette.divider, paddingVertical: spacing.lg, gap: spacing.xs }}>
        <CommandText palette={palette} variant="title">Shift story</CommandText>
        <CommandText palette={palette} variant="body">Nothing is pulling service off course right now. The Wrangler is watching the floor, team, arrivals, and stock together.</CommandText>
      </View>
    );
  }

  return (
    <View style={{ gap: spacing.md }}>
      <View style={{ gap: 3 }}>
        <CommandText palette={palette} variant="title">Shift story</CommandText>
        <CommandText palette={palette} variant="caption">One service, not a stack of modules. Here is how the pressure points connect right now.</CommandText>
      </View>

      <View style={{ borderLeftWidth: 1, borderColor: palette.divider, marginLeft: 11 }}>
        {story.map((priority, index) => {
          const urgent = priority.severity === 'critical' || priority.severity === 'warning';
          const accent = urgent ? palette.warning : priority.severity === 'watch' ? '#8A6B2D' : palette.success;
          return (
            <View key={priority.id} style={{ marginLeft: -11, paddingBottom: index === story.length - 1 ? 0 : spacing.lg, flexDirection: 'row', gap: spacing.md }}>
              <View style={{ width: 23, height: 23, borderRadius: 12, backgroundColor: palette.surfaceSoft, borderWidth: 1, borderColor: accent, alignItems: 'center', justifyContent: 'center' }}>
                <MaterialCommunityIcons name={storyIcon(priority)} size={13} color={accent} />
              </View>
              <View style={{ flex: 1, gap: 3, paddingTop: 1 }}>
                <View style={{ flexDirection: 'row', alignItems: 'center', gap: spacing.sm }}>
                  <CommandText palette={palette} variant="label" style={{ color: accent }}>{storyLabel(priority)}</CommandText>
                  <CommandText palette={palette} variant="caption">{priority.severity === 'critical' ? 'Now' : priority.severity === 'warning' ? 'Next' : 'Watch'}</CommandText>
                </View>
                <CommandText palette={palette} variant="body" style={{ fontWeight: '700' }}>{priority.title}</CommandText>
                <CommandText palette={palette} variant="caption">{priority.body}</CommandText>
              </View>
            </View>
          );
        })}
      </View>
    </View>
  );
}

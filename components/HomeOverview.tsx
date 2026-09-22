import { Pressable, Text, View } from 'react-native';
import type { DesignPalette } from '../lib/theme';

export type OverviewItem = { id: string; title: string; time: string; detail: string; onPress: () => void };
type Props = {
  palette: DesignPalette;
  readiness: ReadonlyArray<readonly [string, number]>;
  readinessScore?: number;
  readinessUnavailable?: boolean;
  onOpenArea: (area: string) => void;
  timeline: OverviewItem[];
  timelineLoading?: boolean;
  timelineUnavailable?: boolean;
  onOpenSchedule: () => void;
  metrics: ReadonlyArray<readonly [string, string]>;
};

/** Read-only operational summary. Route and data decisions stay in the screen. */
export function HomeOverview({ palette: p, readiness, readinessScore, readinessUnavailable, onOpenArea, timeline, timelineLoading, timelineUnavailable, onOpenSchedule, metrics }: Props) {
  const text = { color: p.charcoal, fontSize: 14 };
  return <View style={{ gap: 28 }}>
    <View style={{ gap: 12 }}>
      <View style={{ flexDirection: 'row', alignItems: 'center', flexWrap: 'wrap', justifyContent: 'space-between', gap: 8 }}>
        <Text style={{ ...text, fontSize: 20, fontWeight: '700' }}>Readiness snapshot</Text>
        <Text style={{ color: p.muted, fontSize: 12, fontWeight: '600' }}>{readinessUnavailable ? 'Unavailable' : readinessScore == null ? 'Checking service' : `${readinessScore}% ready`}</Text>
      </View>
      <View style={{ borderWidth: 1, borderColor: p.border, backgroundColor: p.surface, borderRadius: 12, overflow: 'hidden' }}>
        {readiness.map(([label, value], index) => {
          const unknown = readinessUnavailable || readinessScore == null;
          const status = unknown ? 'Unknown' : value >= 100 ? 'Clear' : value > 0 ? `${value}% watch` : 'Pending';
          const color = unknown || value <= 0 ? p.muted : value >= 100 ? p.success : p.warning;
          return <Pressable key={label} accessibilityRole="button" accessibilityLabel={`${label}: ${status}`} onPress={() => onOpenArea(label)} style={({ pressed }) => ({ padding: 16, flexDirection: 'row', alignItems: 'center', gap: 12, borderTopWidth: index ? 1 : 0, borderColor: p.divider, opacity: pressed ? 0.7 : 1 })}>
            <View style={{ flex: 1, gap: 4 }}>
              <Text style={{ ...text, fontWeight: '600' }}>{label}</Text>
              <Text style={{ color: p.muted, fontSize: 12 }}>{label === 'Staffing' ? 'Manager' : 'Team'}</Text>
            </View>
            <View style={{ flexDirection: 'row', alignItems: 'center', gap: 6 }}>
              <View style={{ width: 6, height: 6, borderRadius: 3, backgroundColor: color }} />
              <Text style={{ color, fontSize: 12, fontWeight: '700' }}>{status}</Text>
            </View>
            <Text style={{ color: p.muted, fontSize: 20 }}>›</Text>
          </Pressable>;
        })}
      </View>
    </View>
    <View style={{ gap: 12 }}>
      <View style={{ flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', gap: 8 }}>
        <Text style={{ ...text, fontSize: 20, fontWeight: '700' }}>Today’s flow</Text>
        <Pressable accessibilityRole="button" onPress={onOpenSchedule} style={{ minHeight: 44, justifyContent: 'center', paddingHorizontal: 8 }}>
          <Text style={{ color: p.primary, fontSize: 13, fontWeight: '600' }}>Schedule →</Text>
        </Pressable>
      </View>
      {timelineUnavailable ? <Text style={{ color: p.muted, fontSize: 14 }}>Today’s flow is unavailable. Retry the dashboard to refresh it.</Text>
        : timelineLoading ? <Text style={{ color: p.muted, fontSize: 14 }}>Loading today’s flow…</Text>
        : timeline.length ? timeline.map((item, index) => <Pressable key={item.id} accessibilityRole="button" accessibilityLabel={item.title} onPress={item.onPress} style={({ pressed }) => ({ flexDirection: 'row', gap: 12, opacity: pressed ? 0.7 : 1 })}>
          <View style={{ width: 14, alignItems: 'center' }}>
            <View style={{ width: 8, height: 8, borderRadius: 4, backgroundColor: index === 0 ? p.primary : p.border, marginTop: 5 }} />
            {index < timeline.length - 1 ? <View style={{ width: 1, flex: 1, backgroundColor: p.divider, marginTop: 5 }} /> : null}
          </View>
          <View style={{ flex: 1, gap: 4, paddingBottom: 16 }}>
            <Text style={{ color: p.primary, fontSize: 12, fontWeight: '700', fontVariant: ['tabular-nums'] }}>{item.time}</Text>
            <Text style={{ ...text, fontSize: 15, fontWeight: '600' }}>{item.title}</Text>
            <Text style={{ color: p.muted, fontSize: 12, lineHeight: 18 }}>{item.detail}</Text>
          </View>
          <Text style={{ color: p.muted, fontSize: 20 }}>›</Text>
        </Pressable>) : <View style={{ padding: 20, borderRadius: 12, backgroundColor: p.surfaceSoft, gap: 6 }}>
          <Text style={{ ...text, fontWeight: '600' }}>Room to plan</Text>
          <Text style={{ color: p.muted, fontSize: 13, lineHeight: 20 }}>No upcoming events or goals yet.</Text>
        </View>}
    </View>
    <View style={{ flexDirection: 'row', flexWrap: 'wrap', borderTopWidth: 1, borderColor: p.divider }}>
      {metrics.map(([label, value]) => <View key={label} style={{ width: '50%', paddingVertical: 16, paddingRight: 12, gap: 5, borderBottomWidth: 1, borderColor: p.divider }}>
        <Text style={{ color: p.muted, fontSize: 12 }}>{label}</Text>
        <Text style={{ ...text, fontSize: 23, fontWeight: '600', fontVariant: ['tabular-nums'] }}>{value}</Text>
      </View>)}
    </View>
  </View>;
}

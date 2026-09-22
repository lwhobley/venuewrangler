import { Pressable, Text, View } from 'react-native';
import { EmptyState } from '../design-system';
import { colors, spacing } from '../../lib/theme';
import { calendarSegmentsForDay, type CalendarShift } from '../../lib/schedule-segments';

export type AgendaShift = CalendarShift & {
  memberName: string | null;
  jobTitle: string;
  station: string;
  profileId: string | null;
  conflict: boolean;
};

type Props<T extends AgendaShift> = {
  shifts: T[];
  carryInShifts: T[];
  days: { label: string; date: string; today: boolean }[];
  selectedDay: number;
  onDayChange: (day: number) => void;
  onSelect: (shift: T) => void;
  onCreate: (day: number) => void;
};

function time(minutes: number) {
  if (minutes === 1440) return 'Midnight';
  const hour = Math.floor(minutes / 60) % 24;
  return `${hour % 12 || 12}:${String(minutes % 60).padStart(2, '0')} ${hour >= 12 ? 'PM' : 'AM'}`;
}

/** A day at a time, with overnight coverage split by the same helper as the grid. */
export function ShiftAgenda<T extends AgendaShift>({ shifts, carryInShifts, days, selectedDay, onDayChange, onSelect, onCreate }: Props<T>) {
  const rows = calendarSegmentsForDay(shifts, carryInShifts, selectedDay)
    .sort((a, b) => a.renderStart - b.renderStart || (a.memberName ?? '').localeCompare(b.memberName ?? ''));

  return <View style={{ gap: spacing.lg }}>
    <View style={{ flexDirection: 'row', gap: 3 }}>
      {days.map((day, index) => {
        const selected = index === selectedDay;
        return <Pressable key={day.label} accessibilityRole="tab" accessibilityLabel={`${day.label} ${day.date}${day.today ? ', today' : ''}`} accessibilityState={{ selected }} onPress={() => onDayChange(index)} style={({ pressed }) => ({ flex: 1, minHeight: 72, justifyContent: 'center', alignItems: 'center', gap: 5, borderRadius: 10, backgroundColor: selected ? colors.primary : colors.surface, opacity: pressed ? 0.7 : 1 })}>
          <Text style={{ color: selected ? colors.buttonText : colors.muted, fontSize: 11, fontWeight: '600' }}>{day.label}</Text>
          <Text style={{ color: selected ? colors.buttonText : colors.charcoal, fontSize: 19, fontWeight: '700', fontVariant: ['tabular-nums'] }}>{day.date}</Text>
          <View style={{ width: 4, height: 4, borderRadius: 2, backgroundColor: day.today ? selected ? colors.buttonText : colors.primary : 'transparent' }} />
        </Pressable>;
      })}
    </View>
    <View style={{ flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', gap: 12 }}>
      <View style={{ flex: 1 }}>
        <Text style={{ color: colors.charcoal, fontSize: 18, fontWeight: '700' }}>{days[selectedDay]?.today ? 'Today’s coverage' : `${days[selectedDay]?.label} coverage`}</Text>
        <Text style={{ color: colors.muted, fontSize: 12, marginTop: 4 }}>{rows.length} {rows.length === 1 ? 'shift' : 'shifts'} scheduled</Text>
      </View>
      <Pressable accessibilityRole="button" accessibilityLabel="Add shift for selected day" onPress={() => onCreate(selectedDay)} style={({ pressed }) => ({ minHeight: 44, paddingHorizontal: 14, justifyContent: 'center', borderRadius: 8, backgroundColor: colors.surfaceSoft, opacity: pressed ? 0.7 : 1 })}>
        <Text style={{ color: colors.primary, fontSize: 13, fontWeight: '700' }}>+ Add shift</Text>
      </Pressable>
    </View>
    <View style={{ backgroundColor: colors.surface, borderRadius: 12, borderWidth: 1, borderColor: colors.border, overflow: 'hidden' }}>
      {rows.length ? rows.map((shift, index) => {
        const carryIn = shift.segmentKey.endsWith(':carry-in');
        const continuation = carryIn || shift.segmentKey.endsWith(':spill');
        const open = !shift.profileId;
        const signal = shift.conflict ? colors.danger : open ? colors.warning : colors.primary;
        return <Pressable key={shift.segmentKey} disabled={carryIn} accessibilityRole={carryIn ? undefined : 'button'} accessibilityLabel={`${shift.memberName ?? 'Open shift'}, ${shift.jobTitle}, ${time(shift.renderStart)} to ${time(shift.renderEnd)}${carryIn ? ', from previous week' : ''}`} onPress={() => onSelect(shift)} style={({ pressed }) => ({ padding: spacing.lg, gap: spacing.sm, borderTopWidth: index ? 1 : 0, borderColor: colors.divider, opacity: pressed ? 0.7 : 1 })}>
          <View style={{ flexDirection: 'row', gap: 12, alignItems: 'center' }}>
            <View style={{ width: 36, height: 36, borderRadius: 10, backgroundColor: colors.surfaceSoft, alignItems: 'center', justifyContent: 'center' }}>
              <Text style={{ color: signal, fontSize: 12, fontWeight: '700' }}>{open ? '+' : (shift.memberName ?? '').split(/\s+/).filter(Boolean).slice(0, 2).map((part) => part[0]).join('')}</Text>
            </View>
            <View style={{ flex: 1, gap: 3 }}>
              <Text style={{ fontSize: 15, fontWeight: '700', color: colors.charcoal }}>{shift.memberName ?? 'Open shift'}</Text>
              <Text style={{ fontSize: 12, color: colors.muted }}>{[shift.jobTitle, shift.station].filter(Boolean).join(' · ')}</Text>
            </View>
            {!carryIn ? <Text style={{ fontSize: 22, color: colors.muted }}>›</Text> : null}
          </View>
          <View style={{ gap: 4, paddingLeft: 48 }}>
            <Text style={{ color: colors.charcoal, fontSize: 13, fontWeight: '600', fontVariant: ['tabular-nums'] }}>{time(shift.renderStart)} – {time(shift.renderEnd)}</Text>
            {continuation ? <Text style={{ color: colors.muted, fontSize: 12 }}>{carryIn ? 'Continues from previous week' : 'Continues from yesterday'}</Text> : null}
            {shift.conflict || open ? <Text style={{ color: signal, fontSize: 12, fontWeight: '700' }}>{shift.conflict ? 'Scheduling conflict' : 'Needs assignment'}</Text> : null}
          </View>
        </Pressable>;
      }) : <EmptyState title="No coverage yet" detail="Add the first shift for this day." actionLabel="Add shift" onAction={() => onCreate(selectedDay)} />}
    </View>
  </View>;
}

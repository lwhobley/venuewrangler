import { useMemo, useState } from 'react';
import { View } from 'react-native';
import { Button, Menu, Text } from 'react-native-paper';
import { zonedDayIndex, zonedIsoDate, zonedDateTimeMs } from '../lib/zoned-datetime';
import { colors, spacing } from '../lib/theme';

export type DatePreset = {
  key: string;
  label: string;        // full label shown in menu
  shortLabel: string;   // compact label shown on the button
  days: number;         // window size for backend queries that take windowDays
  startDate: string;    // YYYY-MM-DD
  endDate: string;      // YYYY-MM-DD
  startTs: number;      // ms timestamp — start of startDate (midnight in venue timeZone)
  endTs: number;        // ms timestamp — end of endDate (23:59:59 in venue timeZone)
};

function pad(n: number) {
  return n.toString().padStart(2, '0');
}

export function buildPresets(timeZone?: string | null): DatePreset[] {
  const now = new Date();
  const todayIso = zonedIsoDate(timeZone, now);
  const [year, month, day] = todayIso.split('-').map(Number);
  const dayOfWeek = zonedDayIndex(timeZone, now);

  const dateFromDelta = (daysAgo: number) => {
    const ms = Date.UTC(year, month - 1, day - daysAgo);
    const d = new Date(ms);
    return `${d.getUTCFullYear()}-${pad(d.getUTCMonth() + 1)}-${pad(d.getUTCDate())}`;
  };

  const yesterdayIso = dateFromDelta(1);
  const weekStartIso = dateFromDelta(dayOfWeek);
  const last7Iso = dateFromDelta(6);
  const last30Iso = dateFromDelta(29);
  const monthStartIso = `${year}-${pad(month)}-01`;

  const startTs = (dateStr: string) => {
    const ms = zonedDateTimeMs(dateStr, '00:00', timeZone);
    if (Number.isFinite(ms)) return ms;
    const [y, m, d] = dateStr.split('-').map(Number);
    return new Date(y, m - 1, d).getTime();
  };
  const endTs = (dateStr: string) => {
    const ms = zonedDateTimeMs(dateStr, '23:59', timeZone);
    if (Number.isFinite(ms)) return ms + 59999;
    const [y, m, d] = dateStr.split('-').map(Number);
    return new Date(y, m - 1, d, 23, 59, 59, 999).getTime();
  };

  const fmt = (dateStr: string) => {
    const [y, m, d] = dateStr.split('-').map(Number);
    const dt = new Date(Date.UTC(y, m - 1, d));
    return dt.toLocaleDateString('en-US', { timeZone: 'UTC', month: 'short', day: 'numeric' });
  };
  const monthName = new Date(Date.UTC(year, month - 1, 1)).toLocaleDateString('en-US', { timeZone: 'UTC', month: 'long' });

  const todayFmt = fmt(todayIso);

  return [
    {
      key: 'today',
      label: `Today · ${todayFmt}`,
      shortLabel: `Today · ${todayFmt}`,
      days: 1,
      startDate: todayIso,
      endDate: todayIso,
      startTs: startTs(todayIso),
      endTs: endTs(todayIso),
    },
    {
      key: 'yesterday',
      label: `Yesterday · ${fmt(yesterdayIso)}`,
      shortLabel: `Yesterday · ${fmt(yesterdayIso)}`,
      days: 1,
      startDate: yesterdayIso,
      endDate: yesterdayIso,
      startTs: startTs(yesterdayIso),
      endTs: endTs(yesterdayIso),
    },
    {
      key: 'this_week',
      label: `This week · ${fmt(weekStartIso)}–${todayFmt}`,
      shortLabel: `This week`,
      days: dayOfWeek + 1 || 7,
      startDate: weekStartIso,
      endDate: todayIso,
      startTs: startTs(weekStartIso),
      endTs: endTs(todayIso),
    },
    {
      key: 'last_7',
      label: `Last 7 days · ${fmt(last7Iso)}–${todayFmt}`,
      shortLabel: 'Last 7 days',
      days: 7,
      startDate: last7Iso,
      endDate: todayIso,
      startTs: startTs(last7Iso),
      endTs: endTs(todayIso),
    },
    {
      key: 'last_30',
      label: `Last 30 days · ${fmt(last30Iso)}–${todayFmt}`,
      shortLabel: 'Last 30 days',
      days: 30,
      startDate: last30Iso,
      endDate: todayIso,
      startTs: startTs(last30Iso),
      endTs: endTs(todayIso),
    },
    {
      key: 'this_month',
      label: `This month · ${monthName}`,
      shortLabel: monthName,
      days: day,
      startDate: monthStartIso,
      endDate: todayIso,
      startTs: startTs(monthStartIso),
      endTs: endTs(todayIso),
    },
  ];
}

/** Hook that owns the selected preset. Presets refresh each calendar day in the venue's timezone. */
export function useDateRange(defaultKey = 'today', timeZone?: string | null) {
  const todayStr = zonedIsoDate(timeZone);
  const presets = useMemo(() => buildPresets(timeZone), [todayStr, timeZone]);
  const [selected, setSelected] = useState<DatePreset>(
    () => presets.find((p) => p.key === defaultKey) ?? presets[0],
  );
  const [lastToday, setLastToday] = useState(todayStr);
  const [lastZone, setLastZone] = useState(timeZone);
  if (lastToday !== todayStr || lastZone !== timeZone) {
    setLastToday(todayStr);
    setLastZone(timeZone);
    setSelected(presets.find((p) => p.key === selected.key) ?? presets[0]);
  }
  return { selected, setSelected, presets };
}

type Props = {
  selected: DatePreset;
  presets: DatePreset[];
  onSelect: (preset: DatePreset) => void;
};

export function DateRangeBar({ selected, presets, onSelect }: Props) {
  const [open, setOpen] = useState(false);

  return (
    <View style={{ flexDirection: 'row', alignItems: 'center', gap: spacing.sm, flexWrap: 'wrap', flexShrink: 1 }}>
      <Menu
        visible={open}
        onDismiss={() => setOpen(false)}
        anchor={
          <Button
            compact
            mode="outlined"
            icon="calendar-range"
            textColor={colors.primary}
            onPress={() => setOpen(true)}
          >
            {selected.shortLabel}
          </Button>
        }
      >
        {presets.map((preset) => (
          <Menu.Item
            key={preset.key}
            title={preset.label}
            leadingIcon={selected.key === preset.key ? 'check' : 'circle-outline'}
            onPress={() => {
              onSelect(preset);
              setOpen(false);
            }}
          />
        ))}
      </Menu>
      {selected.startDate !== selected.endDate ? (
        <Text style={{ color: colors.muted, fontSize: 12, flexShrink: 1 }}>
          {selected.startDate} – {selected.endDate}
        </Text>
      ) : null}
    </View>
  );
}

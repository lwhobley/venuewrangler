import type { ReactNode } from 'react';
import { Pressable, ScrollView, View } from 'react-native';
import { Text } from 'react-native-paper';
import { Skeleton } from './Skeleton';

const fallbackColors = {
  muted: '#777',
  charcoal: '#222',
  background: '#fff',
  surface: '#fff',
  border: '#ddd',
  divider: '#eee',
  primary: '#333',
  buttonText: '#fff',
  surfaceSoft: '#f4f4f4',
  cream: '#f7f3ea',
  success: '#2a2',
  warning: '#a80',
  danger: '#c33',
};

const fallbackSpacing = { lg: 24, md: 16, sm: 8, xxl: 48 };

function readTheme(key: string) {
  try {
    return require('../lib/theme')[key];
  } catch {
    return undefined;
  }
}

function tokens() {
  const colors = { ...fallbackColors, ...(readTheme('colors') ?? {}) };
  const spacing = { ...fallbackSpacing, ...(readTheme('spacing') ?? {}) };
  const display = readTheme('fontFamily')?.display as string | undefined;
  return { colors, spacing, display };
}

type IconName = string;

function Icon({ name, size, color }: { name: IconName; size: number; color: string }) {
  try {
    const Icons = require('@expo/vector-icons').MaterialCommunityIcons;
    return <Icons name={name} size={size} color={color} />;
  } catch {
    return null;
  }
}

function tap() {
  try {
    const platform = require('react-native').Platform?.OS;
    if (!platform || platform === 'web') return;
    void require('expo-haptics').selectionAsync()?.catch(() => undefined);
  } catch {
    return;
  }
}

export function ScreenShell({ children }: { children: ReactNode }) {
  const { colors, spacing } = tokens();
  return (
    <ScrollView style={{ flex: 1, backgroundColor: colors.background }} contentContainerStyle={{ padding: spacing.lg, gap: spacing.lg, paddingBottom: spacing.xxl }}>
      {children}
    </ScrollView>
  );
}

export function PageHeader({ kicker, title, detail, action }: { kicker?: string; title: string; detail?: string; action?: ReactNode }) {
  const { colors, spacing, display } = tokens();
  return (
    <View style={{ flexDirection: 'row', alignItems: 'flex-end', justifyContent: 'space-between', gap: spacing.md }}>
      <View style={{ flex: 1, gap: 4 }}>
        {kicker ? <Text style={{ color: colors.muted, fontSize: 12, fontWeight: '600', letterSpacing: 0.6 }}>{kicker}</Text> : null}
        <Text style={{ color: colors.charcoal, fontFamily: display, fontSize: 34, lineHeight: 40 }}>{title}</Text>
        {detail ? <Text style={{ color: colors.muted, fontSize: 15, lineHeight: 22 }}>{detail}</Text> : null}
      </View>
      {action}
    </View>
  );
}

export function Section({ title, action, children }: { title: string; action?: ReactNode; children: ReactNode }) {
  const { colors, spacing } = tokens();
  return (
    <View style={{ gap: spacing.sm }}>
      <View style={{ flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', gap: spacing.sm }}>
        <Text style={{ color: colors.charcoal, fontSize: 18, fontWeight: '700' }}>{title}</Text>
        {action}
      </View>
      <View style={{ backgroundColor: colors.surface, borderRadius: 12, borderWidth: 1, borderColor: colors.border, overflow: 'hidden' }}>
        {children}
      </View>
    </View>
  );
}

export function Metric({ label, value }: { label: string; value: string }) {
  const { colors, spacing } = tokens();
  return (
    <View style={{ flex: 1, paddingHorizontal: spacing.sm, paddingVertical: spacing.md, gap: 4 }}>
      <Text style={{ color: colors.muted, fontSize: 12 }}>{label}</Text>
      <Text style={{ color: colors.charcoal, fontSize: 22, fontWeight: '700', fontVariant: ['tabular-nums'] }}>{value}</Text>
    </View>
  );
}

export function ListRow({ title, detail, trailing, onPress }: { title: string; detail?: string; trailing?: ReactNode; onPress?: () => void }) {
  const { colors, spacing } = tokens();
  const body = (
    <View style={{ flexDirection: 'row', alignItems: 'center', gap: spacing.md, padding: spacing.lg, borderBottomWidth: 1, borderBottomColor: colors.divider }}>
      <View style={{ flex: 1, gap: 3 }}>
        <Text style={{ color: colors.charcoal, fontSize: 15, fontWeight: '700' }}>{title}</Text>
        {detail ? <Text style={{ color: colors.muted, fontSize: 13 }}>{detail}</Text> : null}
      </View>
      {trailing}
    </View>
  );
  if (!onPress) return body;
  return <Pressable accessibilityRole="button" onPress={() => { tap(); onPress(); }} style={({ pressed }) => ({ opacity: pressed ? 0.7 : 1 })}>{body}</Pressable>;
}

export function ActionButton({ label, onPress, tone = 'primary' }: { label: string; onPress: () => void; tone?: 'primary' | 'quiet' }) {
  const { colors } = tokens();
  const filled = tone === 'primary';
  return (
    <Pressable
      accessibilityRole="button"
      accessibilityLabel={label}
      onPress={() => { tap(); onPress(); }}
      style={({ pressed }) => ({
        alignSelf: 'flex-start',
        minHeight: 44,
        justifyContent: 'center',
        paddingHorizontal: 14,
        borderRadius: 8,
        backgroundColor: filled ? colors.primary : colors.surfaceSoft,
        opacity: pressed ? 0.7 : 1,
      })}
    >
      <Text style={{ color: filled ? colors.buttonText : colors.primary, fontSize: 14, fontWeight: '700' }}>{label}</Text>
    </Pressable>
  );
}

export function StatusBadge({ label, tone = 'neutral' }: { label: string; tone?: 'neutral' | 'ok' | 'watch' | 'danger' }) {
  const { colors } = tokens();
  const color = tone === 'ok' ? colors.success : tone === 'watch' ? colors.warning : tone === 'danger' ? colors.danger : colors.muted;
  return (
    <View style={{ flexDirection: 'row', alignItems: 'center', gap: 6, backgroundColor: colors.cream, paddingHorizontal: 10, paddingVertical: 5, borderRadius: 999 }}>
      <View style={{ width: 6, height: 6, borderRadius: 3, backgroundColor: color }} />
      <Text style={{ color: colors.charcoal, fontSize: 12, fontWeight: '700' }}>{label}</Text>
    </View>
  );
}

export function EmptyState({ title, detail, actionLabel, onAction }: { title: string; detail?: string; actionLabel?: string; onAction?: () => void }) {
  const { colors, spacing } = tokens();
  return (
    <View style={{ padding: spacing.lg, gap: spacing.sm }}>
      <Text style={{ color: colors.charcoal, fontSize: 16, fontWeight: '700' }}>{title}</Text>
      {detail ? <Text style={{ color: colors.muted, fontSize: 14, lineHeight: 20 }}>{detail}</Text> : null}
      {actionLabel && onAction ? <ActionButton label={actionLabel} onPress={onAction} tone="quiet" /> : null}
    </View>
  );
}

export function IconWell({ name }: { name: IconName }) {
  const { colors } = tokens();
  return (
    <View style={{ width: 36, height: 36, borderRadius: 10, backgroundColor: colors.surfaceSoft, alignItems: 'center', justifyContent: 'center' }}>
      <Icon name={name} size={18} color={colors.primary} />
    </View>
  );
}

export function RowSkeleton() {
  const { spacing } = tokens();
  return <View style={{ padding: spacing.lg, gap: 8 }}><Skeleton width="46%" height={14} /><Skeleton width="72%" height={12} /></View>;
}

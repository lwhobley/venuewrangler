import { ReactNode } from 'react';
import { Pressable, StyleProp, Text, TextStyle, View, ViewStyle } from 'react-native';
import { MaterialCommunityIcons } from '@expo/vector-icons';
import { DesignPalette, radius, spacing } from '../lib/theme';

type IconName = keyof typeof MaterialCommunityIcons.glyphMap;
type CommandTextVariant = 'hero' | 'title' | 'label' | 'body' | 'caption' | 'metric';

// Filled surfaces provide separation without a thin outline around each block.
export function CommandSurface({
  palette,
  children,
  style,
  strong,
  inset,
}: {
  palette: DesignPalette;
  children: ReactNode;
  style?: StyleProp<ViewStyle>;
  strong?: boolean;
  inset?: boolean;
}) {
  return (
    <View
      style={[
        {
          backgroundColor: strong ? palette.surfaceStrong : inset ? palette.surfaceSoft : palette.surface,
          borderWidth: 0,
          borderColor: palette.border,
          borderRadius: strong ? radius.soft : radius.sharp,
          padding: inset ? spacing.md : spacing.lg,
          overflow: 'hidden',
          ...(strong
            ? {
                shadowColor: palette.shadow,
                shadowOpacity: 0.04,
                shadowRadius: 12,
                shadowOffset: { width: 0, height: 3 },
                elevation: 2,
              }
            : {}),
        },
        style,
      ]}
    >
      {children}
    </View>
  );
}

export function CommandText({
  palette,
  children,
  variant = 'body',
  style,
}: {
  palette: DesignPalette;
  children: ReactNode;
  variant?: CommandTextVariant;
  style?: StyleProp<TextStyle>;
}) {
  const styles: Record<CommandTextVariant, TextStyle> = {
    hero: { color: palette.charcoal, fontSize: 30, lineHeight: 36, letterSpacing: -0.5, fontWeight: '800' },
    title: { color: palette.charcoal, fontSize: 19, lineHeight: 25, letterSpacing: -0.2, fontWeight: '700' },
    label: { color: palette.muted, fontSize: 11, lineHeight: 15, fontWeight: '700', letterSpacing: 0.6, textTransform: 'uppercase' },
    body: { color: palette.charcoal, fontSize: 14, lineHeight: 20, fontWeight: '500' },
    caption: { color: palette.muted, fontSize: 12, lineHeight: 17, fontWeight: '500' },
    metric: { color: palette.charcoal, fontSize: 28, lineHeight: 33, letterSpacing: -0.4, fontWeight: '700' },
  };

  return <Text style={[styles[variant], style]}>{children}</Text>;
}

// Compact, raised controls share the Olive Ledger selection color.
export function CommandButton({
  palette,
  children,
  icon,
  selected,
  onPress,
  style,
  accessibilityLabel,
  disabled,
}: {
  palette: DesignPalette;
  children: ReactNode;
  icon?: IconName;
  selected?: boolean;
  onPress?: () => void;
  style?: StyleProp<ViewStyle>;
  accessibilityLabel?: string;
  disabled?: boolean;
}) {
  return (
    <Pressable
      accessibilityRole="button"
      accessibilityLabel={accessibilityLabel}
      accessibilityState={{ ...(selected ? { selected: true } : {}), ...(disabled ? { disabled: true } : {}) }}
      disabled={disabled}
      onPress={onPress}
      style={({ pressed }) => [
        {
          minHeight: 44,
          paddingHorizontal: 12,
          paddingVertical: 7,
          borderRadius: radius.sharp,
          borderWidth: 0,
          borderColor: palette.border,
          backgroundColor: selected ? palette.primary : palette.surfaceSoft,
          shadowColor: palette.shadow,
          shadowOpacity: pressed || disabled ? 0 : 0.1,
          shadowRadius: 4,
          shadowOffset: { width: 0, height: 2 },
          elevation: pressed || disabled ? 0 : 2,
          flexDirection: 'row',
          alignItems: 'center',
          justifyContent: 'center',
          gap: 8,
          opacity: disabled ? 0.5 : pressed ? 0.7 : 1,
        },
        style,
      ]}
    >
      {icon ? <MaterialCommunityIcons name={icon} size={15} color={selected ? palette.buttonText : palette.muted} /> : null}
      <Text
        numberOfLines={1}
        style={{
          color: selected ? palette.buttonText : palette.charcoal,
          fontSize: 12,
          fontWeight: '600',
        }}
      >
        {children}
      </Text>
    </Pressable>
  );
}

// A tag, not a pill: sharp corners, a colored left bar carries the tone
// instead of a filled colored background.
export function StatusPill({
  palette,
  children,
  tone = 'neutral',
}: {
  palette: DesignPalette;
  children: ReactNode;
  tone?: 'neutral' | 'good' | 'warn' | 'danger';
}) {
  const toneColor = tone === 'good' ? palette.success : tone === 'warn' ? palette.warning : tone === 'danger' ? palette.danger : palette.primary;
  return (
    <View
      style={{
        borderLeftWidth: 2,
        borderLeftColor: toneColor,
        borderRadius: radius.sharp,
        backgroundColor: palette.surfaceSoft,
        paddingHorizontal: 8,
        paddingVertical: 4,
        alignSelf: 'flex-start',
      }}
    >
      <Text numberOfLines={1} style={{ color: toneColor, fontSize: 11, fontWeight: '700' }}>
        {children}
      </Text>
    </View>
  );
}

export function MiniTrend({ palette, values }: { palette: DesignPalette; values: number[] }) {
  const max = Math.max(...values, 1);
  return (
    <View style={{ flexDirection: 'row', alignItems: 'flex-end', gap: 4, height: 34 }}>
      {values.map((value, index) => (
        <View
          key={`${value}-${index}`}
          style={{
            width: 5,
            height: Math.max(6, (value / max) * 34),
            backgroundColor: index === values.length - 1 ? palette.primary : `${palette.primary}44`,
          }}
        />
      ))}
    </View>
  );
}

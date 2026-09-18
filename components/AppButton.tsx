import { useState } from 'react';
import { Platform, type ViewStyle } from 'react-native';
import { Button as PaperButton, type ButtonProps } from 'react-native-paper';
import { radius, useDesignTheme } from '../lib/theme';

/** Raised controls retain Paper's loading, accessibility, icon and touch behavior. */
export function Button({ style, contentStyle, labelStyle, onPressIn, onPressOut, ...props }: ButtonProps) {
  const palette = useDesignTheme();
  const [pressed, setPressed] = useState(false);
  const raised = props.mode !== undefined && props.mode !== 'text';
  const active = pressed && !props.disabled;
  const glow = typeof props.buttonColor === 'string' ? props.buttonColor : palette.primary;
  const elevation: ViewStyle = raised && !props.disabled ? {
    shadowColor: active ? glow : palette.shadow,
    shadowOpacity: active ? 0.48 : 0.18,
    shadowRadius: active ? 18 : 8,
    shadowOffset: { width: 0, height: active ? 2 : 5 },
    elevation: active ? 8 : 4,
    ...(Platform.OS === 'web' ? {
      boxShadow: active ? `0 0 18px ${glow}, 0 2px 4px ${palette.shadow}22` : `0 5px 12px ${palette.shadow}25`,
    } : {}),
  } : {};
  return <PaperButton
    {...props}
    onPressIn={(event) => { setPressed(true); onPressIn?.(event); }}
    onPressOut={(event) => { setPressed(false); onPressOut?.(event); }}
    style={[style, { borderRadius: radius.pill }, elevation]}
    contentStyle={[{ minHeight: props.compact ? 44 : raised ? 52 : 44 }, contentStyle]}
    labelStyle={[{ fontWeight: '700', letterSpacing: 0.15 }, labelStyle]}
  />;
}

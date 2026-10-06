import { MD3DarkTheme, MD3LightTheme } from 'react-native-paper';
import { create } from 'zustand';

type ThemeMode = 'dark' | 'light';

type AppearanceState = {
  mode: ThemeMode;
  setMode: (mode: ThemeMode) => void;
  toggleMode: () => void;
};

export const useAppearanceStore = create<AppearanceState>((set) => ({
  mode: 'light',
  setMode: (mode) => set({ mode }),
  toggleMode: () => set((state) => ({ mode: state.mode === 'dark' ? 'light' : 'dark' })),
}));

export const designPalettes = {
  dark: {
    mode: 'dark' as const,
    background: '#0D2430',
    backgroundAlt: '#112D3C',
    surface: '#173545',
    surfaceStrong: '#1D4052',
    surfaceSoft: '#23495A',
    glass: '#173545',
    primary: '#79C1D4',
    secondary: '#E4B976',
    charcoal: '#F5F9FA',
    muted: '#BACBD3',
    border: '#335466',
    divider: '#2B4A5B',
    success: '#82D2AB',
    danger: '#F08F8D',
    warning: '#E4B976',
    info: '#79C1D4',
    cream: '#23495A',
    glow: '#285C70',
    shadow: '#000000',
    // Text/icons drawn on top of `primary` fills (light-green in dark mode).
    buttonText: '#0D2430',
  },
  light: {
    mode: 'light' as const,
    background: '#F3F6F7',
    backgroundAlt: '#FFFFFF',
    surface: '#FFFFFF',
    surfaceStrong: '#FFFFFF',
    surfaceSoft: '#E9F0F3',
    glass: 'rgba(255, 255, 255, 0.94)',
    primary: '#194A62',
    secondary: '#9B6638',
    charcoal: '#18313E',
    muted: '#607582',
    border: '#D8E2E7',
    divider: '#E4EBEF',
    success: '#258060',
    danger: '#BA4C49',
    warning: '#A86B32',
    info: '#287995',
    cream: '#E9F0F3',
    glow: '#C9E9F2',
    shadow: '#173747',
    // Text/icons drawn on top of `primary` fills (dark-green in light mode).
    buttonText: '#FFFFFF',
  },
} as const;

export type DesignPalette = (typeof designPalettes)[ThemeMode];

export const useDesignTheme = () => {
  const mode = useAppearanceStore((state) => state.mode);
  return designPalettes[mode];
};

export const colors = designPalettes.light;

export const authColors = {
  background: colors.background,
  surface: colors.surface,
  primary: colors.primary,
  text: colors.charcoal,
  muted: colors.muted,
  border: colors.border,
  danger: colors.danger,
  success: colors.success,
  buttonText: colors.buttonText,
  highlight: colors.cream,
};

export const authInputProps = {
  outlineColor: authColors.border,
  activeOutlineColor: authColors.primary,
  textColor: authColors.text,
  placeholderTextColor: authColors.muted,
  style: { backgroundColor: authColors.surface },
};

export const accents = [
  { bg: colors.cream, fg: colors.charcoal, icon: colors.primary },
  { bg: '#FFF3E4', fg: '#7D501F', icon: '#A86B32' },
  { bg: '#E9F6F0', fg: '#1B704F', icon: '#258060' },
  { bg: '#EAF3F8', fg: '#245F78', icon: '#287995' },
  { bg: '#FFF0E7', fg: '#8A522B', icon: '#B8773C' },
  { bg: '#FCEDEC', fg: '#9E3D3C', icon: '#BA4C49' },
] as const;

export const spacing = {
  xs: 4,
  sm: 8,
  md: 12,
  lg: 16,
  xl: 24,
  xxl: 32,
  xxxl: 48,
  huge: 64,
};

// Compact controls and clean panels keep operational lists easy to scan.
export const radius = {
  sharp: 12,
  soft: 8,
  sm: 4,
  md: 8,
  lg: 12,
  xl: 16,
  pill: 9999,
};

// Legacy display font remains available for brand artwork; app screens use
// the same legible sans hierarchy as operational data.
export const fontFamily = {
  // Loaded once in app/_layout.tsx. Fraunces is intentionally reserved for
  // identity moments and page titles; operational data stays in the native
  // sans so dense screens remain quick to scan.
  display: 'Fraunces_600SemiBold',
  displayItalic: 'Fraunces_600SemiBold_Italic',
  displayMedium: 'Fraunces_500Medium',
} as const;

export const type = {
  micro: { fontSize: 12, lineHeight: 16, letterSpacing: 0.2 },
  label: { fontSize: 13, lineHeight: 18, letterSpacing: 0.4 },
  subtitle: { fontSize: 14, lineHeight: 20, letterSpacing: 0.1 },
  body: { fontSize: 15, lineHeight: 22, letterSpacing: 0 },
  bodyLarge: { fontSize: 17, lineHeight: 24, letterSpacing: 0 },
  heading: { fontSize: 20, lineHeight: 26, letterSpacing: -0.2, fontWeight: '700' },
  title: { fontSize: 30, lineHeight: 36, letterSpacing: -0.6, fontWeight: '700' },
  display: { fontSize: 42, lineHeight: 46, letterSpacing: -0.9, fontWeight: '700' },
} as const;

// Contemporary ambient diffusion shadow for elevated cards and floating sheets.
export const shadow = {
  shadowColor: designPalettes.light.shadow,
  shadowOpacity: 0.04,
  shadowRadius: 16,
  shadowOffset: { width: 0, height: 4 },
  elevation: 2,
} as const;

export const authCardStyle = {
  backgroundColor: authColors.surface,
  borderRadius: radius.soft,
  borderWidth: 1,
  borderColor: authColors.border,
} as const;

export const glass = {
  backgroundColor: designPalettes.light.glass,
  borderWidth: 1,
  borderColor: designPalettes.light.border,
  backdropFilter: 'blur(20px)',
  WebkitBackdropFilter: 'blur(20px)',
} as const;

export const makePaperTheme = (mode: ThemeMode) => {
  const palette = designPalettes[mode];
  const base = mode === 'dark' ? MD3DarkTheme : MD3LightTheme;

  return {
    ...base,
    dark: mode === 'dark',
    roundness: 12,
    colors: {
      ...base.colors,
      primary: palette.primary,
      onPrimary: palette.buttonText,
      primaryContainer: palette.cream,
      onPrimaryContainer: palette.charcoal,
      secondary: palette.secondary,
      onSecondary: palette.buttonText,
      secondaryContainer: palette.surfaceSoft,
      onSecondaryContainer: palette.charcoal,
      tertiary: palette.info,
      onTertiary: palette.buttonText,
      tertiaryContainer: palette.surfaceSoft,
      onTertiaryContainer: palette.charcoal,
      background: palette.background,
      surface: palette.surfaceStrong,
      onSurface: palette.charcoal,
      surfaceVariant: palette.surfaceSoft,
      onSurfaceVariant: palette.muted,
      onBackground: palette.charcoal,
      outline: palette.border,
      outlineVariant: palette.divider,
      error: palette.danger,
      elevation: {
        ...base.colors.elevation,
        level1: palette.surface,
        level2: palette.surfaceSoft,
        level3: palette.surfaceStrong,
        level4: palette.surfaceStrong,
        level5: palette.surfaceStrong,
      },
    },
  };
};

export const lightTheme = makePaperTheme('light');
export const darkTheme = makePaperTheme('dark');

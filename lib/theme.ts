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
    background: '#172019',
    backgroundAlt: '#1D2820',
    surface: '#1D2820',
    surfaceStrong: '#243026',
    surfaceSoft: '#2A382D',
    glass: '#1D2820',
    primary: '#7ECA98',
    secondary: '#E1A853',
    charcoal: '#F7F7F4',
    muted: '#B8C2BA',
    border: '#3A493D',
    divider: '#334136',
    success: '#7ECA98',
    danger: '#F09A90',
    warning: '#E1A853',
    info: '#9FC8DB',
    cream: '#283B2D',
    glow: '#283B2D',
    shadow: '#000000',
    // Text/icons drawn on top of `primary` fills (light-green in dark mode).
    buttonText: '#172019',
  },
  light: {
    mode: 'light' as const,
    background: '#F8F8F5',
    backgroundAlt: '#FFFFFF',
    surface: '#FFFFFF',
    surfaceStrong: '#FFFFFF',
    surfaceSoft: '#F2F3EF',
    glass: 'rgba(255, 255, 255, 0.92)',
    primary: '#17643B',
    secondary: '#C59B27',
    charcoal: '#1A201C',
    muted: '#667068',
    border: '#E1E4DE',
    divider: '#ECEFEA',
    success: '#17643B',
    danger: '#BA4439',
    warning: '#C59B27',
    info: '#3B6B82',
    cream: '#F3F6F1',
    glow: '#E8EFEA',
    shadow: '#3C443E',
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
  buttonText: '#FFFFFF',
  highlight: '#F0F7F2',
};

export const authInputProps = {
  outlineColor: authColors.border,
  activeOutlineColor: authColors.primary,
  textColor: authColors.text,
  placeholderTextColor: authColors.muted,
  style: { backgroundColor: authColors.surface },
};

export const accents = [
  { bg: '#EEF5F0', fg: '#1A201C', icon: '#17643B' },
  { bg: '#FFF7E6', fg: '#1A201C', icon: '#C59B27' },
  { bg: '#EEF3F7', fg: '#1A201C', icon: '#3B6B82' },
  { bg: '#F8EEE8', fg: '#1A201C', icon: '#A35E35' },
  { bg: '#F0F1E9', fg: '#1A201C', icon: '#63705A' },
  { bg: '#FBEDEC', fg: '#1A201C', icon: '#BA4439' },
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

// Editorial system rule: at most two radii anywhere in the UI. `sharp` is for
// Contemporary system rule: subtle architectural radius for panels, cards, and controls.
// `sharp` gives controls a subtle refined contour; `soft` provides elegant
// contemporary card curvature as shown in the architectural renderings.
export const radius = {
  sharp: 6,
  soft: 12,
  sm: 4,
  md: 8,
  lg: 12,
  xl: 16,
  pill: 9999,
};

// The command system uses native-feeling sans typography throughout. It keeps
// dense, data-backed screens legible and avoids a different type personality
// on every tab.
export const fontFamily = {
  display: undefined,
  displayItalic: undefined,
  displayMedium: undefined,
} as const;

export const type = {
  micro: { fontSize: 12, lineHeight: 16, letterSpacing: 0.2 },
  label: { fontSize: 13, lineHeight: 18, letterSpacing: 0.4 },
  subtitle: { fontSize: 14, lineHeight: 20, letterSpacing: 0.1 },
  body: { fontSize: 15, lineHeight: 22, letterSpacing: 0 },
  bodyLarge: { fontSize: 17, lineHeight: 24, letterSpacing: 0 },
  heading: { fontSize: 20, lineHeight: 26, letterSpacing: -0.2, fontWeight: '700' },
  title: { fontSize: 28, lineHeight: 34, letterSpacing: -0.4, fontWeight: '700' },
  display: { fontSize: 40, lineHeight: 44, letterSpacing: -0.6, fontWeight: '700' },
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
    roundness: radius.sharp,
    colors: {
      ...base.colors,
      primary: palette.primary,
      secondary: palette.secondary,
      background: palette.background,
      surface: palette.surfaceStrong,
      onSurface: palette.charcoal,
      onBackground: palette.charcoal,
      outline: palette.border,
      error: palette.danger,
      elevation: {
        ...base.colors.elevation,
        level1: palette.surface,
        level2: palette.surfaceSoft,
      },
    },
  };
};

export const lightTheme = makePaperTheme('light');
export const darkTheme = makePaperTheme('dark');

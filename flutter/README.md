# Organic theme for apps/mobile

Drop-in replacements for `apps/mobile/lib/core/theme/`:

- `app_colors.dart`: Organic neutral, terracotta and sage ramps. Legacy names (`charcoal*`, `ivory*`, `teal*`, `coral*`, `cobalt*`) are kept and remapped, so existing imports compile.
- `ops_colors.dart`: same `Tone` enum, `OpsColors` extension and `context.ops` API; tones now come from the ramps. Danger uses one derived red (`#9A3A22` light, `#F08A6B` dark) so it stays distinct from warning; chips still pair color with icon and text.
- `app_theme.dart`: `AppTheme.light()` and `AppTheme.dark()`. Pill buttons and fields, 28px cards, 36px sheets, Caprasimo headings over Figtree, charcoal dock for `NavigationBar`.

Setup:

1. Add `google_fonts: ^6.2.1` to `apps/mobile/pubspec.yaml` (or bundle Caprasimo and Figtree as assets and replace the `GoogleFonts.*` calls with `TextStyle(fontFamily: ...)`).
2. Copy the three files over the existing ones.
3. Run `flutter analyze`. Screens that hardcode `AppBar` colors, `Colors.white` card fills, or the old teal should read from `Theme.of(context)` instead.

Light and dark are both wired to the existing `theme_mode_provider.dart`; no provider changes needed.

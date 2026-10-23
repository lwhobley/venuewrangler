/// Corner radii of the Organic design system, matching the shapes `AppTheme` sets on cards,
/// tiles, dialogs and sheets. Use these where a screen draws its own container or `InkWell`
/// instead of hardcoding a number, so the shapes stay in step with the theme.
class AppRadii {
  const AppRadii._();

  /// Cards and panels (`CardTheme`).
  static const card = 28.0;

  /// Tiles and rows inside a card, and list tiles (`ListTileTheme`).
  static const tile = 20.0;

  /// Top corners of bottom sheets (`BottomSheetTheme`).
  static const sheet = 36.0;

  /// Dialogs (`DialogTheme`).
  static const dialog = 32.0;

  /// Buttons, fields, chips and the navigation dock: always fully rounded.
  static const pill = 999.0;
}

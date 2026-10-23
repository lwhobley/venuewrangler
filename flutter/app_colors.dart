import 'package:flutter/material.dart';

/// Raw palette, Organic design system. Screens should not use these directly: read
/// `Theme.of(context).colorScheme` or the semantic [OpsColors] extension so light and dark
/// stay consistent.
///
/// Legacy names (charcoal*, ivory*, teal*, coral*, cobalt*) are kept so existing imports keep
/// compiling; their values now come from the Organic ramps. `teal` is the primary accent
/// (terracotta) and `tealLight` its dark-mode counterpart.
class AppColors {
  const AppColors._();

  // Organic neutrals (ramp steps 100..900)
  static const neutral100 = Color(0xFFF9F4ED);
  static const neutral200 = Color(0xFFEEE7DB);
  static const neutral300 = Color(0xFFDCD3C4);
  static const neutral400 = Color(0xFFC0B6A5);
  static const neutral500 = Color(0xFFA19786);
  static const neutral600 = Color(0xFF82796A);
  static const neutral700 = Color(0xFF645C50);
  static const neutral800 = Color(0xFF474238);
  static const neutral900 = Color(0xFF2E2B25);

  // Terracotta accent ramp
  static const accent100 = Color(0xFFFFF2EB);
  static const accent200 = Color(0xFFFFE1D0);
  static const accent300 = Color(0xFFFFC6A5);
  static const accent400 = Color(0xFFF6A06B);
  static const accent = Color(0xFFC67139);
  static const accent600 = Color(0xFFB2622D);
  static const accent700 = Color(0xFF8C491A);
  static const accent800 = Color(0xFF643312);
  static const accent900 = Color(0xFF402310);

  // Sage second accent ramp
  static const sage100 = Color(0xFFF0FAE1);
  static const sage200 = Color(0xFFE1EECC);
  static const sage300 = Color(0xFFCCDBB2);
  static const sage400 = Color(0xFFAEBF92);
  static const sage500 = Color(0xFF8FA073);
  static const sage600 = Color(0xFF728157);
  static const sage700 = Color(0xFF56633F);
  static const sage800 = Color(0xFF3D472B);
  static const sage900 = Color(0xFF272E1B);

  // Workspace + surfaces
  static const charcoal = neutral900;
  static const charcoalRaised = Color(0xFF3A362E);
  static const charcoalPanel = neutral800;
  static const charcoalLine = neutral700;
  static const ivory = Color(0xFFF5EAD8); // --color-bg
  static const ivoryDeep = Color(0xFFEBDDC5); // --color-surface
  static const ivoryLine = neutral300;
  static const white = Color(0xFFFFFFFF);

  // Text
  static const inkOnLight = Color(0xFF201E1D);
  static const mutedOnLight = neutral700;
  static const inkOnDark = neutral100;
  static const mutedOnDark = neutral400;

  // Primary (terracotta). `teal*` names retained for compatibility.
  static const teal = accent;
  static const tealLight = accent400;
  static const tealContainer = accent200;

  // Legacy interactive names, mapped to the Organic accents.
  static const coral = accent;
  static const coralStrongOnLight = accent700;
  static const cobalt = sage600;
  static const cobaltOnDark = sage400;
  static const cobaltStrongOnLight = sage700;

  // Semantic status tones. Danger is the one derived hue: terracotta rotated toward red.
  static const greenOnDark = sage400;
  static const greenOnLight = sage800;
  static const amberOnDark = accent300;
  static const amberOnLight = accent700;
  static const purpleOnDark = sage300;
  static const purpleOnLight = sage700;
  static const redOnDark = Color(0xFFF08A6B);
  static const redOnLight = Color(0xFF9A3A22);
}

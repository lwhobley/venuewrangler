import 'package:flutter/material.dart';

/// Raw palette. Screens should not use these directly — read `Theme.of(context).colorScheme`
/// or the semantic [OpsColors] extension so light/dark stay consistent.
class AppColors {
  const AppColors._();

  // Workspace + surfaces
  static const charcoal = Color(0xFF141A22);
  static const charcoalRaised = Color(0xFF1B2330);
  static const charcoalPanel = Color(0xFF222C3B);
  static const charcoalLine = Color(0xFF2F3B4D);
  static const ivory = Color(0xFFF5F1EA);
  static const ivoryDeep = Color(0xFFEBE5DA);
  static const ivoryLine = Color(0xFFD9D2C4);
  static const white = Color(0xFFFFFFFF);

  // Text
  static const inkOnLight = Color(0xFF141A22);
  static const mutedOnLight = Color(0xFF566173);
  static const inkOnDark = Color(0xFFF1EDE5);
  static const mutedOnDark = Color(0xFFA3AFBF);

  // Interactive accent (primary) and selection/edit accent (secondary)
  static const coral = Color(0xFFFF5A5F);
  static const coralStrongOnLight = Color(0xFFC62F36);
  static const cobalt = Color(0xFF4D7CFE);

  /// Cobalt lightened to stay readable as text/icons on charcoal (plain cobalt is ~3.9:1).
  static const cobaltOnDark = Color(0xFF7C9FFE);
  static const cobaltStrongOnLight = Color(0xFF2450CC);

  // Semantic status tones — foreground (text/icon) per brightness, tinted container
  static const greenOnDark = Color(0xFF5BD39A);
  static const greenOnLight = Color(0xFF146A43);
  static const amberOnDark = Color(0xFFF5BC4A);
  static const amberOnLight = Color(0xFF8A5600);
  static const purpleOnDark = Color(0xFFB59BFF);
  static const purpleOnLight = Color(0xFF6742C4);
  static const redOnDark = Color(0xFFFF8585);
  static const redOnLight = Color(0xFFB3261E);
}

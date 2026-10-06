import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

const _key = 'theme_mode';

/// User's light/dark/system choice, persisted on-device. Defaults to following the system.
final themeModeProvider =
    StateNotifierProvider<ThemeModeNotifier, ThemeMode>((ref) {
  return ThemeModeNotifier()..load();
});

class ThemeModeNotifier extends StateNotifier<ThemeMode> {
  ThemeModeNotifier() : super(ThemeMode.system);

  static const _storage = FlutterSecureStorage();
  bool _chosen = false;

  Future<void> load() async {
    try {
      final saved = await _storage.read(key: _key);
      final mode = ThemeMode.values.where((m) => m.name == saved);
      if (mode.isNotEmpty && !_chosen && mounted) state = mode.first;
    } catch (_) {
      // Storage unavailable (e.g. in tests): keep following the system.
    }
  }

  Future<void> set(ThemeMode mode) async {
    _chosen = true;
    state = mode;
    try {
      await _storage.write(key: _key, value: mode.name);
    } catch (_) {}
  }
}

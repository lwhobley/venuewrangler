import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';

/// Runs before every test file. The theme uses `google_fonts`, which needs the Flutter binding
/// (a theme built in `main()` runs before any test) and would otherwise try to download the
/// fonts. Tests never have network access, so fetching is off: text falls back to the default
/// font, which does not matter for layout assertions or contrast checks.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  TestWidgetsFlutterBinding.ensureInitialized();
  GoogleFonts.config.allowRuntimeFetching = false;
  await testMain();
}

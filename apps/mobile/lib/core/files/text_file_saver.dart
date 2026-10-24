import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'text_file_saver_io.dart'
    if (dart.library.html) 'text_file_saver_web.dart' as platform;

/// Hands a generated text file (a CSV export) to the person: a browser download on web, the
/// system "save to" sheet on iOS and Android (file_picker's saveFile), where they can keep it
/// in Files/Drive and send it on.
abstract interface class TextFileSaver {
  /// Returns false when the person dismissed the save sheet.
  Future<bool> save({
    required String fileName,
    required String contents,
    String mimeType = 'text/csv',
  });
}

final textFileSaverProvider =
    Provider<TextFileSaver>((ref) => platform.createTextFileSaver());

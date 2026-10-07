import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// A thin interface over `file_picker`, same reasoning as media's ImagePickerService: UI code
/// and tests never depend on the plugin directly.
///
/// Exactly one of [path] (mobile/desktop: a file on disk) or [bytes] (web: browsers expose no file
/// path, and reading `PlatformFile.path` there throws) is set.
class PickedDocument {
  const PickedDocument({this.path, this.bytes, required this.name})
      : assert((path == null) != (bytes == null));
  final String? path;
  final Uint8List? bytes;
  final String name;
}

abstract interface class DocumentPickerService {
  /// Returns the picked file, or `null` if the user cancelled. Allowed extensions mirror
  /// supabase/functions/_shared/document-bytes.ts's MIME_BY_EXTENSION map exactly, so a user
  /// can never pick a file the server will reject on extension alone.
  Future<PickedDocument?> pickDocument();
}

class DeviceDocumentPickerService implements DocumentPickerService {
  const DeviceDocumentPickerService();

  static const _allowedExtensions = [
    'pdf',
    'jpg',
    'jpeg',
    'png',
    'webp',
    'txt',
    'csv',
    'rtf',
    'docx',
    'xlsx',
    'pptx',
  ];

  @override
  Future<PickedDocument?> pickDocument() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: _allowedExtensions,
      withData: kIsWeb,
    );
    final file = result?.files.single;
    if (file == null) return null;
    if (kIsWeb) {
      final bytes = file.bytes;
      return bytes == null
          ? null
          : PickedDocument(bytes: bytes, name: file.name);
    }
    final path = file.path;
    return path == null ? null : PickedDocument(path: path, name: file.name);
  }
}

final documentPickerServiceProvider = Provider<DocumentPickerService>((ref) {
  return const DeviceDocumentPickerService();
});

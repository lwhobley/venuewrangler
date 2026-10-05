import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// A thin interface over `file_picker`, same reasoning as media's ImagePickerService: UI code
/// and tests never depend on the plugin directly.
class PickedDocument {
  const PickedDocument({required this.path, required this.name});
  final String path;
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
      withData: false,
    );
    final file = result?.files.single;
    if (file?.path == null) return null;
    return PickedDocument(path: file!.path!, name: file.name);
  }
}

final documentPickerServiceProvider = Provider<DocumentPickerService>((ref) {
  return const DeviceDocumentPickerService();
});

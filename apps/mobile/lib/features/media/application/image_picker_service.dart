import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart' show Uint8List;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import 'image_sanitizer.dart';

/// A thin interface over `image_picker` so UI code and tests never depend on the plugin
/// directly — a widget test can override [imagePickerServiceProvider] with a fake returning
/// a fixed path, rather than needing to mock a platform channel.
abstract interface class ImagePickerService {
  /// Returns the picked file's local path, or `null` if the user cancelled. The file has had its
  /// EXIF/GPS and other metadata stripped (see `image_sanitizer.dart`).
  Future<String?> pickImage({required ImageSource source});

  /// Returns the picked image's bytes, metadata stripped the same way, or `null` if the user
  /// cancelled. Unlike [pickImage] this works in a browser, which has no local file paths
  /// (sanitizing or reading a picked file by path throws there), so it is what uploads that
  /// don't need a file on disk afterwards (profile photos) should use.
  Future<Uint8List?> pickImageBytes({required ImageSource source});
}

class DeviceImagePickerService implements ImagePickerService {
  const DeviceImagePickerService();

  @override
  Future<String?> pickImage({required ImageSource source}) async {
    final file =
        await ImagePicker().pickImage(source: source, imageQuality: 85);
    if (file == null) return null;
    // image_picker can carry the source's GPS tags into its copy; strip them before anything
    // else (annotation, queueing, upload) can see the file.
    return sanitizeImageFile(file.path);
  }

  @override
  Future<Uint8List?> pickImageBytes({required ImageSource source}) async {
    final file =
        await ImagePicker().pickImage(source: source, imageQuality: 85);
    if (file == null) return null;
    final bytes = await file.readAsBytes();
    // On a device image_picker leaves its (unsanitized) copy in the cache; the bytes are all
    // that's needed now, so drop it. In a browser the "path" is a blob URL with nothing to delete.
    if (!kIsWeb) await deleteTempImage(file.path);
    return sanitizeImageBytes(bytes);
  }
}

final imagePickerServiceProvider = Provider<ImagePickerService>((ref) {
  return const DeviceImagePickerService();
});

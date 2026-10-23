import 'package:flutter/foundation.dart';
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
    return kIsWeb ? file.path : sanitizeImageFile(file.path);
  }
}

final imagePickerServiceProvider = Provider<ImagePickerService>((ref) {
  return const DeviceImagePickerService();
});

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

/// A thin interface over `image_picker` so UI code and tests never depend on the plugin
/// directly — a widget test can override [imagePickerServiceProvider] with a fake returning
/// a fixed path, rather than needing to mock a platform channel.
abstract interface class ImagePickerService {
  /// Returns the picked file's local path, or `null` if the user cancelled.
  Future<String?> pickImage({required ImageSource source});
}

class DeviceImagePickerService implements ImagePickerService {
  const DeviceImagePickerService();

  @override
  Future<String?> pickImage({required ImageSource source}) async {
    final file = await ImagePicker().pickImage(source: source, imageQuality: 85);
    return file?.path;
  }
}

final imagePickerServiceProvider = Provider<ImagePickerService>((ref) {
  return const DeviceImagePickerService();
});

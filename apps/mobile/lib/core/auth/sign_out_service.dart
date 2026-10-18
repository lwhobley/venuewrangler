import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../network/supabase_providers.dart';
import '../offline/offline_queue_providers.dart';
import '../storage/secure_session_storage.dart';
import '../../features/notifications/application/notifications_providers.dart';
import 'auth_providers.dart';

/// Deletes the temporary copies `file_picker` made of documents/imports the person chose
/// (they are otherwise left in the app cache until the OS reclaims it). Unsupported on web and
/// desktop; callers must treat a failure as non-fatal.
Future<void> clearPickerTemporaryFiles() async {
  if (kIsWeb) return;
  await FilePicker.clearTemporaryFiles();
}

/// Overridable in tests; the real implementation touches a platform channel.
final pickerTemporaryFilesCleanerProvider =
    Provider<Future<void> Function()>((ref) => clearPickerTemporaryFiles);

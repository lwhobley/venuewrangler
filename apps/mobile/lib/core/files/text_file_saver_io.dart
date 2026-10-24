import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';

import 'text_file_saver.dart';

TextFileSaver createTextFileSaver() => const _IoTextFileSaver();

class _IoTextFileSaver implements TextFileSaver {
  const _IoTextFileSaver();

  @override
  Future<bool> save({
    required String fileName,
    required String contents,
    String mimeType = 'text/csv',
  }) async {
    // A UTF-8 byte-order mark so spreadsheet apps read accented names correctly.
    final bytes = utf8.encode('﻿$contents');
    final path = await FilePicker.platform.saveFile(
      fileName: fileName,
      bytes: bytes,
    );
    if (path == null) return false;
    // On desktop the picker only chooses a path; on mobile it has written the bytes already.
    if (!Platform.isAndroid && !Platform.isIOS) {
      await File(path).writeAsBytes(bytes);
    }
    return true;
  }
}

// dart:html is needed for the download link; this file is only compiled for web builds.
// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;

import 'text_file_saver.dart';

TextFileSaver createTextFileSaver() => const _WebTextFileSaver();

class _WebTextFileSaver implements TextFileSaver {
  const _WebTextFileSaver();

  @override
  Future<bool> save({
    required String fileName,
    required String contents,
    String mimeType = 'text/csv',
  }) async {
    // A UTF-8 byte-order mark so spreadsheet apps read accented names correctly.
    final blob = html.Blob(
      [utf8.encode('﻿$contents')],
      '$mimeType;charset=utf-8',
    );
    final url = html.Url.createObjectUrlFromBlob(blob);
    html.AnchorElement(href: url)
      ..download = fileName
      ..style.display = 'none'
      ..click();
    // Give the browser a moment to start the download before releasing the blob.
    unawaited(
      Future<void>.delayed(
        const Duration(seconds: 5),
        () => html.Url.revokeObjectUrl(url),
      ),
    );
    return true;
  }
}

import 'dart:io';
import 'dart:typed_data';

/// Strips location and other embedded metadata (EXIF incl. GPS, XMP, IPTC, comments, PNG text
/// chunks) from images before they leave the device.
///
/// Why this exists: every venue member can read staff photos, and `image_picker` copies the
/// source file's `TAG_GPS_*` tags through on Android, so a coworker could recover where a photo
/// was taken (often someone's home). Done in pure Dart by rewriting the container instead of
/// decoding and re-encoding the pixels: nothing is recompressed, so image quality is untouched,
/// and no image-codec dependency is needed.
///
/// JPEG: every APP1 (EXIF/XMP), APP13 (Photoshop/IPTC), and COM segment is dropped. The EXIF
/// *orientation* is the one thing worth keeping (phones store portrait shots rotated and rely on
/// it), so when it is not "normal" a minimal EXIF block holding only that tag is written back.
/// JFIF, ICC profile and Adobe colour-transform segments are kept.
/// PNG: `eXIf`, `tEXt`, `zTXt`, `iTXt` (XMP) and `tIME` chunks are dropped.
/// WebP: `EXIF` and `XMP ` chunks are dropped and the VP8X flags cleared to match.
class UnsupportedImageFormatException extends FormatException {
  const UnsupportedImageFormatException()
      : super('Choose a JPEG, PNG, or WebP photo.');
}

/// Returns [bytes] with metadata removed. Throws [UnsupportedImageFormatException] for any
/// other format (fail closed: an image we cannot inspect is not uploaded) and [FormatException]
/// for a truncated or malformed file.
Uint8List sanitizeImageBytes(Uint8List bytes) {
  if (_isJpeg(bytes)) return _sanitizeJpeg(bytes);
  if (_isPng(bytes)) return _sanitizePng(bytes);
  if (_isWebp(bytes)) return _sanitizeWebp(bytes);
  throw const UnsupportedImageFormatException();
}

/// Sanitizes the file at [path] in place (write to a sibling, then rename) and returns [path].
Future<String> sanitizeImageFile(String path) async {
  final file = File(path);
  final cleaned = sanitizeImageBytes(await file.readAsBytes());
  final tmp = File('$path.clean');
  await tmp.writeAsBytes(cleaned, flush: true);
  await tmp.rename(path);
  return path;
}

/// Best-effort removal of a local temp copy once it has been uploaded or queued for good.
Future<void> deleteTempImage(String path) async {
  try {
    final file = File(path);
    if (await file.exists()) await file.delete();
  } catch (_) {
    // A leftover cache file is not worth failing an upload that already succeeded.
  }
}

bool _isJpeg(Uint8List b) =>
    b.length >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF;

bool _isPng(Uint8List b) {
  const sig = [137, 80, 78, 71, 13, 10, 26, 10];
  if (b.length < sig.length) return false;
  for (var i = 0; i < sig.length; i++) {
    if (b[i] != sig[i]) return false;
  }
  return true;
}

bool _isWebp(Uint8List b) =>
    b.length >= 12 &&
    String.fromCharCodes(b.sublist(0, 4)) == 'RIFF' &&
    String.fromCharCodes(b.sublist(8, 12)) == 'WEBP';

// ---- JPEG -------------------------------------------------------------------------------

Uint8List _sanitizeJpeg(Uint8List b) {
  final out = BytesBuilder(copy: false);
  out.add(const [0xFF, 0xD8]);
  var orientation = 1;
  final kept = BytesBuilder(copy: false);

  var i = 2;
  while (true) {
    if (i + 1 >= b.length) throw const FormatException('Truncated JPEG.');
    if (b[i] != 0xFF) throw const FormatException('Malformed JPEG.');
    // Fill bytes: any number of 0xFF may precede a marker.
    while (i + 1 < b.length && b[i + 1] == 0xFF) {
      i++;
    }
    final marker = b[i + 1];
    // Standalone markers have no length field.
    if (marker == 0xD8 ||
        marker == 0x01 ||
        (marker >= 0xD0 && marker <= 0xD7)) {
      kept.add(b.sublist(i, i + 2));
      i += 2;
      continue;
    }
    if (marker == 0xD9) {
      // EOI before any scan: nothing more to copy.
      kept.add(const [0xFF, 0xD9]);
      break;
    }
    if (i + 3 >= b.length) throw const FormatException('Truncated JPEG.');
    final length = (b[i + 2] << 8) | b[i + 3];
    if (length < 2 || i + 2 + length > b.length) {
      throw const FormatException('Malformed JPEG segment.');
    }
    final end = i + 2 + length;

    if (marker == 0xDA) {
      // Start of scan: the entropy-coded data runs to the end of the file; copy it verbatim.
      kept.add(b.sublist(i));
      break;
    }

    final drop = marker == 0xE1 || marker == 0xED || marker == 0xFE;
    if (marker == 0xE1) {
      orientation = _exifOrientation(b, i + 4, end) ?? orientation;
    }
    if (!drop) kept.add(b.sublist(i, end));
    i = end;
  }

  final body = kept.takeBytes();
  // The orientation block must come right after SOI/JFIF; placing it first is valid and
  // simplest (readers locate APP1 by scanning).
  if (orientation > 1 && orientation <= 8) {
    out.add(_orientationOnlyExif(orientation));
  }
  out.add(body);
  return out.takeBytes();
}

/// Reads the EXIF Orientation tag from an APP1 payload [start, end), or null if absent.
int? _exifOrientation(Uint8List b, int start, int end) {
  // "Exif\0\0" then a TIFF header.
  if (end - start < 14) return null;
  const exif = [0x45, 0x78, 0x69, 0x66, 0, 0];
  for (var k = 0; k < exif.length; k++) {
    if (b[start + k] != exif[k]) return null;
  }
  final tiff = start + 6;
  final bool little;
  if (b[tiff] == 0x49 && b[tiff + 1] == 0x49) {
    little = true;
  } else if (b[tiff] == 0x4D && b[tiff + 1] == 0x4D) {
    little = false;
  } else {
    return null;
  }
  int u16(int o) => little ? b[o] | (b[o + 1] << 8) : (b[o] << 8) | b[o + 1];
  int u32(int o) => little
      ? b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24)
      : (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];

  if (tiff + 8 > end) return null;
  final ifd = tiff + u32(tiff + 4);
  if (ifd + 2 > end) return null;
  final count = u16(ifd);
  for (var n = 0; n < count; n++) {
    final entry = ifd + 2 + n * 12;
    if (entry + 12 > end) return null;
    if (u16(entry) == 0x0112 && u16(entry + 2) == 3) {
      final value = u16(entry + 8);
      return value >= 1 && value <= 8 ? value : null;
    }
  }
  return null;
}

/// A complete APP1 segment whose only tag is Orientation (big-endian TIFF, one IFD entry).
Uint8List _orientationOnlyExif(int orientation) {
  return Uint8List.fromList([
    0xFF, 0xE1, 0x00, 0x22, // APP1, length 34
    0x45, 0x78, 0x69, 0x66, 0x00, 0x00, // "Exif\0\0"
    0x4D, 0x4D, 0x00, 0x2A, 0x00, 0x00, 0x00,
    0x08, // TIFF header, IFD0 at offset 8
    0x00, 0x01, // one entry
    0x01, 0x12, 0x00, 0x03, 0x00, 0x00, 0x00,
    0x01, // Orientation, SHORT, count 1
    0x00, orientation, 0x00, 0x00, // value
    0x00, 0x00, 0x00, 0x00, // no next IFD
  ]);
}

// ---- PNG --------------------------------------------------------------------------------

Uint8List _sanitizePng(Uint8List b) {
  const drop = {'eXIf', 'tEXt', 'zTXt', 'iTXt', 'tIME'};
  final out = BytesBuilder(copy: false)..add(b.sublist(0, 8));
  var i = 8;
  var sawEnd = false;
  while (i < b.length) {
    if (i + 12 > b.length) throw const FormatException('Truncated PNG.');
    final length = (b[i] << 24) | (b[i + 1] << 16) | (b[i + 2] << 8) | b[i + 3];
    final end = i + 12 + length;
    if (length < 0 || end > b.length) {
      throw const FormatException('Malformed PNG chunk.');
    }
    final type = String.fromCharCodes(b.sublist(i + 4, i + 8));
    if (!drop.contains(type)) out.add(b.sublist(i, end));
    i = end;
    if (type == 'IEND') {
      sawEnd = true;
      break;
    }
  }
  if (!sawEnd) throw const FormatException('Truncated PNG.');
  return out.takeBytes();
}

// ---- WebP -------------------------------------------------------------------------------

Uint8List _sanitizeWebp(Uint8List b) {
  final chunks = BytesBuilder(copy: false);
  var i = 12;
  while (i < b.length) {
    if (i + 8 > b.length) throw const FormatException('Truncated WebP.');
    final type = String.fromCharCodes(b.sublist(i, i + 4));
    final size =
        b[i + 4] | (b[i + 5] << 8) | (b[i + 6] << 16) | (b[i + 7] << 24);
    final padded = size + (size & 1);
    final end = i + 8 + padded;
    if (end > b.length) throw const FormatException('Malformed WebP chunk.');
    if (type == 'EXIF' || type == 'XMP ') {
      i = end;
      continue;
    }
    final chunk = Uint8List.fromList(b.sublist(i, end));
    if (type == 'VP8X' && size >= 1) {
      // Feature flags: 0x08 = EXIF present, 0x04 = XMP present.
      chunk[8] = chunk[8] & ~0x0C;
    }
    chunks.add(chunk);
    i = end;
  }
  final body = chunks.takeBytes();
  final riffSize = body.length + 4; // "WEBP" + chunks
  final out = BytesBuilder(copy: false)
    ..add(const [0x52, 0x49, 0x46, 0x46]) // RIFF
    ..add([
      riffSize & 0xFF,
      (riffSize >> 8) & 0xFF,
      (riffSize >> 16) & 0xFF,
      (riffSize >> 24) & 0xFF,
    ])
    ..add(const [0x57, 0x45, 0x42, 0x50]) // WEBP
    ..add(body);
  return out.takeBytes();
}

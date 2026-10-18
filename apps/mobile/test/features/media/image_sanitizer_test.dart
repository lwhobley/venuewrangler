import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venuewrangler_mobile/features/media/application/image_sanitizer.dart';

const _gpsMarker = 'GPS-LAT-40.7128N-LON-74.0060W';

Uint8List _u16(int v) => Uint8List.fromList([(v >> 8) & 0xFF, v & 0xFF]);

Uint8List _segment(int marker, List<int> payload) => Uint8List.fromList([
      0xFF,
      marker,
      ..._u16(payload.length + 2),
      ...payload,
    ]);

/// A little-endian EXIF block with an Orientation tag and a GPS IFD whose data holds
/// [_gpsMarker] (standing in for the latitude/longitude rationals).
Uint8List _exifWithGps({required int orientation}) {
  final gps = ascii.encode(_gpsMarker);
  // TIFF: header(8) | IFD0: count(2) + 2 entries(24) + next(4) = 30 | GPS IFD | gps data
  final ifd0Size = 2 + 2 * 12 + 4;
  final gpsIfdOffset = 8 + ifd0Size;
  final gpsDataOffset = gpsIfdOffset + 2 + 12 + 4;
  final tiff = BytesBuilder()
    ..add([0x49, 0x49, 0x2A, 0x00, 8, 0, 0, 0]) // II, 42, IFD0 at 8
    ..add([2, 0])
    // Orientation (0x0112), SHORT, 1, value
    ..add([0x12, 0x01, 3, 0, 1, 0, 0, 0, orientation, 0, 0, 0])
    // GPSInfo pointer (0x8825), LONG, 1, offset to GPS IFD
    ..add([0x25, 0x88, 4, 0, 1, 0, 0, 0, gpsIfdOffset, 0, 0, 0])
    ..add([0, 0, 0, 0])
    // GPS IFD: one entry, GPSLatitude (0x0002), ASCII, count, offset to data
    ..add([1, 0])
    ..add([
      0x02,
      0x00,
      2,
      0,
      gps.length,
      0,
      0,
      0,
      gpsDataOffset,
      0,
      0,
      0,
    ])
    ..add([0, 0, 0, 0])
    ..add(gps);
  return Uint8List.fromList([
    ...ascii.encode('Exif'),
    0,
    0,
    ...tiff.takeBytes(),
  ]);
}

const _scanData = [0xFF, 0xDA, 0x00, 0x08, 1, 1, 0, 0, 63, 0, 0x12, 0x34, 0x56];

Uint8List _jpeg({int? orientation, bool withComment = true}) {
  final b = BytesBuilder()
    ..add([0xFF, 0xD8])
    ..add(
      _segment(
        0xE0,
        [...ascii.encode('JFIF'), 0, 1, 1, 0, 0, 1, 0, 1, 0, 0],
      ),
    );
  if (orientation != null) {
    b.add(_segment(0xE1, _exifWithGps(orientation: orientation)));
  }
  b
    ..add(
      _segment(
        0xE1,
        ascii.encode('http://ns.adobe.com/xap/1.0/\x00$_gpsMarker'),
      ),
    )
    ..add(_segment(0xED, ascii.encode('Photoshop 3.0\x00$_gpsMarker')));
  if (withComment) b.add(_segment(0xFE, ascii.encode(_gpsMarker)));
  b
    ..add(
      _segment(0xDB, List.filled(65, 8)),
    ) // quantisation table, must survive
    ..add(_scanData)
    ..add([0xFF, 0xD9]);
  return b.takeBytes();
}

bool _contains(Uint8List haystack, List<int> needle) {
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    var ok = true;
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        ok = false;
        break;
      }
    }
    if (ok) return true;
  }
  return false;
}

/// Marker codes of every segment before the scan.
List<int> _markers(Uint8List jpeg) {
  final markers = <int>[];
  var i = 2;
  while (i + 3 < jpeg.length && jpeg[i] == 0xFF) {
    final marker = jpeg[i + 1];
    markers.add(marker);
    if (marker == 0xDA) break;
    i += 2 + ((jpeg[i + 2] << 8) | jpeg[i + 3]);
  }
  return markers;
}

Uint8List _chunk(String type, List<int> data) {
  final length = data.length;
  return Uint8List.fromList([
    (length >> 24) & 0xFF,
    (length >> 16) & 0xFF,
    (length >> 8) & 0xFF,
    length & 0xFF,
    ...ascii.encode(type),
    ...data,
    0, 0, 0, 0, // CRC is not checked by the sanitizer
  ]);
}

void main() {
  group('JPEG', () {
    test('GPS EXIF, XMP, IPTC and comments are removed', () {
      final input = _jpeg(orientation: 1);
      expect(_contains(input, ascii.encode(_gpsMarker)), isTrue);

      final out = sanitizeImageBytes(input);

      expect(_contains(out, ascii.encode(_gpsMarker)), isFalse);
      expect(_contains(out, ascii.encode('GPS')), isFalse);
      expect(_contains(out, ascii.encode('Exif')), isFalse);
      expect(_contains(out, ascii.encode('adobe.com/xap')), isFalse);
      expect(_markers(out), [0xE0, 0xDB, 0xDA]); // JFIF, DQT, SOS
    });

    test('image data and non-metadata segments are untouched', () {
      final out = sanitizeImageBytes(_jpeg(orientation: 1));

      expect(
        out.sublist(out.length - _scanData.length - 2),
        [..._scanData, 0xFF, 0xD9],
      );
      expect(_contains(out, List.filled(65, 8)), isTrue);
      expect(out.sublist(0, 2), [0xFF, 0xD8]);
    });

    test('a rotated photo keeps only its orientation, with no GPS', () {
      final out = sanitizeImageBytes(_jpeg(orientation: 6));

      expect(_contains(out, ascii.encode(_gpsMarker)), isFalse);
      expect(_contains(out, [0x88, 0x25]), isFalse); // no GPSInfo pointer tag
      expect(_markers(out), [0xE1, 0xE0, 0xDB, 0xDA]);
      // The one APP1 segment is the 34-byte orientation-only block.
      expect(out.sublist(2, 6), [0xFF, 0xE1, 0x00, 0x22]);
      expect(out[2 + 2 + 2 + 6 + 8 + 2 + 8], 0x00);
      expect(out[2 + 2 + 2 + 6 + 8 + 2 + 8 + 1], 6);
    });

    test('a photo with no EXIF at all passes through cleanly', () {
      final input = _jpeg(withComment: false);

      final out = sanitizeImageBytes(input);

      expect(_markers(out), [0xE0, 0xDB, 0xDA]);
    });

    test('a truncated file is rejected rather than uploaded half-cleaned', () {
      final input = _jpeg(orientation: 1);

      expect(
        () => sanitizeImageBytes(input.sublist(0, 30)),
        throwsFormatException,
      );
    });
  });

  group('PNG', () {
    test('text, EXIF and time chunks are removed, pixels kept', () {
      final png = BytesBuilder()
        ..add([137, 80, 78, 71, 13, 10, 26, 10])
        ..add(_chunk('IHDR', List.filled(13, 1)))
        ..add(_chunk('tEXt', ascii.encode('Comment\x00$_gpsMarker')))
        ..add(_chunk('eXIf', ascii.encode(_gpsMarker)))
        ..add(_chunk('iTXt', ascii.encode('XML:com.adobe.xmp\x00$_gpsMarker')))
        ..add(_chunk('tIME', List.filled(7, 2)))
        ..add(_chunk('IDAT', [9, 8, 7]))
        ..add(_chunk('IEND', const []));

      final out = sanitizeImageBytes(png.takeBytes());

      expect(_contains(out, ascii.encode('GPS')), isFalse);
      expect(_contains(out, ascii.encode('eXIf')), isFalse);
      expect(_contains(out, ascii.encode('IHDR')), isTrue);
      expect(_contains(out, ascii.encode('IDAT')), isTrue);
      expect(_contains(out, ascii.encode('IEND')), isTrue);
    });
  });

  group('WebP', () {
    Uint8List webp() {
      Uint8List chunk(String type, List<int> data) {
        final size = data.length;
        return Uint8List.fromList([
          ...ascii.encode(type),
          size & 0xFF,
          (size >> 8) & 0xFF,
          (size >> 16) & 0xFF,
          (size >> 24) & 0xFF,
          ...data,
          if (size.isOdd) 0,
        ]);
      }

      final body = BytesBuilder()
        ..add(chunk('VP8X', [0x0C, 0, 0, 0, 1, 0, 0, 1, 0, 0]))
        ..add(chunk('VP8 ', [1, 2, 3, 4]))
        ..add(chunk('EXIF', ascii.encode(_gpsMarker)))
        ..add(chunk('XMP ', ascii.encode(_gpsMarker)));
      final bytes = body.takeBytes();
      final size = bytes.length + 4;
      return Uint8List.fromList([
        ...ascii.encode('RIFF'),
        size & 0xFF,
        (size >> 8) & 0xFF,
        (size >> 16) & 0xFF,
        (size >> 24) & 0xFF,
        ...ascii.encode('WEBP'),
        ...bytes,
      ]);
    }

    test('EXIF and XMP chunks go, flags and RIFF size are updated', () {
      final out = sanitizeImageBytes(webp());

      expect(_contains(out, ascii.encode('GPS')), isFalse);
      expect(_contains(out, ascii.encode('EXIF')), isFalse);
      expect(_contains(out, ascii.encode('XMP ')), isFalse);
      expect(_contains(out, ascii.encode('VP8 ')), isTrue);
      // VP8X flags byte: EXIF (0x08) and XMP (0x04) bits cleared.
      expect(out[20] & 0x0C, 0);
      final riffSize = out[4] | (out[5] << 8) | (out[6] << 16) | (out[7] << 24);
      expect(riffSize, out.length - 8);
    });
  });

  test('other formats are refused rather than uploaded unchecked', () {
    expect(
      () => sanitizeImageBytes(Uint8List.fromList(ascii.encode('GIF89a....'))),
      throwsA(isA<UnsupportedImageFormatException>()),
    );
    expect(() => sanitizeImageBytes(Uint8List(0)), throwsFormatException);
  });

  group('files', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('sanitizer'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('sanitizeImageFile cleans in place and leaves no sibling', () async {
      final file = File('${dir.path}/photo.jpg')
        ..writeAsBytesSync(_jpeg(orientation: 1));

      final path = await sanitizeImageFile(file.path);

      expect(path, file.path);
      expect(_contains(file.readAsBytesSync(), ascii.encode('GPS')), isFalse);
      expect(File('${file.path}.clean').existsSync(), isFalse);
    });

    test('deleteTempImage removes the file and tolerates a missing one',
        () async {
      final file = File('${dir.path}/tmp.jpg')..writeAsBytesSync([1]);

      await deleteTempImage(file.path);
      await deleteTempImage(file.path);

      expect(file.existsSync(), isFalse);
    });
  });
}

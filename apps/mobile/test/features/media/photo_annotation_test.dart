import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venuewrangler_mobile/core/theme/app_theme.dart';
import 'package:venuewrangler_mobile/features/media/domain/annotation.dart';
import 'package:venuewrangler_mobile/features/media/presentation/photo_annotation_screen.dart';

Future<ui.Image> _solidImage(int w, int h) async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(
    Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
    Paint()..color = const Color(0xFF445566),
  );
  return recorder.endRecording().toImage(w, h);
}

class _MemoryImage extends ImageProvider<_MemoryImage> {
  const _MemoryImage(this.image);

  final ui.Image image;

  @override
  Future<_MemoryImage> obtainKey(ImageConfiguration configuration) =>
      Future.value(this);

  @override
  ImageStreamCompleter loadImage(
    _MemoryImage key,
    ImageDecoderCallback decode,
  ) =>
      OneFrameImageStreamCompleter(
        Future.value(ImageInfo(image: image.clone())),
      );

  @override
  bool operator ==(Object other) =>
      other is _MemoryImage && other.image == image;

  @override
  int get hashCode => image.hashCode;
}

void main() {
  testWidgets('export draws annotations on top of the photo', (tester) async {
    await tester.runAsync(() async {
      final base = await _solidImage(100, 50);
      final data = await renderAnnotatedPng(base, [
        const RectAnnotation(
          color: Color(0xFFFF0000),
          width: 0.05,
          from: Offset(0.1, 0.1),
          to: Offset(0.9, 0.9),
        ),
      ]);
      expect(data.lengthInBytes, greaterThan(100));
      // PNG signature.
      final b = data.buffer.asUint8List();
      expect(b.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
    });
  });

  testWidgets('large photos are downscaled for export', (tester) async {
    await tester.runAsync(() async {
      final base = await _solidImage(4800, 2400);
      final data = await renderAnnotatedPng(base, const []);
      final codec = await ui.instantiateImageCodec(
        data.buffer.asUint8List(),
      );
      final frame = await codec.getNextFrame();
      expect(frame.image.width, kMaxExportSide);
      expect(frame.image.height, kMaxExportSide ~/ 2);
    });
  });

  testWidgets('drawing, undo/redo and Done saves an annotated copy',
      (tester) async {
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    late ui.Image base;
    await tester.runAsync(() async => base = await _solidImage(400, 300));

    Uint8List? saved;
    String? result;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async {
                  result = await Navigator.of(context).push<String>(
                    MaterialPageRoute(
                      builder: (_) => PhotoAnnotationScreen(
                        imagePath: '/original.jpg',
                        imageProvider: _MemoryImage(base),
                        saveBytes: (bytes) async {
                          saved = bytes;
                          return '/annotated.png';
                        },
                      ),
                    ),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // Undo is disabled until something is drawn.
    expect(
      tester
          .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.undo))
          .onPressed,
      isNull,
    );

    await tester.drag(find.byType(Image), const Offset(120, 60),
        warnIfMissed: false);
    await tester.pump();
    final undo =
        tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.undo));
    expect(undo.onPressed, isNotNull);

    await tester.tap(find.byTooltip('Undo'));
    await tester.pump();
    expect(
      tester
          .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.redo))
          .onPressed,
      isNotNull,
    );
    await tester.tap(find.byTooltip('Redo'));
    await tester.pump();

    await tester.runAsync(() async {
      await tester.tap(find.text('Done'));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();

    expect(saved, isNotNull);
    expect(result, '/annotated.png');
  });

  testWidgets('Done without drawing returns the original photo',
      (tester) async {
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    late ui.Image base;
    await tester.runAsync(() async => base = await _solidImage(400, 300));

    String? result;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Builder(
          builder: (context) => Scaffold(
            body: ElevatedButton(
              onPressed: () async {
                result = await Navigator.of(context).push<String>(
                  MaterialPageRoute(
                    builder: (_) => PhotoAnnotationScreen(
                      imagePath: '/original.jpg',
                      imageProvider: _MemoryImage(base),
                    ),
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();

    expect(result, '/original.jpg');
  });
}

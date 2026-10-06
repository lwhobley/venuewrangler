import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// All annotation geometry is stored as fractions (0–1) of the photo's width/height, and
/// stroke/text sizes as fractions of its width, so the same annotations render identically on
/// screen and in the full-resolution export.
sealed class Annotation {
  const Annotation({required this.color, required this.width});

  final Color color;

  /// Stroke width as a fraction of the photo width.
  final double width;

  void paint(Canvas canvas, Size size);

  Paint _stroke(Size size) => Paint()
    ..color = color
    ..style = PaintingStyle.stroke
    ..strokeWidth = math.max(1.5, width * size.width)
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;

  static Offset scale(Offset p, Size size) =>
      Offset(p.dx * size.width, p.dy * size.height);
}

class FreehandStroke extends Annotation {
  const FreehandStroke({
    required super.color,
    required super.width,
    required this.points,
  });

  final List<Offset> points;

  FreehandStroke withPoint(Offset p) => FreehandStroke(
        color: color,
        width: width,
        points: [...points, p],
      );

  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty) return;
    final paint = _stroke(size);
    if (points.length == 1) {
      canvas.drawCircle(
        Annotation.scale(points.first, size),
        paint.strokeWidth / 2,
        paint..style = PaintingStyle.fill,
      );
      return;
    }
    final path = Path()
      ..moveTo(
        points.first.dx * size.width,
        points.first.dy * size.height,
      );
    for (var i = 1; i < points.length; i++) {
      path.lineTo(points[i].dx * size.width, points[i].dy * size.height);
    }
    canvas.drawPath(path, paint);
  }
}

class ArrowShape extends Annotation {
  const ArrowShape({
    required super.color,
    required super.width,
    required this.from,
    required this.to,
  });

  final Offset from;
  final Offset to;

  ArrowShape withEnd(Offset p) =>
      ArrowShape(color: color, width: width, from: from, to: p);

  @override
  void paint(Canvas canvas, Size size) {
    final a = Annotation.scale(from, size);
    final b = Annotation.scale(to, size);
    final paint = _stroke(size);
    canvas.drawLine(a, b, paint);
    final len = (b - a).distance;
    if (len < 1) return;
    final head = math.max(paint.strokeWidth * 4, 14.0).clamp(0.0, len);
    final angle = math.atan2(b.dy - a.dy, b.dx - a.dx);
    const spread = math.pi / 7;
    final p1 =
        b - Offset(math.cos(angle - spread), math.sin(angle - spread)) * head;
    final p2 =
        b - Offset(math.cos(angle + spread), math.sin(angle + spread)) * head;
    canvas.drawPath(
      Path()
        ..moveTo(b.dx, b.dy)
        ..lineTo(p1.dx, p1.dy)
        ..moveTo(b.dx, b.dy)
        ..lineTo(p2.dx, p2.dy),
      paint,
    );
  }
}

class RectAnnotation extends Annotation {
  const RectAnnotation({
    required super.color,
    required super.width,
    required this.from,
    required this.to,
    this.ellipse = false,
  });

  final Offset from;
  final Offset to;
  final bool ellipse;

  RectAnnotation withEnd(Offset p) => RectAnnotation(
        color: color,
        width: width,
        from: from,
        to: p,
        ellipse: ellipse,
      );

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromPoints(
      Annotation.scale(from, size),
      Annotation.scale(to, size),
    );
    final paint = _stroke(size);
    ellipse
        ? canvas.drawOval(rect, paint)
        : canvas.drawRRect(
            RRect.fromRectAndRadius(rect, Radius.circular(paint.strokeWidth)),
            paint,
          );
  }
}

class TextLabel extends Annotation {
  const TextLabel({
    required super.color,
    required super.width,
    required this.at,
    required this.text,
  });

  final Offset at;
  final String text;

  @override
  void paint(Canvas canvas, Size size) {
    // Text size scales with the stroke-size choice so Thin/Medium/Thick also mean small/
    // medium/large lettering.
    final fontSize = math.max(12.0, width * size.width * 4.5);
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color,
          fontSize: fontSize,
          fontWeight: FontWeight.w800,
          shadows: const [Shadow(blurRadius: 3), Shadow(blurRadius: 8)],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: size.width * 0.9);
    painter
      ..paint(canvas, Annotation.scale(at, size))
      ..dispose();
  }
}

class AnnotationPainter extends CustomPainter {
  const AnnotationPainter(this.annotations, {this.preview});

  final List<Annotation> annotations;
  final Annotation? preview;

  @override
  void paint(Canvas canvas, Size size) {
    for (final a in annotations) {
      a.paint(canvas, size);
    }
    preview?.paint(canvas, size);
  }

  @override
  bool shouldRepaint(AnnotationPainter old) => true;
}

/// Longest side of an exported photo, in pixels. Keeps uploads comfortably under the bucket's
/// size limit while staying legible.
const int kMaxExportSide = 2400;

/// Draws [base] with [annotations] on top and returns PNG bytes.
Future<ByteData> renderAnnotatedPng(
  ui.Image base,
  List<Annotation> annotations,
) async {
  final longest = math.max(base.width, base.height);
  final scale = longest > kMaxExportSide ? kMaxExportSide / longest : 1.0;
  final size = Size(base.width * scale, base.height * scale);

  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawImageRect(
    base,
    Rect.fromLTWH(0, 0, base.width.toDouble(), base.height.toDouble()),
    Offset.zero & size,
    Paint()..filterQuality = FilterQuality.high,
  );
  AnnotationPainter(annotations).paint(canvas, size);

  final image = await recorder
      .endRecording()
      .toImage(size.width.round(), size.height.round());
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  return bytes!;
}

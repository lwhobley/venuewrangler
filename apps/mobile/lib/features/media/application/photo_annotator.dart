import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../presentation/photo_annotation_screen.dart';

/// Opens the annotation editor for a freshly picked photo. A provider so widget tests that
/// only care about the attach flow can skip the editor UI.
typedef PhotoAnnotator = Future<String?> Function(
  BuildContext context,
  String imagePath,
);

final photoAnnotatorProvider = Provider<PhotoAnnotator>((ref) => annotatePhoto);

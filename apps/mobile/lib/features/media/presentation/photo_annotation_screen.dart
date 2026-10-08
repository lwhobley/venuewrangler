import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../../../core/theme/app_colors.dart';
import '../domain/annotation.dart';

enum AnnotationTool {
  pen('Pen', Icons.edit_outlined),
  arrow('Arrow', Icons.north_east),
  box('Box', Icons.crop_square),
  circle('Circle', Icons.circle_outlined),
  text('Text', Icons.title);

  const AnnotationTool(this.label, this.icon);

  final String label;
  final IconData icon;
}

/// Opens the annotation editor for [imagePath] and returns the path of the annotated copy
/// (or the original path if nothing was drawn). Null if the user backed out.
Future<String?> annotatePhoto(BuildContext context, String imagePath) {
  return Navigator.of(context).push<String>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => PhotoAnnotationScreen(imagePath: imagePath),
    ),
  );
}

/// Draw on a photo before attaching it: freehand, arrows, boxes, circles and text labels, with
/// undo/redo. The photo itself is never modified — an annotated PNG copy is written next to it.
class PhotoAnnotationScreen extends StatefulWidget {
  const PhotoAnnotationScreen({
    super.key,
    required this.imagePath,
    this.imageProvider,
    this.saveBytes,
  });

  final String imagePath;

  /// Test seam: supply the pixels without touching the file system.
  final ImageProvider? imageProvider;

  /// Test seam: where the exported PNG goes. Defaults to the temp directory.
  final Future<String> Function(Uint8List bytes)? saveBytes;

  @override
  State<PhotoAnnotationScreen> createState() => _PhotoAnnotationScreenState();
}

class _PhotoAnnotationScreenState extends State<PhotoAnnotationScreen> {
  static const _palette = [
    AppColors.coral,
    AppColors.amberOnDark,
    Colors.white,
    AppColors.cobaltOnDark,
    AppColors.greenOnDark,
    Colors.black,
  ];
  static const _widths = [('Thin', 0.005), ('Medium', 0.010), ('Thick', 0.018)];

  late final ImageProvider _provider =
      widget.imageProvider ?? FileImage(File(widget.imagePath));
  ImageStream? _stream;
  late final ImageStreamListener _listener;
  ui.Image? _image;

  AnnotationTool _tool = AnnotationTool.pen;
  Color _color = _palette.first;
  double _width = _widths[1].$2;

  final List<Annotation> _done = [];
  final List<Annotation> _redo = [];
  Annotation? _live;
  bool _saving = false;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    _listener = ImageStreamListener(
      (info, _) {
        if (mounted) setState(() => _image = info.image);
      },
      onError: (e, _) {
        if (mounted) setState(() => _loadError = 'Could not open this photo.');
      },
    );
    _stream = _provider.resolve(ImageConfiguration.empty)
      ..addListener(_listener);
  }

  @override
  void dispose() {
    _stream?.removeListener(_listener);
    super.dispose();
  }

  Offset _norm(Offset local, Size size) => Offset(
        (local.dx / size.width).clamp(0.0, 1.0),
        (local.dy / size.height).clamp(0.0, 1.0),
      );

  void _start(Offset p) {
    setState(() {
      _redo.clear();
      _live = switch (_tool) {
        AnnotationTool.pen =>
          FreehandStroke(color: _color, width: _width, points: [p]),
        AnnotationTool.arrow =>
          ArrowShape(color: _color, width: _width, from: p, to: p),
        AnnotationTool.box =>
          RectAnnotation(color: _color, width: _width, from: p, to: p),
        AnnotationTool.circle => RectAnnotation(
            color: _color,
            width: _width,
            from: p,
            to: p,
            ellipse: true,
          ),
        AnnotationTool.text => null,
      };
    });
  }

  void _update(Offset p) {
    final live = _live;
    if (live == null) return;
    setState(() {
      _live = switch (live) {
        FreehandStroke() => live.withPoint(p),
        ArrowShape() => live.withEnd(p),
        RectAnnotation() => live.withEnd(p),
        TextLabel() => live,
      };
    });
  }

  void _end() {
    final live = _live;
    if (live == null) return;
    setState(() {
      _done.add(live);
      _live = null;
    });
  }

  Future<void> _addText(Offset at) async {
    var label = '';
    final text = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add label'),
        content: TextField(
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(labelText: 'Text'),
          onChanged: (value) => label = value,
          onSubmitted: (v) => Navigator.pop(context, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, label.trim()),
            child: const Text('Add'),
          ),
        ],
      ),
    );
    if (!mounted || text == null || text.isEmpty) return;
    setState(() {
      _redo.clear();
      _done.add(TextLabel(color: _color, width: _width, at: at, text: text));
    });
  }

  void _undo() {
    if (_done.isEmpty) return;
    setState(() => _redo.add(_done.removeLast()));
  }

  void _redoStep() {
    if (_redo.isEmpty) return;
    setState(() => _done.add(_redo.removeLast()));
  }

  Future<String> _defaultSave(Uint8List bytes) async {
    final dir = await getTemporaryDirectory();
    final name = 'annotated_${DateTime.now().microsecondsSinceEpoch}.png';
    final file = File('${dir.path}${Platform.pathSeparator}$name');
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  Future<void> _finish() async {
    final image = _image;
    if (image == null) return;
    if (_done.isEmpty) {
      Navigator.pop(context, widget.imagePath);
      return;
    }
    setState(() => _saving = true);
    try {
      final data = await renderAnnotatedPng(image, _done);
      final bytes =
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      final path = await (widget.saveBytes ?? _defaultSave)(bytes);
      if (mounted) Navigator.pop(context, path);
    } catch (_) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not save the annotated photo.')),
      );
    }
  }

  Future<void> _close() async {
    if (_done.isEmpty) {
      Navigator.pop(context);
      return;
    }
    final discard = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Discard annotations?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep editing'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    if (discard == true && mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final image = _image;
    return PopScope(
      canPop: _done.isEmpty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _close();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          leading: IconButton(
            icon: const Icon(Icons.close),
            tooltip: 'Close',
            onPressed: _close,
          ),
          title: const Text('Annotate photo'),
          actions: [
            IconButton(
              icon: const Icon(Icons.undo),
              tooltip: 'Undo',
              onPressed: _done.isEmpty ? null : _undo,
            ),
            IconButton(
              icon: const Icon(Icons.redo),
              tooltip: 'Redo',
              onPressed: _redo.isEmpty ? null : _redoStep,
            ),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilledButton(
                onPressed: image == null || _saving ? null : _finish,
                child: _saving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Done'),
              ),
            ),
          ],
        ),
        body: Column(
          children: [
            Expanded(
              child: _loadError != null
                  ? Center(
                      child: Text(
                        _loadError!,
                        style: const TextStyle(color: Colors.white),
                      ),
                    )
                  : image == null
                      ? const Center(child: CircularProgressIndicator())
                      : Center(
                          child: AspectRatio(
                            aspectRatio: image.width / image.height,
                            child: LayoutBuilder(
                              builder: (context, c) {
                                final size = c.biggest;
                                return GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTapUp: _tool == AnnotationTool.text
                                      ? (d) => _addText(
                                            _norm(d.localPosition, size),
                                          )
                                      : null,
                                  onPanStart: _tool == AnnotationTool.text
                                      ? null
                                      : (d) => _start(
                                            _norm(d.localPosition, size),
                                          ),
                                  onPanUpdate: _tool == AnnotationTool.text
                                      ? null
                                      : (d) => _update(
                                            _norm(d.localPosition, size),
                                          ),
                                  onPanEnd: (_) => _end(),
                                  child: Stack(
                                    fit: StackFit.expand,
                                    children: [
                                      Image(image: _provider, fit: BoxFit.fill),
                                      CustomPaint(
                                        painter: AnnotationPainter(
                                          _done,
                                          preview: _live,
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                          ),
                        ),
            ),
            Container(
              color: scheme.surfaceContainerHigh,
              child: SafeArea(
                top: false,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      child: Row(
                        children: [
                          for (final tool in AnnotationTool.values)
                            Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 2),
                              child: ChoiceChip(
                                avatar: Icon(tool.icon, size: 18),
                                label: Text(tool.label),
                                selected: _tool == tool,
                                onSelected: (_) => setState(() => _tool = tool),
                              ),
                            ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                      child: Row(
                        children: [
                          for (final c in _palette)
                            Semantics(
                              label: 'Colour',
                              selected: c == _color,
                              button: true,
                              child: GestureDetector(
                                onTap: () => setState(() => _color = c),
                                child: Container(
                                  width: 36,
                                  height: 36,
                                  margin: const EdgeInsets.only(right: 8),
                                  decoration: BoxDecoration(
                                    color: c,
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: c == _color
                                          ? scheme.primary
                                          : scheme.outlineVariant,
                                      width: c == _color ? 3 : 1,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          const Spacer(),
                          SegmentedButton<double>(
                            showSelectedIcon: false,
                            style: const ButtonStyle(
                              visualDensity: VisualDensity.compact,
                            ),
                            segments: [
                              for (final w in _widths)
                                ButtonSegment(value: w.$2, label: Text(w.$1)),
                            ],
                            selected: {_width},
                            onSelectionChanged: (s) =>
                                setState(() => _width = s.first),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

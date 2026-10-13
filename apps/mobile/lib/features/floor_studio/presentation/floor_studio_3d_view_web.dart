// dart:html is needed for the iframe embed; this file is only compiled for web builds.
// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:convert';
import 'dart:html' as html;
import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';

/// Web embed: the bundled scene in a same-origin iframe. The scene signals readiness with
/// `eventtwin-room-scene-ready`; the scene data is posted in reply.
class FloorStudio3DView extends StatefulWidget {
  const FloorStudio3DView({super.key, required this.sceneData});

  final Map<String, Object?> sceneData;

  @override
  State<FloorStudio3DView> createState() => _FloorStudio3DViewState();
}

class _FloorStudio3DViewState extends State<FloorStudio3DView> {
  static var _nextViewId = 0;
  late final String _viewType =
      'venuewrangler-floor-studio-3d-${_nextViewId++}';
  late final html.IFrameElement _iframe;
  html.EventListener? _messageListener;
  var _ready = false;
  String? _lastSent;

  @override
  void initState() {
    super.initState();
    _iframe = html.IFrameElement()
      ..style.border = '0'
      ..style.width = '100%'
      ..style.height = '100%'
      ..src = 'assets/assets/three/scene.html';
    ui_web.platformViewRegistry
        .registerViewFactory(_viewType, (int viewId) => _iframe);
    _messageListener = (event) {
      final message = event as html.MessageEvent;
      final data = message.data;
      if (message.source != _iframe.contentWindow) return;
      if (data is Map && data['type'] == 'eventtwin-room-scene-ready') {
        _ready = true;
        _sendScene();
      }
    };
    html.window.addEventListener('message', _messageListener);
  }

  @override
  void didUpdateWidget(covariant FloorStudio3DView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_ready) _sendScene();
  }

  void _sendScene() {
    final encoded = jsonEncode(widget.sceneData);
    if (encoded == _lastSent) return;
    _lastSent = encoded;
    _iframe.contentWindow?.postMessage(
      {
        'type': 'eventtwin-room-scene',
        'payload': widget.sceneData,
      },
      '*',
    );
  }

  @override
  void dispose() {
    final listener = _messageListener;
    if (listener != null) html.window.removeEventListener('message', listener);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      SizedBox(height: 360, child: HtmlElementView(viewType: _viewType));
}

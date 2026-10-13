import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// Hosts the bundled Three.js room scene in a WebView. The scene listens for a
/// `postMessage` with `type: 'eventtwin-room-scene'`, so the payload is sent once the
/// page has loaded and again whenever it changes.
class FloorStudio3DView extends StatefulWidget {
  const FloorStudio3DView({super.key, required this.sceneData});

  final Map<String, Object?> sceneData;

  @override
  State<FloorStudio3DView> createState() => _FloorStudio3DViewState();
}

class _FloorStudio3DViewState extends State<FloorStudio3DView> {
  late final WebViewController _controller;
  var _pageReady = false;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) {
            _pageReady = true;
            _sendScene();
          },
        ),
      )
      ..loadFlutterAsset('assets/three/scene.html');
  }

  @override
  void didUpdateWidget(covariant FloorStudio3DView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sceneData != widget.sceneData && _pageReady) {
      _sendScene();
    }
  }

  void _sendScene() {
    final message = jsonEncode(
      {'type': 'eventtwin-room-scene', 'payload': widget.sceneData},
    );
    _controller.runJavaScript("window.postMessage($message, '*');");
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 360,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: WebViewWidget(controller: _controller),
      ),
    );
  }
}

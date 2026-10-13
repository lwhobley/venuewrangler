import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'local_asset_server.dart';

/// Hosts the bundled Three.js room scene in a WebView. The scene listens for a
/// `postMessage` with `type: 'eventtwin-room-scene'`, so the payload is sent once the
/// scene reports ready and again whenever it changes.
class FloorStudio3DView extends StatefulWidget {
  const FloorStudio3DView({super.key, required this.sceneData});

  final Map<String, Object?> sceneData;

  @override
  State<FloorStudio3DView> createState() => _FloorStudio3DViewState();
}

class _FloorStudio3DViewState extends State<FloorStudio3DView> {
  late final WebViewController _controller;
  var _pageReady = false;
  String? _lastSent;
  LocalAssetServer? _server;
  var _disposed = false;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      // The scene is a module script, so page-finished can fire before its message
      // listener exists. It announces readiness through this channel instead.
      ..addJavaScriptChannel(
        'EventTwinReady',
        onMessageReceived: (_) {
          _pageReady = true;
          _sendScene();
        },
      );
    _startServer();
  }

  Future<void> _startServer() async {
    final server = await LocalAssetServer.start();
    if (_disposed) {
      await server.close();
      return;
    }
    _server = server;
    await _controller.loadRequest(server.sceneUri);
  }

  @override
  void dispose() {
    _disposed = true;
    _server?.close();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant FloorStudio3DView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_pageReady) _sendScene();
  }

  void _sendScene() {
    final message = jsonEncode(
      {'type': 'eventtwin-room-scene', 'payload': widget.sceneData},
    );
    // The parent builds a fresh map on every rebuild; only re-render on real changes.
    if (message == _lastSent) return;
    _lastSent = message;
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

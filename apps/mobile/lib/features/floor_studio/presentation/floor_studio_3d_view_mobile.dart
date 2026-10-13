import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'local_asset_server.dart';

/// Hosts the bundled Three.js room scene in a WebView. The scene data is stored in a page
/// global and announced with an `eventtwin-scene` event; the scene also checks that global
/// when it starts, so it renders whichever of page load and data delivery happens last.
/// Scene errors come back over the `EventTwinHost` channel and show under the view.
class FloorStudio3DView extends StatefulWidget {
  const FloorStudio3DView({super.key, required this.sceneData});

  final Map<String, Object?> sceneData;

  @override
  State<FloorStudio3DView> createState() => _FloorStudio3DViewState();
}

class _FloorStudio3DViewState extends State<FloorStudio3DView> {
  late final WebViewController _controller;
  var _pageLoaded = false;
  String? _lastSent;
  LocalAssetServer? _server;
  var _disposed = false;
  String? _status = 'Loading 3D scene…';
  final _errors = <String>[];

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel(
        'EventTwinHost',
        onMessageReceived: (message) => _onSceneMessage(message.message),
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) {
            _pageLoaded = true;
            // A (re)loaded page has none of the earlier data, so always resend.
            _lastSent = null;
            _sendScene();
          },
          onWebResourceError: (error) => _addError(
            'Could not load ${error.url ?? 'the 3D scene'}: '
            '${error.description} (${error.errorCode})',
          ),
        ),
      );
    _startServer();
  }

  Future<void> _startServer() async {
    try {
      final server = await LocalAssetServer.start();
      if (_disposed) {
        await server.close();
        return;
      }
      _server = server;
      await _controller.loadRequest(server.sceneUri);
    } catch (error) {
      _addError('Could not start the 3D scene: $error');
    }
  }

  void _onSceneMessage(String raw) {
    Map<String, Object?> message;
    try {
      message = (jsonDecode(raw) as Map).cast<String, Object?>();
    } on FormatException {
      return;
    }
    switch (message['kind']) {
      case 'rendered':
        if (_errors.isEmpty) _setStatus(null);
      case 'error':
        _addError('${message['detail']}');
    }
  }

  void _addError(String error) {
    _errors.add(error);
    _setStatus(_errors.join('\n'));
  }

  void _setStatus(String? status) {
    if (_disposed || !mounted) return;
    setState(() => _status = status);
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
    if (_pageLoaded) _sendScene();
  }

  void _sendScene() {
    final payload = jsonEncode(widget.sceneData);
    // The parent builds a fresh map on every rebuild; only re-render on real changes.
    if (payload == _lastSent) return;
    _lastSent = payload;
    _controller.runJavaScript(
      'window.__eventtwinScene = $payload;'
      "window.dispatchEvent(new Event('eventtwin-scene'));",
    );
  }

  @override
  Widget build(BuildContext context) {
    final status = _status;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 360,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: WebViewWidget(controller: _controller),
          ),
        ),
        if (status != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              status,
              style: TextStyle(
                fontSize: 12,
                color: _errors.isEmpty
                    ? null
                    : Theme.of(context).colorScheme.error,
              ),
            ),
          ),
      ],
    );
  }
}

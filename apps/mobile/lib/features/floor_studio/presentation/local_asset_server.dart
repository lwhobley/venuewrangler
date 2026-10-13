import 'dart:io';

import 'package:flutter/services.dart';

/// Serves the bundled `assets/three/` files over `http://127.0.0.1`. Mobile WebViews
/// block `fetch()` and module imports from `file://`, which the scene needs for its
/// Three.js modules and glTF models.
class LocalAssetServer {
  LocalAssetServer._(this._server);

  final HttpServer _server;

  static const _root = 'assets/three/';
  static const _types = {
    'html': 'text/html; charset=utf-8',
    'js': 'text/javascript; charset=utf-8',
    'gltf': 'model/gltf+json',
    'bin': 'application/octet-stream',
    'jpg': 'image/jpeg',
    'jpeg': 'image/jpeg',
    'png': 'image/png',
  };

  static Future<LocalAssetServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final instance = LocalAssetServer._(server);
    server.listen(instance._handle);
    return instance;
  }

  Uri get sceneUri {
    return Uri.http('127.0.0.1:${_server.port}', '/scene.html');
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    try {
      final segments = request.uri.pathSegments;
      if (segments.isEmpty ||
          segments.any((s) => s.isEmpty || s == '..' || s == '.')) {
        response.statusCode = HttpStatus.notFound;
        return;
      }
      final data = await rootBundle.load('$_root${segments.join('/')}');
      final extension = segments.last.split('.').last.toLowerCase();
      response.headers.contentType = ContentType.parse(
        _types[extension] ?? 'application/octet-stream',
      );
      response
          .add(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
    } catch (_) {
      response.statusCode = HttpStatus.notFound;
    } finally {
      await response.close();
    }
  }

  Future<void> close() => _server.close(force: true);
}

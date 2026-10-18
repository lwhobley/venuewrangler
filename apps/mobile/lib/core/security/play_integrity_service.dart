import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';

/// Android half of the per-request punch proof (the iOS half is [AppAttestService]).
///
/// Asks Google Play for a Play Integrity *standard* token whose `requestHash` is the SHA-256 (hex)
/// of the exact punch payload, so the token cannot be reused for any other request. The server
/// (`supabase/functions/time-clock-punch`) decodes it with Google and checks the hash, package
/// name, freshness and the app/device verdicts.
///
/// Needs the Google Cloud project number linked to the Play Console app, supplied at build time
/// with `--dart-define=PLAY_INTEGRITY_PROJECT_NUMBER=<number>`. Without it, or off Android, this
/// returns null and the punch is recorded unattested (or refused when the server enforces).
class PlayIntegrityService {
  PlayIntegrityService({
    MethodChannel? channel,
    bool Function()? isAndroid,
    String projectNumber = const String.fromEnvironment(
      'PLAY_INTEGRITY_PROJECT_NUMBER',
    ),
  })  : _channel = channel ??
            const MethodChannel('com.venuewrangler.app/play_integrity'),
        _isAndroid = isAndroid ?? (() => !kIsWeb && Platform.isAndroid),
        _projectNumber = projectNumber;

  final MethodChannel _channel;
  final bool Function() _isAndroid;
  final String _projectNumber;

  /// Returns the integrity token for [requestHashHex], or null when unavailable. Never throws.
  Future<String?> requestToken(String requestHashHex) async {
    if (!_isAndroid() || _projectNumber.isEmpty) return null;
    try {
      return await _channel.invokeMethod<String>('requestToken', {
        'requestHash': requestHashHex,
        'cloudProjectNumber': _projectNumber,
      });
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}

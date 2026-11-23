import 'dart:convert';

import 'package:supabase_flutter/supabase_flutter.dart';

/// True when [session]'s access-token AMR includes a `recovery` method.
///
/// Used at bootstrap so a password-recovery session still forces `/reset-password`
/// even if the durable latch key was never persisted (crash before write).
bool sessionLooksLikePasswordRecovery(Session? session) {
  if (session == null) return false;
  final payload = decodeJwtPayload(session.accessToken);
  if (payload == null) return false;
  final amr = payload['amr'];
  if (amr is! List) return false;
  for (final entry in amr) {
    if (entry is Map && entry['method'] == 'recovery') return true;
    if (entry is String && entry == 'recovery') return true;
  }
  return false;
}

/// Decodes the middle segment of a JWT without verifying the signature.
/// Returns null when the token is malformed.
Map<String, dynamic>? decodeJwtPayload(String token) {
  final parts = token.split('.');
  if (parts.length < 2) return null;
  try {
    final normalized = base64Url.normalize(parts[1]);
    final json = utf8.decode(base64Url.decode(normalized));
    final decoded = jsonDecode(json);
    return decoded is Map<String, dynamic>
        ? decoded
        : decoded is Map
            ? Map<String, dynamic>.from(decoded)
            : null;
  } catch (_) {
    return null;
  }
}

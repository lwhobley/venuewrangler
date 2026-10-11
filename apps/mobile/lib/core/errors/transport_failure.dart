import 'dart:async';
import 'dart:io';

import 'package:supabase_flutter/supabase_flutter.dart';

/// True when [error] means the write never got a definitive answer from the server: no
/// connectivity, a timeout, a dropped connection, or a transient server/gateway failure.
///
/// Only these may be queued for later sync. A deterministic rejection (RLS denial, constraint
/// violation, bad input) must be shown to the person instead; queueing it would retry forever
/// and report a failed change as "Saved offline".
bool isTransportFailure(Object error) {
  if (error is SocketException || error is TimeoutException) return true;
  // package:http's ClientException is what the Supabase HTTP stack throws when the connection
  // drops. It is matched by name because package:http is only a dev dependency of this app.
  if (error.runtimeType.toString() == 'ClientException') return true;
  if (error is PostgrestException) {
    final code = error.code ?? '';
    // Empty code: a non-JSON body (e.g. a proxy 502 page). 08xxx: connection exception.
    // 57xxx: operator intervention (shutdown, statement timeout). PGRST000: PostgREST cannot
    // reach the database.
    return code.isEmpty ||
        code.startsWith('08') ||
        code.startsWith('57') ||
        code == 'PGRST000';
  }
  return false;
}

import 'package:flutter/widgets.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import '../config/env_config.dart';

/// Initializes Sentry with PII scrubbing and release/environment tagging, per the migration
/// plan's requirement. When [EnvConfig.sentryDsn] is empty, Sentry stays disabled and
/// [runApp] still runs normally — this mirrors the existing Expo app's behavior
/// (EXPO_PUBLIC_SENTRY_DSN unset => Sentry disabled) documented in Phase 0 discovery.
Future<void> runAppWithErrorReporting(
  EnvConfig env,
  Widget Function() appBuilder,
) async {
  if (env.sentryDsn.isEmpty) {
    runApp(appBuilder());
    return;
  }

  await SentryFlutter.init(
    (options) {
      options.dsn = env.sentryDsn;
      options.environment = env.flavor.name;
      options.tracesSampleRate = 0;
      options.sendDefaultPii = false;
      options.beforeSend = _scrubEvent;
    },
    appRunner: () => runApp(appBuilder()),
  );
}

/// Strips anything that could leak a Supabase access/refresh token, an Authorization
/// header, or a query-string credential before an event leaves the device. Extend this,
/// never remove from it, as new sensitive fields are identified.
SentryEvent? _scrubEvent(SentryEvent event, Hint hint) {
  final request = event.request;
  if (request == null) return event;

  // Header names are case-insensitive — an exact-case remove('Authorization') would let a
  // lowercase `authorization` header through.
  const sensitiveHeaders = {'authorization', 'apikey', 'cookie'};
  final scrubbedHeaders = Map<String, String>.from(request.headers)
    ..removeWhere((key, _) => sensitiveHeaders.contains(key.toLowerCase()));

  final scrubbedUrl = _stripSensitiveQueryParams(request.url);

  return event.copyWith(
    request: request.copyWith(headers: scrubbedHeaders, url: scrubbedUrl),
  );
}

String? _stripSensitiveQueryParams(String? url) {
  if (url == null) return null;
  final uri = Uri.tryParse(url);
  if (uri == null) return url;

  const sensitiveParams = {'token', 'access_token', 'refresh_token', 'apikey'};
  if (uri.queryParameters.keys.toSet().intersection(sensitiveParams).isEmpty) {
    return url;
  }

  final cleaned = Map<String, String>.from(uri.queryParameters)
    ..removeWhere((key, _) => sensitiveParams.contains(key));
  return uri.replace(queryParameters: cleaned).toString();
}

/// A correlation id attached to a privileged Edge Function request, carried into Sentry/audit
/// context (never into the body of a log line that leaves the device). Phase 3 Edge Functions
/// should expect and echo this header back so client- and server-side traces can be joined.
String newCorrelationId() =>
    DateTime.now().microsecondsSinceEpoch.toRadixString(36) +
    (identityHashCode(DateTime.now()) % 0xFFFFFF).toRadixString(36);

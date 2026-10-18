import 'package:flutter/widgets.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import '../config/env_config.dart';
import 'sentry_scrubber.dart';

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
      options.beforeSend = scrubSentryEvent;
      options.beforeBreadcrumb = scrubBreadcrumb;
      // The default also records every debugPrint as a breadcrumb, and the app prints caught
      // errors (`debugPrint('$error')`), which can include PostgREST `Key (email)=(...)` values.
      options.enablePrintBreadcrumbs = false;
    },
    appRunner: () => runApp(appBuilder()),
  );
}

/// A correlation id attached to a privileged Edge Function request, carried into Sentry/audit
/// context (never into the body of a log line that leaves the device). Phase 3 Edge Functions
/// should expect and echo this header back so client- and server-side traces can be joined.
String newCorrelationId() =>
    DateTime.now().microsecondsSinceEpoch.toRadixString(36) +
    (identityHashCode(DateTime.now()) % 0xFFFFFF).toRadixString(36);

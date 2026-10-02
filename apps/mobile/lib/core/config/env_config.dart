import 'flavor.dart';

/// Environment configuration resolved entirely from `--dart-define` values supplied at
/// build/run time. No URL, project id, key, or secret is ever hardcoded here — per the
/// migration plan's hard requirement, the Supabase anon key is the only credential this app
/// ever holds, and it is safe to ship because Postgres RLS (not the client) enforces
/// authorization.
class EnvConfig {
  const EnvConfig({
    required this.flavor,
    required this.supabaseUrl,
    required this.supabaseAnonKey,
    required this.sentryDsn,
  });

  final AppFlavor flavor;
  final String supabaseUrl;
  final String supabaseAnonKey;

  /// Empty string disables Sentry (see core/errors/error_reporter.dart).
  final String sentryDsn;

  factory EnvConfig.fromDartDefines(AppFlavor flavor) {
    const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
    const supabaseAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');
    const sentryDsn = String.fromEnvironment('SENTRY_DSN');

    if (supabaseUrl.isEmpty || supabaseAnonKey.isEmpty) {
      throw StateError(
        'SUPABASE_URL and SUPABASE_ANON_KEY must be supplied via --dart-define '
        '(see apps/mobile/.env.example). Refusing to start with an unconfigured backend.',
      );
    }

    if (flavor.isProduction && !supabaseUrl.startsWith('https://')) {
      throw StateError('Production builds must use an https Supabase URL.');
    }

    return EnvConfig(
      flavor: flavor,
      supabaseUrl: supabaseUrl,
      supabaseAnonKey: supabaseAnonKey,
      sentryDsn: sentryDsn,
    );
  }
}

/// The three build flavors required by the migration plan. Selected at build/run time via
/// `--dart-define=APP_FLAVOR=development|staging|production`; each `main_*.dart` entrypoint
/// hardcodes its own value so a flavor can never be mismatched between the entrypoint used
/// and the config it reads.
enum AppFlavor {
  development,
  staging,
  production;

  static AppFlavor fromString(String value) {
    return AppFlavor.values.firstWhere(
      (flavor) => flavor.name == value,
      orElse: () => AppFlavor.development,
    );
  }

  bool get isProduction => this == AppFlavor.production;
}

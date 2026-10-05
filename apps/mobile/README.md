# Venue Wrangler mobile (Flutter + Supabase)

Phase 1 foundation scaffold. See `docs/migration/flutter-supabase-rebuild-plan.md` at the
repo root for the full discovery, mapping table, and risk list this is built from.

## Status

This is a hand-authored Dart-level scaffold (`pubspec.yaml`, `lib/`, `test/`). **The
`android/`, `ios/`, and `web/` platform folders are not yet populated** — the Flutter SDK was
not available in the environment this scaffold was authored in, and hand-fabricating native
Xcode/Gradle project files without the tooling to verify them would be unbuildable, unreviewable
boilerplate. The first thing to do with a real Flutter SDK is:

```
flutter create --platforms=android,ios,web --org com.venuewrangler --project-name venuewrangler_mobile .
```

run from this directory, which fills in those three folders without touching anything under
`lib/`, `test/`, or `pubspec.yaml`. After that, `flutter pub get`, `dart run build_runner build`
(`freezed`/`build_runner` were removed — no models use codegen; re-add them if that changes), and the three
flavored entrypoints below should run normally.

## Flavors

Three entrypoints, one per environment, each hardcoding its own `AppFlavor` so a flavor can
never be mismatched between the binary built and the config it reads
(`lib/app/bootstrap.dart`):

```
flutter run -t lib/main_development.dart --dart-define-from-file=env/development.json
flutter run -t lib/main_staging.dart     --dart-define-from-file=env/staging.json
flutter run -t lib/main_production.dart  --dart-define-from-file=env/production.json
```

Copy each `env/*.json.example` to `env/*.json` (gitignored) and fill in the real Supabase
project URL/anon key for that environment — never commit the real files. The anon key is safe
to ship: it has no privileges beyond what Postgres RLS grants (see the foundation migration
under `supabase/migrations/`), which is the entire point of moving authorization into the
database instead of the client.

## Architecture

- **State management**: Riverpod. UI never calls `Supabase.instance.client` directly — it goes
  through a repository interface (`core/auth/auth_repository.dart` is the first example),
  which is what makes substituting a fake in widget tests possible.
- **Routing**: a single `go_router` instance (`lib/app/router.dart`) that redirects between the
  auth flow and the authenticated shell based on session state. Feature routes are added here
  as Phase 2 builds them.
- **Errors**: `core/errors/app_error.dart` defines the small set of error categories every
  feature's loading/empty/error/retry/permission-denied state should switch on.
- **Sentry**: `core/errors/error_reporter.dart` — disabled when `SENTRY_DSN` is empty, scrubs
  Authorization headers and token-bearing query params before anything leaves the device.
- **Feature folders**: each `lib/features/*` directory not yet implemented has a short
  `README.md` explaining its scope and which Phase 0 reference behavior it should be built
  from — check there before starting a feature so work doesn't drift from the mapping table.

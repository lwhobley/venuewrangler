# Venue Wrangler mobile (Flutter + Supabase)

See `docs/migration/flutter-supabase-rebuild-plan.md` at the repo root for the original
discovery, mapping table, and risk list this was built from.

## Status

`android/`, `ios/`, and `web/` are all populated and build. iOS ships to TestFlight via
Codemagic (`codemagic.yaml`); Android and web are run/built locally with the commands below.

The `web/` platform folder was added with `flutter create --platforms=web .`, which only
touches `web/` plus a couple of tooling files (`.metadata`, `analysis_options.yaml`) — it does
not add or need a generic `lib/main.dart`, since every target (including web) is built with an
explicit `-t lib/main_*.dart`, same as iOS/Android (see Flavors below). Web-specific caveats:

- `bootstrap.dart` and the push/attestation services guard every `dart:io` `Platform.isX` check
  with `!kIsWeb` first — those getters throw on web, not return `false`, so an unguarded check
  blocks the whole app at startup. Follow this pattern for any new `Platform.isX` use.
- The offline mutation queue (`core/offline/offline_queue_store.dart`) is file-based via
  `path_provider`, which has no web implementation. On web this currently fails silently
  (caught by the Sentry error zone, doesn't block rendering) rather than actually queuing — the
  app works online but offline-queued writes don't yet persist across a web reload. Needs a
  web storage backend (IndexedDB via a conditional import, or `shared_preferences`) before
  offline support is real on web.
- Web icons under `web/icons/` and `web/favicon.png` are reused from the existing iOS/Android
  app icon (not dedicated maskable-safe-zone artwork) — adequate for now, worth regenerating
  properly (e.g. via `flutter_launcher_icons`) before a real web launch.

## Flavors

Three entrypoints, one per environment, each hardcoding its own `AppFlavor` so a flavor can
never be mismatched between the binary built and the config it reads
(`lib/app/bootstrap.dart`). Any of the three works on any platform, including web — add
`-d chrome` to run in a browser, or drop it (and use `flutter build web` instead of `flutter
run`) to just build static output into `build/web/`:

```
flutter run [-d chrome] -t lib/main_development.dart --dart-define-from-file=env/development.json
flutter run [-d chrome] -t lib/main_staging.dart     --dart-define-from-file=env/staging.json
flutter run [-d chrome] -t lib/main_production.dart  --dart-define-from-file=env/production.json

flutter build web -t lib/main_production.dart --dart-define-from-file=env/production.json
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

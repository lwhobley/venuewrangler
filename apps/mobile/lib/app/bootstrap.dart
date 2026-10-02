import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/config/env_config.dart';
import '../core/config/flavor.dart';
import '../core/errors/error_reporter.dart';
import '../core/network/supabase_providers.dart';
import '../core/offline/offline_queue_providers.dart';
import '../core/offline/pending_mutation.dart';
import '../features/tasks/application/tasks_providers.dart';
import 'app.dart';

/// Shared bootstrap every `main_*.dart` entrypoint calls with its own hardcoded [flavor].
/// Keeping this in one place means a flavor can only ever differ by which dart-defines were
/// passed at build time, never by divergent bootstrap logic between entrypoints.
Future<void> bootstrap(AppFlavor flavor) async {
  WidgetsFlutterBinding.ensureInitialized();

  final env = EnvConfig.fromDartDefines(flavor);

  await Supabase.initialize(
    url: env.supabaseUrl,
    anonKey: env.supabaseAnonKey,
  );

  await runAppWithErrorReporting(
    env,
    () => ProviderScope(
      overrides: [
        supabaseClientProvider.overrideWithValue(Supabase.instance.client),
        // Composition root for the offline-mutation-queue handler registry: each feature
        // that queues mutations (currently only tasks) exposes its own handler-map
        // provider, merged here so core/offline never imports a feature directly.
        offlineQueueHandlersProvider.overrideWith(
          (ref) => <String, MutationHandler>{
            ...ref.watch(taskMutationHandlersProvider),
          },
        ),
      ],
      child: const VenueWranglerApp(),
    ),
  );
}

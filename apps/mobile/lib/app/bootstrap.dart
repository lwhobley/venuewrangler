import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/config/env_config.dart';
import '../core/config/flavor.dart';
import '../core/auth/auth_providers.dart';
import '../core/errors/error_reporter.dart';
import '../core/network/supabase_providers.dart';
import '../core/offline/offline_queue_providers.dart';
import '../core/offline/pending_mutation.dart';
import '../core/storage/secure_local_storage.dart';
import '../core/storage/secure_session_storage.dart';
import '../features/checklists/application/checklists_providers.dart';
import '../features/incidents/application/incidents_providers.dart';
import '../features/media/application/media_providers.dart';
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
    publishableKey: env.supabaseAnonKey,
    authOptions: FlutterAuthClientOptions(localStorage: SecureLocalStorage()),
  );
  final recoveryPending =
      Supabase.instance.client.auth.currentSession != null &&
          await const SecureSessionStorage().read(passwordRecoveryStorageKey) ==
              'true';

  // Android push notifications only — iOS uses native APNs directly (see
  // ios/Runner/PushNotificationsPlugin.swift) and has no google-services equivalent file here,
  // so Firebase is never initialized there. Guarded with a try/catch, not just the platform
  // check: android/app/google-services.json may still be the placeholder note rather than a
  // real config (see that path), in which case this throws at startup rather than registering
  // push for the wrong Firebase project — app startup must not depend on this succeeding.
  if (!kIsWeb && Platform.isAndroid) {
    try {
      await Firebase.initializeApp();
    } catch (error) {
      // ignore: avoid_print
      print(
          'Firebase.initializeApp() failed — Android push notifications will not work until '
          'android/app/google-services.json is replaced with the real config: $error');
    }
  }

  await runAppWithErrorReporting(
    env,
    () => ProviderScope(
      overrides: [
        passwordRecoveryPendingProvider.overrideWith((ref) => recoveryPending),
        supabaseClientProvider.overrideWithValue(Supabase.instance.client),
        // Composition root for the offline-mutation-queue handler registry: each feature
        // that queues mutations exposes its own handler-map provider, merged here so
        // core/offline never imports a feature directly.
        offlineQueueHandlersProvider.overrideWith(
          (ref) => <String, MutationHandler>{
            ...ref.watch(taskMutationHandlersProvider),
            ...ref.watch(checklistMutationHandlersProvider),
            ...ref.watch(incidentMutationHandlersProvider),
            ...ref.watch(mediaMutationHandlersProvider),
          },
        ),
      ],
      child: const VenueWranglerApp(),
    ),
  );
}

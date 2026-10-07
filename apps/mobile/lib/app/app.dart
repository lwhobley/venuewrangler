import '../core/theme/theme_mode_provider.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/auth/auth_providers.dart';
import '../core/offline/offline_queue_connectivity.dart';
import '../core/security/app_attest_providers.dart';
import '../core/theme/app_theme.dart';
import '../features/notifications/application/notifications_providers.dart';
import '../features/organizations/application/workspace_provisioning.dart';
import 'intro_video_screen.dart';
import 'router.dart';

class VenueWranglerApp extends ConsumerStatefulWidget {
  const VenueWranglerApp({super.key});

  @override
  ConsumerState<VenueWranglerApp> createState() => _VenueWranglerAppState();
}

class _VenueWranglerAppState extends ConsumerState<VenueWranglerApp> {
  // Plays once per cold start, ahead of auth/venue state, so it shows no matter who's signed
  // in or what they were last doing. Skipped on web when opened at a deep link (e.g. the
  // marketing site's "Launch Workspace" → /app/#/sign-up): the intro's plain MaterialApp
  // would otherwise take over the browser URL, and the router would never see that route.
  bool _introDone = kIsWeb &&
      WidgetsBinding.instance.platformDispatcher.defaultRouteName != '/';

  @override
  Widget build(BuildContext context) {
    if (!_introDone) {
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(),
        home: IntroVideoScreen(
          onFinished: () => setState(() => _introDone = true),
        ),
      );
    }

    // Side-effect only: activates the offline-mutation-queue flush-on-reconnect listener for
    // the whole app's lifetime. See core/offline/offline_queue_connectivity.dart.
    ref.watch(offlineQueueConnectivityProvider);
    // Side-effect only: fires an App Attest attestation attempt on sign-in. See
    // core/security/app_attest_providers.dart.
    ref.watch(appAttestTriggerProvider);
    // Side-effect only: registers a push token for the active venue. See
    // features/notifications/application/notifications_providers.dart.
    ref.watch(pushRegistrationTriggerProvider);
    // Side-effect only: routes a tapped push notification (or one tapped while already in the
    // notifications list) to its destination screen. See app/router.dart.
    ref.watch(notificationTapRoutingProvider);
    // Side-effect only: notices a password-reset sign-in so the router can hold the user on
    // /reset-password. See core/auth/auth_providers.dart.
    ref.watch(passwordRecoveryTriggerProvider);
    // Side-effect only: finishes "Launch Workspace" sign-ups once a session exists. See
    // features/organizations/application/workspace_provisioning.dart.
    ref.watch(pendingWorkspaceCreationTriggerProvider);

    final router = ref.watch(routerProvider);

    return MaterialApp.router(
      title: 'Venue Wrangler',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: ref.watch(themeModeProvider),
      routerConfig: router,
    );
  }
}

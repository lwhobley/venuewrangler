import '../core/theme/theme_mode_provider.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/auth/auth_providers.dart';
import '../core/auth/sign_out_service.dart';
import '../core/offline/offline_queue_connectivity.dart';
import '../core/privacy/privacy_overlay.dart';
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
    // Side-effect only: watch before the intro gate so cold-start deep links, password
    // recovery, server sign-out cleanup, and notification taps are never missed while the
    // intro video plays.
    ref.watch(offlineQueueConnectivityProvider);
    ref.watch(appAttestTriggerProvider);
    ref.watch(pushRegistrationTriggerProvider);
    ref.watch(notificationTapRoutingProvider);
    ref.watch(passwordRecoveryTriggerProvider);
    ref.watch(recoveryMfaProbeProvider);
    ref.watch(serverSignOutCleanupProvider);
    ref.watch(pendingWorkspaceCreationTriggerProvider);

    if (!_introDone) {
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(),
        home: IntroVideoScreen(
          onFinished: () => setState(() => _introDone = true),
        ),
      );
    }

    final router = ref.watch(routerProvider);

    return MaterialApp.router(
      title: 'Venue Wrangler',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: ref.watch(themeModeProvider),
      routerConfig: router,
      // Hides the app in the OS app switcher; see core/privacy/privacy_overlay.dart.
      builder: (context, child) =>
          PrivacyOverlay(child: child ?? const SizedBox.shrink()),
    );
  }
}

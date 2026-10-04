import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/offline/offline_queue_connectivity.dart';
import '../core/security/app_attest_providers.dart';
import '../core/theme/app_theme.dart';
import '../features/notifications/application/notifications_providers.dart';
import 'router.dart';

class VenueWranglerApp extends ConsumerWidget {
  const VenueWranglerApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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

    final router = ref.watch(routerProvider);

    return MaterialApp.router(
      title: 'Venue Wrangler',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      routerConfig: router,
    );
  }
}

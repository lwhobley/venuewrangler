import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/offline/offline_queue_connectivity.dart';
import '../core/theme/app_theme.dart';
import 'router.dart';

class VenueWranglerApp extends ConsumerWidget {
  const VenueWranglerApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Side-effect only: activates the offline-mutation-queue flush-on-reconnect listener for
    // the whole app's lifetime. See core/offline/offline_queue_connectivity.dart.
    ref.watch(offlineQueueConnectivityProvider);

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

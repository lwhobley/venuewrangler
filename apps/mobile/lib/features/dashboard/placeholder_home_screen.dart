import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/auth_providers.dart';
import '../venues/application/venues_providers.dart';

/// Phase 1/early-Phase-2 placeholder authenticated landing screen. The real dashboard (see
/// features/dashboard/README.md) lands later in Phase 2 once tasks/events/inventory exist to
/// summarize.
class PlaceholderHomeScreen extends ConsumerWidget {
  const PlaceholderHomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activeVenue = ref.watch(activeVenueProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(activeVenue?.name ?? 'Venue Wrangler'),
        actions: [
          IconButton(
            icon: const Icon(Icons.swap_horiz),
            tooltip: 'Switch venue',
            onPressed: () => ref.read(activeVenueProvider.notifier).state = null,
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Sign out',
            onPressed: () => ref.read(authRepositoryProvider).signOut(),
          ),
        ],
      ),
      body: const Center(
        child: Text('Signed in with a venue selected. Feature screens land in Phase 2.'),
      ),
    );
  }
}

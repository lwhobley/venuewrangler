import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/auth_providers.dart';

/// Phase 1 placeholder authenticated landing screen. The real dashboard (see
/// features/dashboard/README.md) lands in Phase 2 once organizations/venues exist to query.
class PlaceholderHomeScreen extends ConsumerWidget {
  const PlaceholderHomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Venue Wrangler'),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Sign out',
            onPressed: () => ref.read(authRepositoryProvider).signOut(),
          ),
        ],
      ),
      body: const Center(
        child: Text('Signed in. Feature screens land in Phase 2.'),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/auth_providers.dart';
import '../venues/application/venues_providers.dart';

/// Phase 1/early-Phase-2 placeholder authenticated landing screen. The real dashboard (see
/// features/dashboard/README.md) lands later in Phase 2 once more feature screens exist to
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
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            FilledButton.icon(
              onPressed: () => context.go('/tasks'),
              icon: const Icon(Icons.checklist_outlined),
              label: const Text('Tasks'),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: () => context.go('/checklists'),
              icon: const Icon(Icons.fact_check_outlined),
              label: const Text('Checklists'),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: () => context.go('/incidents'),
              icon: const Icon(Icons.report_outlined),
              label: const Text('Incidents'),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: () => context.go('/wrangler'),
              icon: const Icon(Icons.auto_awesome_outlined),
              label: const Text('Ask Wrangler'),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: () => context.go('/workforce'),
              icon: const Icon(Icons.groups_outlined),
              label: const Text('Staff'),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: () => context.go('/inventory'),
              icon: const Icon(Icons.inventory_2_outlined),
              label: const Text('Inventory'),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: () => context.go('/schedules'),
              icon: const Icon(Icons.calendar_month_outlined),
              label: const Text('Schedule'),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: () => context.go('/billing'),
              icon: const Icon(Icons.credit_card_outlined),
              label: const Text('Billing'),
            ),
          ],
        ),
      ),
    );
  }
}

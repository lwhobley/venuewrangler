import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_radii.dart';
import '../../../core/theme/ops_colors.dart';
import '../application/venues_providers.dart';

/// Route of [VenueLocationScreen] (registered in app/router.dart).
const venueLocationRoute = '/venue-location';

/// Tells a manager that the active venue has no location yet, so nobody can clock in there,
/// with a button to set it. Renders nothing for anyone else or once the location is set.
class VenueLocationPrompt extends ConsumerWidget {
  const VenueLocationPrompt({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final venue = ref.watch(activeVenueProvider);
    final canManage =
        ref.watch(canManageActiveVenueProvider).valueOrNull ?? false;
    if (venue == null || venue.hasLocation || !canManage) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    return Container(
      key: const ValueKey('venue-location-prompt'),
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: context.ops.warning.bg,
        borderRadius: BorderRadius.circular(AppRadii.card),
        border: Border.all(color: context.ops.warning.fg.withAlpha(80)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.location_off_outlined, color: context.ops.warning.fg),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  "Set your venue's location",
                  style: theme.textTheme.titleMedium,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Staff cannot clock in at ${venue.name} until you do. The time '
            'clock checks that each clock-in happens on site.',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: () => context.push(venueLocationRoute),
            icon: const Icon(Icons.place_outlined),
            label: const Text('Set location'),
          ),
        ],
      ),
    );
  }
}

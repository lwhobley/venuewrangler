import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_radii.dart';
import '../../../core/theme/ops_colors.dart';
import '../../shift_mode/presentation/shift_widgets.dart';
import '../../venues/application/venue_clock.dart';
import '../../venues/application/venues_providers.dart';
import '../application/events_providers.dart';
import '../domain/event.dart';

/// Opens an event's details — when it runs (venue time), its status and the notes the manager
/// left for the team (load-in, set-up, who to call). Every venue member can read these; the
/// events table has no private columns (see events_schema.sql).
Future<void> showEventDetailsSheet(BuildContext context, VenueEvent event) =>
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => EventDetailsSheet(event: event),
    );

class EventDetailsSheet extends ConsumerWidget {
  const EventDetailsSheet({super.key, required this.event});

  final VenueEvent event;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final clock = ref.watch(venueClockProvider);
    final notes = event.notes?.trim() ?? '';
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(event.name, style: theme.textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(
              '${clock.formatDateTime(event.startTime)} → '
              '${clock.formatDateTime(event.endTime)}',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 4),
            Text(
              event.status.name,
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            Text('Notes', style: theme.textTheme.titleSmall),
            const SizedBox(height: 6),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(AppRadii.card),
                border: Border.all(color: context.ops.panelBorder),
              ),
              child: notes.isEmpty
                  ? Text(
                      'No notes for this event.',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    )
                  : SelectableText(notes, style: theme.textTheme.bodyMedium),
            ),
          ],
        ),
      ),
    );
  }
}

/// Events that have not ended and start within [horizon] of [now], soonest first, skipping
/// cancelled ones — what a team member needs to know about for the coming shifts.
List<VenueEvent> upcomingEvents(
  Iterable<VenueEvent> events,
  DateTime now, {
  Duration horizon = const Duration(days: 7),
}) {
  final until = now.add(horizon);
  return events
      .where(
        (e) =>
            e.status != EventStatus.cancelled &&
            e.endTime.isAfter(now) &&
            e.startTime.isBefore(until),
      )
      .toList()
    ..sort((a, b) => a.startTime.compareTo(b.startTime));
}

/// A home-screen section listing the next week's events; tapping one opens its details and
/// notes. Renders nothing while there are none, so a venue without events sees no empty card.
class UpcomingEventsSection extends ConsumerWidget {
  const UpcomingEventsSection({super.key, required this.now});

  final DateTime now;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final venue = ref.watch(activeVenueProvider);
    if (venue == null) return const SizedBox.shrink();
    final clock = ref.watch(venueClockProvider);
    final events = ref.watch(eventsForVenueProvider(venue.id));
    final upcoming = upcomingEvents(events.valueOrNull ?? const [], now);
    if (upcoming.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SectionTitle('Upcoming events'),
          for (final event in upcoming.take(5))
            Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                leading: const Icon(Icons.event_outlined),
                title: Text(event.name),
                subtitle: Text(
                  [
                    clock.formatDateTime(event.startTime),
                    if (event.notes?.trim().isNotEmpty == true)
                      event.notes!.trim(),
                  ].join('\n'),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => showEventDetailsSheet(context, event),
              ),
            ),
        ],
      ),
    );
  }
}

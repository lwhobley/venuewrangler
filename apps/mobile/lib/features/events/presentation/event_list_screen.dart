import '../../../core/widgets/dialog_save_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../venues/application/venue_clock.dart';
import '../../venues/application/venues_providers.dart';
import '../../venues/presentation/venue_time_widgets.dart';
import '../application/events_providers.dart';
import '../domain/event.dart';

/// A venue's calendar of planned events. Every venue member can view; only a manager tier can
/// create/update/delete (see events_schema.sql). This is a simple event list, not the
/// reference app's full CRM/BEO "event command center" — see events_schema.sql's header
/// comment.
class EventListScreen extends ConsumerWidget {
  const EventListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final venue = ref.watch(activeVenueProvider);
    if (venue == null) {
      return const Scaffold(body: Center(child: Text('No venue selected.')));
    }

    final eventsAsync = ref.watch(eventsForVenueProvider(venue.id));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Events'),
      ),
      body: Column(
        children: [
          const UnsupportedTimezoneBanner(),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () async =>
                  ref.invalidate(eventsForVenueProvider(venue.id)),
              child: eventsAsync.when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (_, __) => Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('Could not load events.'),
                      const SizedBox(height: 12),
                      OutlinedButton(
                        onPressed: () =>
                            ref.invalidate(eventsForVenueProvider(venue.id)),
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                ),
                data: (events) {
                  if (events.isEmpty) {
                    return LayoutBuilder(
                      builder: (context, constraints) => SingleChildScrollView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        child: SizedBox(
                          height: constraints.maxHeight,
                          child: const Center(
                            child: Text('No events planned yet.'),
                          ),
                        ),
                      ),
                    );
                  }
                  return ListView(
                    children: [
                      for (final event in events) _EventTile(event: event),
                    ],
                  );
                },
              ),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showAddEventDialog(context, ref, venue.id),
        icon: const Icon(Icons.event_outlined),
        label: const Text('Add event'),
      ),
    );
  }

  Future<void> _showAddEventDialog(
    BuildContext context,
    WidgetRef ref,
    String venueId,
  ) async {
    final clock = ref.read(venueClockProvider);
    if (!ensureSupported(context, clock)) return;
    final nameController = TextEditingController();
    final notesController = TextEditingController();
    var start = clock.now;
    var end = start.add(const Duration(hours: 3));

    await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('Add event'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Event name'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: notesController,
                decoration:
                    const InputDecoration(labelText: 'Notes (optional)'),
                maxLines: 2,
              ),
              const SizedBox(height: 12),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Start'),
                subtitle: Text(VenueClock.formatWallDateTime(start)),
                trailing: const Icon(Icons.edit_calendar_outlined),
                onTap: () async {
                  final picked = await pickVenueDateTime(
                    context,
                    initial: start,
                    nowWall: clock.now,
                  );
                  if (picked != null) setState(() => start = picked);
                },
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('End'),
                subtitle: Text(VenueClock.formatWallDateTime(end)),
                trailing: const Icon(Icons.edit_calendar_outlined),
                onTap: () async {
                  final picked = await pickVenueDateTime(
                    context,
                    initial: end,
                    nowWall: clock.now,
                  );
                  if (picked != null) setState(() => end = picked);
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            DialogSaveButton(
              label: 'Add',
              validate: () => nameController.text.trim().isEmpty
                  ? 'Event name is required'
                  : !end.isAfter(start)
                      ? 'End must be after start'
                      : null,
              save: () async {
                await ref.read(eventsRepositoryProvider).createEvent(
                      venueId: venueId,
                      name: nameController.text.trim(),
                      startTime: clock.instant(start),
                      endTime: clock.instant(end),
                      notes: notesController.text.trim().isEmpty
                          ? null
                          : notesController.text.trim(),
                    );
                ref.invalidate(eventsForVenueProvider(venueId));
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _EventTile extends ConsumerWidget {
  const _EventTile({required this.event});

  final VenueEvent event;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final clock = ref.watch(venueClockProvider);
    String formatTime(DateTime value) => clock.formatDateTime(value);

    return ListTile(
      leading: Icon(_iconForStatus(event.status)),
      title: Text(event.name),
      subtitle: Text(
        '${formatTime(event.startTime)} → ${formatTime(event.endTime)}\n${event.status.name}${event.notes?.isNotEmpty == true ? '\n${event.notes}' : ''}',
      ),
      isThreeLine: true,
      trailing: IconButton(
        icon: const Icon(Icons.delete_outline),
        onPressed: () => _delete(context, ref),
      ),
    );
  }

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete event?'),
        content: Text('Delete ${event.name}?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    try {
      await ref.read(eventsRepositoryProvider).deleteEvent(event.id);
      ref.invalidate(eventsForVenueProvider(event.venueId));
    } catch (error) {
      if (!context.mounted) return;
      final message = error is PostgrestException && error.code == '42501'
          ? "You don't have permission to delete this event."
          : 'Something went wrong. Please try again.';
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  IconData _iconForStatus(EventStatus status) => switch (status) {
        EventStatus.planned => Icons.event_note_outlined,
        EventStatus.confirmed => Icons.event_available_outlined,
        EventStatus.completed => Icons.event_busy_outlined,
        EventStatus.cancelled => Icons.event_busy,
      };
}

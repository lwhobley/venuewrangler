import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../venues/application/venue_clock.dart';
import '../../venues/application/venues_providers.dart';
import '../../venues/presentation/venue_time_widgets.dart';
import '../application/events_providers.dart';
import '../domain/event.dart';
import 'event_details_sheet.dart';

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
    final added = await showDialog<bool>(
      context: context,
      builder: (_) => AddEventDialog(venueId: venueId, clock: clock),
    );
    if (added == true) ref.invalidate(eventsForVenueProvider(venueId));
  }
}

/// The "Add event" form. It saves from inside the dialog and closes only once the event is
/// stored: a blank name or a refused save is shown in place, so nothing typed is lost. Owns its
/// controllers so they are disposed only after the route has finished animating away.
class AddEventDialog extends ConsumerStatefulWidget {
  const AddEventDialog({super.key, required this.venueId, required this.clock});

  final String venueId;
  final VenueClock clock;

  @override
  ConsumerState<AddEventDialog> createState() => _AddEventDialogState();
}

class _AddEventDialogState extends ConsumerState<AddEventDialog> {
  final _name = TextEditingController();
  final _notes = TextEditingController();
  late DateTime _start = widget.clock.now;
  late DateTime _end = _start.add(const Duration(hours: 3));
  String? _nameError;
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    setState(() {
      _nameError = name.isEmpty ? 'Enter a name for the event.' : null;
      _error = !_end.isAfter(_start)
          ? 'The event end time must be after its start time.'
          : null;
    });
    if (_nameError != null || _error != null) return;
    setState(() => _saving = true);
    try {
      final notes = _notes.text.trim();
      await ref.read(eventsRepositoryProvider).createEvent(
            venueId: widget.venueId,
            name: name,
            startTime: widget.clock.instant(_start),
            endTime: widget.clock.instant(_end),
            notes: notes.isEmpty ? null : notes,
          );
      if (mounted) Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) return;
      final code = error is PostgrestException ? error.code : null;
      setState(() {
        _saving = false;
        _error = switch (code) {
          '42501' => "You don't have permission to add events here.",
          '23514' => 'The event end time must be after its start time.',
          _ => 'Could not add the event. Check your connection and try again.',
        };
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final clock = widget.clock;
    return PopScope(
      canPop: !_saving,
      child: AlertDialog(
        title: const Text('Add event'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _name,
                autofocus: true,
                enabled: !_saving,
                decoration: InputDecoration(
                  labelText: 'Event name',
                  errorText: _nameError,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _notes,
                enabled: !_saving,
                decoration: const InputDecoration(
                  labelText: 'Notes for the team (optional)',
                ),
                maxLines: 3,
              ),
              const SizedBox(height: 12),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Start'),
                subtitle: Text(VenueClock.formatWallDateTime(_start)),
                trailing: const Icon(Icons.edit_calendar_outlined),
                onTap: _saving
                    ? null
                    : () async {
                        final picked = await pickVenueDateTime(
                          context,
                          initial: _start,
                          nowWall: clock.now,
                        );
                        if (picked != null) setState(() => _start = picked);
                      },
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('End'),
                subtitle: Text(VenueClock.formatWallDateTime(_end)),
                trailing: const Icon(Icons.edit_calendar_outlined),
                onTap: _saving
                    ? null
                    : () async {
                        final picked = await pickVenueDateTime(
                          context,
                          initial: _end,
                          nowWall: clock.now,
                        );
                        if (picked != null) setState(() => _end = picked);
                      },
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    _error!,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _saving ? null : () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: _saving ? null : _save,
            child: Text(_saving ? 'Adding…' : 'Add'),
          ),
        ],
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
        '${formatTime(event.startTime)} → ${formatTime(event.endTime)}\n${event.status.name}',
      ),
      isThreeLine: true,
      // Opens the times and the notes left for the team (launch review D5).
      onTap: () => showEventDetailsSheet(context, event),
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

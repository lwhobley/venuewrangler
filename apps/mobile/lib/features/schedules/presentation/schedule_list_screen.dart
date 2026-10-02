import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/errors/app_error.dart';
import '../../ai/application/ai_providers.dart';
import '../../ai/domain/ai_models.dart';
import '../../venues/application/venues_providers.dart';
import '../application/schedules_providers.dart';
import '../domain/shift.dart';

/// Shift schedule for the active venue. Every venue member can view; only a manager tier can
/// create/delete (see schedules_schema.sql). The AI "Suggest coverage" action is advisory
/// only — every suggestion still goes through the same manual "Add shift" dialog a manager
/// would use anyway, satisfying features/ai/README.md's manual-fallback requirement.
class ScheduleListScreen extends ConsumerWidget {
  const ScheduleListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final venue = ref.watch(activeVenueProvider);
    if (venue == null) {
      return const Scaffold(body: Center(child: Text('No venue selected.')));
    }

    final shiftsAsync = ref.watch(shiftsForVenueProvider(venue.id));

    return Scaffold(
      appBar: AppBar(title: Text('Schedule — ${venue.name}')),
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(shiftsForVenueProvider(venue.id)),
        child: shiftsAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (_, __) => Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Could not load the schedule.'),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: () => ref.invalidate(shiftsForVenueProvider(venue.id)),
                  child: const Text('Retry'),
                ),
              ],
            ),
          ),
          data: (shifts) {
            if (shifts.isEmpty) {
              return LayoutBuilder(
                builder: (context, constraints) => SingleChildScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  child: SizedBox(
                    height: constraints.maxHeight,
                    child: const Center(child: Text('No shifts scheduled yet.')),
                  ),
                ),
              );
            }
            return ListView(
              children: [
                for (final shift in shifts) _ShiftTile(shift: shift),
              ],
            );
          },
        ),
      ),
      floatingActionButton: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          FloatingActionButton.extended(
            heroTag: 'suggest-coverage',
            onPressed: () => _showSuggestDialog(context, ref, venue.id),
            icon: const Icon(Icons.auto_awesome_outlined),
            label: const Text('Suggest coverage'),
          ),
          const SizedBox(height: 12),
          FloatingActionButton.extended(
            heroTag: 'add-shift',
            onPressed: () => _showAddShiftDialog(context, ref, venue.id),
            icon: const Icon(Icons.add),
            label: const Text('Add shift'),
          ),
        ],
      ),
    );
  }

  Future<void> _showAddShiftDialog(
    BuildContext context,
    WidgetRef ref,
    String venueId, {
    String? prefillStaffId,
    String? prefillRoleLabel,
    DateTime? prefillStart,
    DateTime? prefillEnd,
  }) async {
    final staffIdController = TextEditingController(text: prefillStaffId);
    final roleLabelController = TextEditingController(text: prefillRoleLabel);
    var start = prefillStart ?? DateTime.now();
    var end = prefillEnd ?? start.add(const Duration(hours: 4));

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('Add shift'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: staffIdController,
                decoration: const InputDecoration(
                  labelText: 'Staff user ID (optional — leave blank for an open shift)',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: roleLabelController,
                decoration: const InputDecoration(labelText: 'Role (e.g. bartender)'),
              ),
              const SizedBox(height: 12),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Start'),
                subtitle: Text(start.toString()),
                trailing: const Icon(Icons.edit_calendar_outlined),
                onTap: () async {
                  final picked = await _pickDateTime(context, start);
                  if (picked != null) setState(() => start = picked);
                },
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('End'),
                subtitle: Text(end.toString()),
                trailing: const Icon(Icons.edit_calendar_outlined),
                onTap: () async {
                  final picked = await _pickDateTime(context, end);
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
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );

    if (confirmed != true || !context.mounted) return;

    try {
      await ref.read(schedulesRepositoryProvider).createShift(
            venueId: venueId,
            staffId:
                staffIdController.text.trim().isEmpty ? null : staffIdController.text.trim(),
            roleLabel:
                roleLabelController.text.trim().isEmpty ? null : roleLabelController.text.trim(),
            startTime: start,
            endTime: end,
          );
      ref.invalidate(shiftsForVenueProvider(venueId));
    } on PostgrestException catch (error) {
      if (!context.mounted) return;
      final message = switch (error.code) {
        '42501' => "You don't have permission to schedule shifts here.",
        '23514' => 'The shift end time must be after its start time.',
        _ => 'Something went wrong. Please try again.',
      };
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<DateTime?> _pickDateTime(BuildContext context, DateTime initial) async {
    final date = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime.now().subtract(const Duration(days: 1)),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (date == null || !context.mounted) return null;

    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
    );
    if (time == null) return null;

    return DateTime(date.year, date.month, date.day, time.hour, time.minute);
  }

  Future<void> _showSuggestDialog(BuildContext context, WidgetRef ref, String venueId) async {
    final textController = TextEditingController();

    final context_ = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Suggest shift coverage'),
        content: TextField(
          controller: textController,
          autofocus: true,
          maxLines: 8,
          decoration: const InputDecoration(
            hintText: 'Describe the roster, target headcount, and any constraints '
                '(time-off requests, required roles)…',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(textController.text.trim()),
            child: const Text('Suggest'),
          ),
        ],
      ),
    );

    if (context_ == null || context_.isEmpty || !context.mounted) return;

    SchedulingSuggestionResult result;
    try {
      result = await ref
          .read(aiRepositoryProvider)
          .suggestScheduling(venueId: venueId, context: context_);
    } on AppError catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.message)));
      return;
    }

    if (!context.mounted) return;
    if (result.suggestions.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No suggestions could be made from that description.')),
      );
      return;
    }

    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Review suggestions'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final suggestion in result.suggestions)
                ListTile(
                  title: Text('Staff: ${suggestion.staffId}'),
                  subtitle: Text(
                    [
                      if (suggestion.startTime != null && suggestion.endTime != null)
                        '${suggestion.startTime} → ${suggestion.endTime}',
                      suggestion.reason,
                    ].join('\n'),
                  ),
                  isThreeLine: true,
                  trailing: TextButton(
                    onPressed: () {
                      Navigator.of(context).pop();
                      _showAddShiftDialog(
                        context,
                        ref,
                        venueId,
                        prefillStaffId: suggestion.staffId,
                        prefillStart: DateTime.tryParse(suggestion.startTime ?? ''),
                        prefillEnd: DateTime.tryParse(suggestion.endTime ?? ''),
                      );
                    },
                    child: const Text('Add'),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}

class _ShiftTile extends ConsumerWidget {
  const _ShiftTile({required this.shift});

  final Shift shift;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListTile(
      leading: const Icon(Icons.schedule_outlined),
      title: Text(shift.roleLabel ?? 'Shift'),
      subtitle: Text(
        '${shift.startTime} → ${shift.endTime}'
        '${shift.staffId != null ? '\nStaff: ${shift.staffId}' : '\n(open shift)'}',
      ),
      isThreeLine: true,
      trailing: IconButton(
        icon: const Icon(Icons.delete_outline),
        onPressed: () => _delete(context, ref),
      ),
    );
  }

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    try {
      await ref.read(schedulesRepositoryProvider).deleteShift(shift.id);
      ref.invalidate(shiftsForVenueProvider(shift.venueId));
    } on PostgrestException catch (error) {
      if (!context.mounted) return;
      final message = error.code == '42501'
          ? "You don't have permission to delete this shift."
          : 'Something went wrong. Please try again.';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    }
  }
}

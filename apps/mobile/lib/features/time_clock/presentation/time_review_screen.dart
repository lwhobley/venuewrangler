import 'dart:convert';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/network/supabase_providers.dart';
import '../../schedules/application/schedules_providers.dart';
import '../../workforce/domain/workforce_models.dart';
import '../../venues/application/venue_clock.dart';
import '../../venues/application/venues_providers.dart';
import '../../venues/presentation/venue_time_widgets.dart';
import '../application/time_clock_providers.dart';
import '../data/time_review_repository.dart';
import '../domain/time_entry.dart';

final timeReviewRepositoryProvider =
    Provider((ref) => TimeReviewRepository(ref.watch(supabaseClientProvider)));
final timeReviewEntriesProvider = FutureProvider.autoDispose
    .family<List<TimeEntry>, ({String venueId, DateTime from, DateTime to})>(
  (ref, key) => ref
      .watch(timeReviewRepositoryProvider)
      .entries(key.venueId, key.from, key.to),
);

class TimeReviewScreen extends ConsumerStatefulWidget {
  const TimeReviewScreen({super.key});
  @override
  ConsumerState<TimeReviewScreen> createState() => _TimeReviewScreenState();
}

class _TimeReviewScreenState extends ConsumerState<TimeReviewScreen> {
  DateTime? _month;
  @override
  Widget build(BuildContext context) {
    final venue = ref.watch(activeVenueProvider);
    final clock = ref.watch(venueClockProvider);
    if (venue == null ||
        ref.watch(canManageActiveVenueProvider).valueOrNull != true) {
      return const Scaffold(
        body: Center(child: Text('Manager access required.')),
      );
    }
    final month = _month ?? DateTime.utc(clock.now.year, clock.now.month);
    final key = (
      venueId: venue.id,
      from: clock.instant(month),
      to: clock.instant(DateTime.utc(month.year, month.month + 1))
    );
    final entries = ref.watch(timeReviewEntriesProvider(key));
    final roster = ref.watch(scheduleRosterForVenueProvider(venue.id));
    final names = <String, String>{
      for (final m in roster.valueOrNull ?? const <RosterMember>[])
        m.userId: m.displayName ?? 'Team member',
    };
    return Scaffold(
      appBar: AppBar(
        title: const Text('Hours and payroll'),
        actions: [
          IconButton(
            icon: const Icon(Icons.download),
            tooltip: 'Export CSV',
            onPressed: entries.hasValue && roster.hasValue
                ? () async {
                    try {
                      await FilePicker.platform.saveFile(
                        dialogTitle: 'Export hours',
                        fileName: 'hours-${month.year}-${month.month}.csv',
                        bytes: Uint8List.fromList(
                          utf8.encode(
                            hoursCsv(
                              entries.requireValue,
                              names,
                              clock.formatDateTime,
                            ),
                          ),
                        ),
                      );
                    } catch (_) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                              'Could not export hours. Please try again.',
                            ),
                          ),
                        );
                      }
                    }
                  }
                : null,
          ),
        ],
      ),
      body: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                icon: const Icon(Icons.chevron_left),
                onPressed: () => setState(
                  () => _month = DateTime.utc(month.year, month.month - 1),
                ),
              ),
              Text(
                '${month.year}-${month.month.toString().padLeft(2, '0')} - ${venue.timezone}',
              ),
              IconButton(
                icon: const Icon(Icons.chevron_right),
                onPressed: () => setState(
                  () => _month = DateTime.utc(month.year, month.month + 1),
                ),
              ),
            ],
          ),
          const Padding(
            padding: EdgeInsets.all(8),
            child: Text(
              'Open punches are provisional. Export includes unpaid-break deductions.',
            ),
          ),
          Expanded(
            child: entries.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (_, __) => Center(
                child: TextButton(
                  onPressed: () =>
                      ref.invalidate(timeReviewEntriesProvider(key)),
                  child: const Text('Could not load hours. Retry'),
                ),
              ),
              data: (rows) => rows.isEmpty
                  ? const Center(child: Text('No punches in this month.'))
                  : ListView(
                      children: [
                        for (final e in rows)
                          ListTile(
                            title: Text(names[e.userId] ?? 'Team member'),
                            subtitle: Text(
                              '${clock.formatDateTime(e.clockInAt)} to ${e.clockOutAt == null ? 'Open' : clock.formatDateTime(e.clockOutAt!)}\n${(e.workedDuration.inMinutes / 60).toStringAsFixed(2)} hours',
                            ),
                            isThreeLine: true,
                            trailing: TextButton(
                              onPressed: () async {
                                final picked = await pickVenueDateTime(
                                  context,
                                  initial: clock
                                      .wall(e.clockOutAt ?? DateTime.now()),
                                  nowWall: clock.now,
                                );
                                if (picked == null || !context.mounted) return;
                                final reason = await showDialog<String>(
                                  context: context,
                                  builder: (_) => const _CorrectionReason(),
                                );
                                if (reason == null) return;
                                try {
                                  await ref
                                      .read(timeReviewRepositoryProvider)
                                      .correct(
                                        e.id,
                                        clock.instant(picked),
                                        reason,
                                      );
                                  ref.invalidate(
                                    timeReviewEntriesProvider(key),
                                  );
                                  ref.invalidate(
                                    venueClockBoardProvider(venue.id),
                                  );
                                } catch (_) {
                                  if (context.mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                        content: Text(
                                          'Correction failed. Use an end after clock-in and before now. You cannot correct your own punch.',
                                        ),
                                      ),
                                    );
                                  }
                                }
                              },
                              child: const Text('Correct'),
                            ),
                          ),
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CorrectionReason extends StatefulWidget {
  const _CorrectionReason();
  @override
  State<_CorrectionReason> createState() => _CorrectionReasonState();
}

class _CorrectionReasonState extends State<_CorrectionReason> {
  final controller = TextEditingController();
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Reason for correction'),
        content: TextField(
          controller: controller,
          maxLength: 500,
          onChanged: (_) => setState(() {}),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: controller.text.trim().isEmpty
                ? null
                : () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Save correction'),
          ),
        ],
      );
}

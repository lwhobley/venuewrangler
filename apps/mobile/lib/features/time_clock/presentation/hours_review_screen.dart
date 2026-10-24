import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/auth_providers.dart';
import '../../../core/errors/app_error.dart';
import '../../../core/files/text_file_saver.dart';
import '../../../core/theme/app_radii.dart';
import '../../../core/theme/ops_colors.dart';
import '../../../core/widgets/status_chip.dart';
import '../../venues/application/venue_clock.dart';
import '../../venues/application/venues_providers.dart';
import '../../venues/domain/venue_timezone.dart';
import '../../venues/presentation/venue_time_widgets.dart';
import '../application/timesheet_providers.dart';
import '../domain/timesheet.dart';
import '../domain/timesheet_csv.dart';
import 'correct_clock_out_dialog.dart';

/// Route of [HoursReviewScreen] (registered in app/router.dart).
const hoursReviewRoute = '/time-clock/hours';

enum _Preset { thisWeek, lastWeek, custom }

/// Managers: hours worked per person for a date range (venue time), every punch behind them,
/// missed clock-outs to close, the correction history, and CSV exports for payroll.
class HoursReviewScreen extends ConsumerStatefulWidget {
  const HoursReviewScreen({super.key});

  @override
  ConsumerState<HoursReviewScreen> createState() => _HoursReviewScreenState();
}

class _HoursReviewScreenState extends ConsumerState<HoursReviewScreen> {
  _Preset _preset = _Preset.thisWeek;
  TimesheetRange? _custom;

  TimesheetRange _range(VenueClock clock) => switch (_preset) {
        _Preset.thisWeek => TimesheetRange.week(clock),
        _Preset.lastWeek => TimesheetRange.week(clock, weeksAgo: 1),
        _Preset.custom => _custom ?? TimesheetRange.week(clock),
      };

  Future<void> _pickCustom(VenueClock clock) async {
    final now = clock.now;
    final today = DateTime(now.year, now.month, now.day);
    final current = _range(clock);
    final picked = await showDateRangePicker(
      context: context,
      firstDate: today.subtract(const Duration(days: 3 * 365)),
      lastDate: today,
      initialDateRange: DateTimeRange(
        start: DateTime(
          current.startWall.year,
          current.startWall.month,
          current.startWall.day,
        ),
        end: DateTime(
          current.endWall.year,
          current.endWall.month,
          current.endWall.day,
        ),
      ),
    );
    if (picked == null || !mounted) return;
    if (picked.end.difference(picked.start).inDays > 92) {
      _snack('Choose a range of up to 93 days.');
      return;
    }
    setState(() {
      _preset = _Preset.custom;
      _custom = TimesheetRange.days(picked.start, picked.end, clock);
    });
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _export({
    required bool summaryOnly,
    required HoursSummary summary,
    required TimesheetRange range,
  }) async {
    final venue = ref.read(activeVenueProvider);
    final clock = ref.read(venueClockProvider);
    if (venue == null) return;
    if (summary.people.isEmpty) {
      _snack('No punches in this range to export.');
      return;
    }
    final contents = summaryOnly
        ? timesheetSummaryCsv(
            summary: summary,
            range: range,
            venueName: venue.name,
            timezoneId: clock.timezoneId,
          )
        : timesheetEntriesCsv(
            summary: summary,
            clock: clock,
            venueName: venue.name,
          );
    try {
      final saved = await ref.read(textFileSaverProvider).save(
            fileName: timesheetFileName(
              venue.name,
              range,
              summaryOnly ? 'hours-summary' : 'hours',
            ),
            contents: contents,
          );
      if (saved && mounted) {
        _snack(
          summary.openCount > 0
              ? 'Exported. ${summary.openCount} open punch(es) have no hours until closed.'
              : 'Exported.',
        );
      }
    } catch (_) {
      if (mounted) _snack('Could not save the file. Try again.');
    }
  }

  Future<void> _correct(TimesheetEntry entry, TimesheetQuery query) async {
    if (entry.userId == ref.read(currentUserIdProvider)) {
      _snack('Managers cannot change their own punches. Ask another manager.');
      return;
    }
    final saved = await CorrectClockOutDialog.show(
      context,
      timeEntryId: entry.id,
      personName: entry.name,
      clockInAt: entry.clockInAt,
      clockOutAt: entry.clockOutAt,
    );
    if (!saved || !mounted) return;
    ref.invalidate(timesheetProvider(query));
    ref.invalidate(venueClockBoardProvider(query.venueId));
    _snack('Punch updated.');
  }

  @override
  Widget build(BuildContext context) {
    final venue = ref.watch(activeVenueProvider);
    if (venue == null) {
      return const Scaffold(body: Center(child: Text('No venue selected.')));
    }
    final clock = ref.watch(venueClockProvider);
    final range = _range(clock);
    final query = (venueId: venue.id, range: range);
    final entriesAsync = ref.watch(timesheetProvider(query));
    final summary = entriesAsync.whenOrNull(
      data: (entries) => summarizeHours(entries, clock),
    );
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Hours'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: () => ref.invalidate(timesheetProvider(query)),
          ),
          PopupMenuButton<bool>(
            tooltip: 'Export for payroll',
            icon: const Icon(Icons.download_outlined),
            enabled: summary != null,
            onSelected: (summaryOnly) => _export(
              summaryOnly: summaryOnly,
              summary: summary!,
              range: range,
            ),
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: false,
                child: Text('Export punches (CSV)'),
              ),
              PopupMenuItem(
                value: true,
                child: Text('Export totals per person (CSV)'),
              ),
            ],
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(timesheetProvider(query)),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            const UnsupportedTimezoneBanner(),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ChoiceChip(
                  label: const Text('This week'),
                  selected: _preset == _Preset.thisWeek,
                  onSelected: (_) => setState(() => _preset = _Preset.thisWeek),
                ),
                ChoiceChip(
                  label: const Text('Last week'),
                  selected: _preset == _Preset.lastWeek,
                  onSelected: (_) => setState(() => _preset = _Preset.lastWeek),
                ),
                ChoiceChip(
                  label: const Text('Custom…'),
                  selected: _preset == _Preset.custom,
                  onSelected: (_) => _pickCustom(clock),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '${VenueTimezone.formatWallDate(range.startWall)} – '
              '${VenueTimezone.formatWallDate(range.endWall)} · venue time (${clock.timezoneId})',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            entriesAsync.when(
              loading: () => const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (error, _) => _Message(
                error is AppError ? error.message : 'Could not load hours.',
                onRetry: () => ref.invalidate(timesheetProvider(query)),
              ),
              data: (_) => _Body(
                summary: summary!,
                clock: clock,
                onCorrect: (e) => _correct(e, query),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({
    required this.summary,
    required this.clock,
    required this.onCorrect,
  });

  final HoursSummary summary;
  final VenueClock clock;
  final ValueChanged<TimesheetEntry> onCorrect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (summary.people.isEmpty) {
      return const _Message('No punches in this range.');
    }
    final open = [
      for (final p in summary.people)
        for (final e in p.entries)
          if (e.isOpen) e,
    ]..sort((a, b) => a.clockInAt.compareTo(b.clockInAt));
    final overtime = summary.people.fold(0, (s, p) => s + p.overtimeMinutes);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: _Stat(
                label: 'Hours worked',
                value: formatHoursMinutes(summary.totalMinutes),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _Stat(
                label: 'Overtime',
                value: formatHoursMinutes(overtime),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _Stat(label: 'People', value: '${summary.people.length}'),
            ),
          ],
        ),
        if (open.isNotEmpty) ...[
          const SizedBox(height: 20),
          Text('Still clocked in', style: theme.textTheme.titleMedium),
          Text(
            'Close a missed clock-out so its hours count. Open punches are '
            'left out of the totals and exports.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          for (final e in open)
            Card(
              color: context.ops.warning.bg,
              child: ListTile(
                leading:
                    Icon(Icons.timer_outlined, color: context.ops.warning.fg),
                title: Text(e.name),
                subtitle: Text(
                  'Since ${clock.formatDateTime(e.clockInAt)} · '
                  '${formatHoursMinutes(e.workedMinutes())} so far',
                ),
                trailing: TextButton(
                  onPressed: () => onCorrect(e),
                  child: const Text('Close'),
                ),
              ),
            ),
        ],
        const SizedBox(height: 20),
        Text('By person', style: theme.textTheme.titleMedium),
        Text(
          'Overtime is time over 40 hours in a Monday–Sunday week.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        for (final p in summary.people)
          _PersonCard(
            person: p,
            summary: summary,
            clock: clock,
            onCorrect: onCorrect,
          ),
      ],
    );
  }
}

class _PersonCard extends StatelessWidget {
  const _PersonCard({
    required this.person,
    required this.summary,
    required this.clock,
    required this.onCorrect,
  });

  final PersonHours person;
  final HoursSummary summary;
  final VenueClock clock;
  final ValueChanged<TimesheetEntry> onCorrect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final closed = person.entries.length - person.openCount;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        shape: const Border(),
        title: Text(person.name, style: theme.textTheme.titleMedium),
        subtitle: Text(
          '$closed punch${closed == 1 ? '' : 'es'}'
          '${person.overtimeMinutes > 0 ? ' · ${formatHoursMinutes(person.overtimeMinutes)} overtime' : ''}'
          '${person.openCount > 0 ? ' · ${person.openCount} open' : ''}'
          '${person.editedCount > 0 ? ' · ${person.editedCount} edited' : ''}',
        ),
        trailing: Text(
          formatHoursMinutes(person.workedMinutes),
          style: theme.textTheme.titleLarge,
        ),
        children: [
          for (final e in person.entries)
            _EntryTile(
              entry: e,
              hours: summary.byEntry[e.id],
              clock: clock,
              onCorrect: () => onCorrect(e),
            ),
        ],
      ),
    );
  }
}

class _EntryTile extends StatelessWidget {
  const _EntryTile({
    required this.entry,
    required this.hours,
    required this.clock,
    required this.onCorrect,
  });

  final TimesheetEntry entry;
  final EntryHours? hours;
  final VenueClock clock;
  final VoidCallback onCorrect;

  @override
  Widget build(BuildContext context) {
    final out = entry.clockOutAt;
    final unpaid = entry.unpaidBreakMinutes();
    return ListTile(
      title: Text(
        '${clock.formatDate(entry.clockInAt)} · ${clock.formatTime(entry.clockInAt)}'
        ' – ${out == null ? 'open' : clock.formatTime(out)}',
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            entry.isOpen
                ? '${formatHoursMinutes(entry.workedMinutes())} so far'
                : '${formatHoursMinutes(entry.workedMinutes())} worked'
                    '${unpaid > 0 ? ' · $unpaid min unpaid break' : ''}'
                    '${(hours?.overtime ?? 0) > 0 ? ' · ${formatHoursMinutes(hours!.overtime)} overtime' : ''}',
          ),
          if (entry.isEdited || entry.isOpen || entry.isUnverified) ...[
            const SizedBox(height: 4),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                if (entry.isOpen)
                  const StatusChip(
                    label: 'Missing clock-out',
                    tone: Tone.warning,
                    dense: true,
                  ),
                if (entry.isEdited)
                  InkWell(
                    borderRadius: BorderRadius.circular(AppRadii.pill),
                    onTap: () => _showHistory(context),
                    child: const StatusChip(
                      label: 'Edited',
                      tone: Tone.info,
                      dense: true,
                    ),
                  ),
                if (entry.isUnverified)
                  const StatusChip(
                    label: 'Unverified device',
                    tone: Tone.neutral,
                    dense: true,
                  ),
              ],
            ),
          ],
        ],
      ),
      trailing: IconButton(
        tooltip: entry.isOpen ? 'Close missed clock-out' : 'Fix clock-out',
        icon: const Icon(Icons.edit_calendar_outlined),
        onPressed: onCorrect,
      ),
    );
  }

  void _showHistory(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Changes to this punch'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final c in entry.corrections) ...[
                Text(
                  '${c.byLabel} · ${clock.formatDateTime(c.correctedAt)}',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                Text(
                  'Clock-out: ${c.clockOutBefore == null ? 'missing' : clock.formatDateTime(c.clockOutBefore!)}'
                  ' → ${c.clockOutAfter == null ? 'missing' : clock.formatDateTime(c.clockOutAfter!)}'
                  '${c.breaksChanged ? ' (open break closed)' : ''}',
                ),
                if (c.reason != null && c.reason!.isNotEmpty)
                  Text('Reason: ${c.reason}'),
                const SizedBox(height: 12),
              ],
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

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(AppRadii.tile),
        border: Border.all(color: context.ops.panelBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(value, style: theme.textTheme.titleLarge),
          Text(label, style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message(this.text, {this.onRetry});

  final String text;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            Text(text, textAlign: TextAlign.center),
            if (onRetry != null) ...[
              const SizedBox(height: 12),
              OutlinedButton(onPressed: onRetry, child: const Text('Retry')),
            ],
          ],
        ),
      ),
    );
  }
}

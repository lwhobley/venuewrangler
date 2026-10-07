import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/ops_colors.dart';
import '../../../core/widgets/status_chip.dart';

import '../../../core/errors/app_error.dart';
import '../../venues/application/venues_providers.dart';
import '../application/time_clock_providers.dart';
import '../domain/time_entry.dart';

class TimeClockScreen extends ConsumerStatefulWidget {
  const TimeClockScreen({super.key});

  @override
  ConsumerState<TimeClockScreen> createState() => _TimeClockScreenState();
}

class _TimeClockScreenState extends ConsumerState<TimeClockScreen> {
  Timer? _ticker;
  int _selectedTab = 0; // 0: My Time Clock, 1: Clock Board
  bool _isProcessing = false;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  Future<void> _handleClockIn(String venueId) async {
    setState(() => _isProcessing = true);
    try {
      final repo = ref.read(timeClockRepositoryProvider);
      final fix = await ref.read(locationServiceProvider).currentFix();
      await repo.clockIn(
        venueId: venueId,
        lat: fix.lat,
        lng: fix.lng,
        accuracyM: fix.accuracyM,
        mocked: fix.mocked,
      );
      _refresh(venueId);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Clocked in successfully.')),
        );
      }
    } on AppError catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              e.message,
              style: TextStyle(color: Theme.of(context).colorScheme.onError),
            ),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  Future<void> _handleClockOut(TimeEntry activeEntry, String venueId) async {
    setState(() => _isProcessing = true);
    try {
      final repo = ref.read(timeClockRepositoryProvider);
      final fix = await ref.read(locationServiceProvider).currentFix();
      await repo.clockOut(
        entryId: activeEntry.id,
        lat: fix.lat,
        lng: fix.lng,
        accuracyM: fix.accuracyM,
        mocked: fix.mocked,
      );
      _refresh(venueId);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Clocked out successfully.')),
        );
      }
    } on AppError catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              e.message,
              style: TextStyle(color: Theme.of(context).colorScheme.onError),
            ),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  Future<void> _handleStartBreak(TimeEntry activeEntry, String venueId) async {
    final type = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Start Break'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop('paid'),
            child: ListTile(
              leading: Icon(Icons.coffee, color: context.ops.info.fg),
              title: const Text('Paid Break (15 min)'),
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop('unpaid'),
            child: ListTile(
              leading: Icon(Icons.restaurant, color: context.ops.warning.fg),
              title: const Text('Unpaid Meal Break (30+ min)'),
            ),
          ),
        ],
      ),
    );

    if (type == null) return;

    setState(() => _isProcessing = true);
    try {
      final repo = ref.read(timeClockRepositoryProvider);
      await repo.startBreak(entry: activeEntry, type: type);
      _refresh(venueId);
    } on AppError catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              e.message,
              style: TextStyle(color: Theme.of(context).colorScheme.onError),
            ),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  Future<void> _handleEndBreak(TimeEntry activeEntry, String venueId) async {
    setState(() => _isProcessing = true);
    try {
      final repo = ref.read(timeClockRepositoryProvider);
      await repo.endBreak(entry: activeEntry);
      _refresh(venueId);
    } on AppError catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              e.message,
              style: TextStyle(color: Theme.of(context).colorScheme.onError),
            ),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  void _refresh(String venueId) {
    ref.invalidate(activeTimeEntryProvider(venueId));
    ref.invalidate(myTimeEntriesProvider(venueId));
    ref.invalidate(venueClockBoardProvider(venueId));
  }

  String _formatDuration(Duration d) {
    final hours = d.inHours.toString().padLeft(2, '0');
    final minutes = (d.inMinutes % 60).toString().padLeft(2, '0');
    final seconds = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$hours:$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final venue = ref.watch(activeVenueProvider);
    if (venue == null) {
      return const Scaffold(
        body: Center(child: Text('No venue selected.')),
      );
    }

    final activeEntryAsync = ref.watch(activeTimeEntryProvider(venue.id));
    final myEntriesAsync = ref.watch(myTimeEntriesProvider(venue.id));
    final boardAsync = ref.watch(venueClockBoardProvider(venue.id));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Time Clock'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: () => _refresh(venue.id),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async => _refresh(venue.id),
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Segmented switch between My Punch and Clock Board
              SegmentedButton<int>(
                segments: const [
                  ButtonSegment(
                    value: 0,
                    icon: Icon(Icons.timer_outlined),
                    label: Text('My Time Clock'),
                  ),
                  ButtonSegment(
                    value: 1,
                    icon: Icon(Icons.people_outline),
                    label: Text('Clock Board'),
                  ),
                ],
                selected: {_selectedTab},
                onSelectionChanged: (val) =>
                    setState(() => _selectedTab = val.first),
              ),
              const SizedBox(height: 16),

              if (_selectedTab == 0) ...[
                // Active Punch Status Banner
                activeEntryAsync.when(
                  loading: () => const Center(
                    child: Padding(
                      padding: EdgeInsets.all(32),
                      child: CircularProgressIndicator(),
                    ),
                  ),
                  error: (error, _) => Card(
                    color: context.ops.danger.bg,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text('Error loading clock status: $error'),
                    ),
                  ),
                  data: (activeEntry) {
                    final isClockedIn = activeEntry != null;
                    final isOnBreak = activeEntry?.isOnBreak ?? false;

                    final statusColor = isOnBreak
                        ? context.ops.warning.fg
                        : isClockedIn
                            ? context.ops.success.fg
                            : context.ops.neutral.fg;

                    final statusText = isOnBreak
                        ? 'ON BREAK'
                        : isClockedIn
                            ? 'CLOCKED IN'
                            : 'CLOCKED OUT';

                    return Card(
                      elevation: 2,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                        side: BorderSide(
                          color: statusColor.withAlpha(80),
                          width: 1.5,
                        ),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          vertical: 24,
                          horizontal: 20,
                        ),
                        child: Column(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 6,
                              ),
                              decoration: BoxDecoration(
                                color: statusColor.withAlpha(25),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Text(
                                statusText,
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                  color: statusColor,
                                  letterSpacing: 1.2,
                                ),
                              ),
                            ),
                            const SizedBox(height: 16),
                            Text(
                              // The actual (local) time, ticking live via _ticker — not
                              // hours worked, which the "Shift elapsed" line and Recent
                              // Punches below already cover.
                              _formatClockFace(DateTime.now()),
                              style: const TextStyle(
                                fontSize: 48,
                                fontWeight: FontWeight.w800,
                                fontFamily: 'monospace',
                              ),
                            ),
                            if (isClockedIn) ...[
                              const SizedBox(height: 4),
                              Text(
                                'Shift elapsed: ${_formatDuration(activeEntry.totalElapsed)}',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant,
                                ),
                              ),
                              if (isOnBreak &&
                                  activeEntry.activeBreak != null) ...[
                                const SizedBox(height: 2),
                                Text(
                                  'Current ${activeEntry.activeBreak!.type} break: ${_formatDuration(activeEntry.activeBreak!.duration)}',
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    color: context.ops.warning.fg,
                                  ),
                                ),
                              ],
                            ],
                            const SizedBox(height: 24),
                            // Action Buttons
                            if (!isClockedIn) ...[
                              FilledButton.icon(
                                onPressed: _isProcessing
                                    ? null
                                    : () => _handleClockIn(venue.id),
                                icon: const Icon(Icons.login),
                                label: const Text('Clock In'),
                                style: FilledButton.styleFrom(
                                  backgroundColor: context.ops.success.fg,
                                  foregroundColor:
                                      Theme.of(context).colorScheme.surface,
                                  minimumSize: const Size.fromHeight(50),
                                ),
                              ),
                            ] else ...[
                              Row(
                                children: [
                                  Expanded(
                                    child: OutlinedButton.icon(
                                      onPressed: _isProcessing
                                          ? null
                                          : () => isOnBreak
                                              ? _handleEndBreak(
                                                  activeEntry,
                                                  venue.id,
                                                )
                                              : _handleStartBreak(
                                                  activeEntry,
                                                  venue.id,
                                                ),
                                      icon: Icon(
                                        isOnBreak
                                            ? Icons.play_arrow
                                            : Icons.pause,
                                      ),
                                      label: Text(
                                        isOnBreak ? 'End Break' : 'Take Break',
                                      ),
                                      style: OutlinedButton.styleFrom(
                                        minimumSize: const Size.fromHeight(48),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: FilledButton.icon(
                                      onPressed: _isProcessing
                                          ? null
                                          : () => _handleClockOut(
                                                activeEntry,
                                                venue.id,
                                              ),
                                      icon: const Icon(Icons.logout),
                                      label: const Text('Clock Out'),
                                      style: FilledButton.styleFrom(
                                        backgroundColor:
                                            Theme.of(context).colorScheme.error,
                                        foregroundColor: Theme.of(context)
                                            .colorScheme
                                            .onError,
                                        minimumSize: const Size.fromHeight(48),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ],
                        ),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 24),

                // Recent Punches Section
                const Text(
                  'Recent Punches',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                myEntriesAsync.when(
                  loading: () => const Center(
                    child: Padding(
                      padding: EdgeInsets.all(16),
                      child: CircularProgressIndicator(),
                    ),
                  ),
                  error: (error, _) => Text('Could not load history: $error'),
                  data: (entries) {
                    if (entries.isEmpty) {
                      return const Card(
                        child: Padding(
                          padding: EdgeInsets.all(24),
                          child: Center(
                            child: Text('No punch history recorded yet.'),
                          ),
                        ),
                      );
                    }

                    return ListView.separated(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: entries.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                      itemBuilder: (context, index) {
                        final entry = entries[index];
                        final inTime = entry.clockInAt.toLocal();
                        final outTime = entry.clockOutAt?.toLocal();

                        return Card(
                          elevation: 1,
                          child: ListTile(
                            leading: CircleAvatar(
                              backgroundColor: entry.isOpen
                                  ? context.ops.success.bg
                                  : context.ops.neutral.bg,
                              child: Icon(
                                entry.isOpen ? Icons.timer : Icons.done,
                                color: entry.isOpen
                                    ? context.ops.success.fg
                                    : context.ops.neutral.fg,
                              ),
                            ),
                            title: Text(
                              '${inTime.month}/${inTime.day} — ${_formatDuration(entry.workedDuration)}',
                              style:
                                  const TextStyle(fontWeight: FontWeight.bold),
                            ),
                            subtitle: Text(
                              'In: ${_formatTime(inTime)} • Out: ${outTime != null ? _formatTime(outTime) : 'Active'}',
                            ),
                            trailing: entry.locationAnomaly != null
                                ? const StatusChip(
                                    label: 'Flagged Fix',
                                    tone: Tone.warning,
                                    dense: true,
                                  )
                                : null,
                          ),
                        );
                      },
                    );
                  },
                ),
              ] else ...[
                // Clock Board (Active Staff on Duty)
                const Text(
                  'Active Staff on Duty',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                boardAsync.when(
                  loading: () => const Center(
                    child: Padding(
                      padding: EdgeInsets.all(16),
                      child: CircularProgressIndicator(),
                    ),
                  ),
                  error: (error, _) =>
                      Text('Could not load clock board: $error'),
                  data: (entries) {
                    final openEntries = entries.where((e) => e.isOpen).toList();
                    if (openEntries.isEmpty) {
                      return const Card(
                        child: Padding(
                          padding: EdgeInsets.all(24),
                          child: Center(
                            child: Text('No staff currently clocked in.'),
                          ),
                        ),
                      );
                    }

                    return ListView.separated(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: openEntries.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                      itemBuilder: (context, index) {
                        final entry = openEntries[index];
                        return Card(
                          elevation: 1,
                          child: ListTile(
                            leading: CircleAvatar(
                              backgroundColor: entry.isOnBreak
                                  ? context.ops.warning.bg
                                  : context.ops.success.bg,
                              child: Icon(
                                entry.isOnBreak ? Icons.coffee : Icons.person,
                                color: entry.isOnBreak
                                    ? context.ops.warning.fg
                                    : context.ops.success.fg,
                              ),
                            ),
                            title: Text(
                              'Staff ID: ${entry.userId.substring(0, 8)}...',
                              style:
                                  const TextStyle(fontWeight: FontWeight.bold),
                            ),
                            subtitle: Text(
                              entry.isOnBreak
                                  ? 'On Break (${entry.activeBreak?.type})'
                                  : 'Clocked in at ${_formatTime(entry.clockInAt.toLocal())}',
                            ),
                            trailing: Text(
                              _formatDuration(entry.workedDuration),
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                                fontFamily: 'monospace',
                              ),
                            ),
                          ),
                        );
                      },
                    );
                  },
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  String _formatTime(DateTime dt) {
    final hour = dt.hour.toString().padLeft(2, '0');
    final minute = dt.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  // Same local-time convention as _formatTime, with seconds for the live clock face.
  String _formatClockFace(DateTime dt) {
    final hour = dt.hour.toString().padLeft(2, '0');
    final minute = dt.minute.toString().padLeft(2, '0');
    final second = dt.second.toString().padLeft(2, '0');
    return '$hour:$minute:$second';
  }
}

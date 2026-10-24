import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/errors/app_error.dart';
import '../../../core/auth/auth_providers.dart';
import '../../../core/theme/ops_colors.dart';
import '../../../core/widgets/status_chip.dart';
import '../../ai/application/ai_providers.dart';
import '../../ai/domain/ai_models.dart';
import '../../venues/application/venue_clock.dart';
import '../../venues/application/venues_providers.dart';
import '../../venues/presentation/venue_time_widgets.dart';
import '../../workforce/domain/workforce_models.dart';
import '../application/schedules_providers.dart';
import '../domain/coverage_request.dart';
import '../domain/shift.dart';
import '../domain/shift_labels.dart';

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

    ref.watch(scheduleLiveUpdatesProvider(venue.id));
    final shiftsAsync = ref.watch(shiftsForVenueProvider(venue.id));
    final swapsAsync = ref.watch(shiftSwapsForVenueProvider(venue.id));
    final currentUserId = ref.watch(currentUserIdProvider);
    final canManage =
        ref.watch(canManageActiveVenueProvider).valueOrNull ?? false;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Schedule'),
        actions: [
          IconButton(
            icon: const Icon(Icons.assignment_outlined),
            tooltip: 'Requests (time off, drop or pick up shifts)',
            onPressed: () => context.push('/staff-requests'),
          ),
          IconButton(
            icon: const Icon(Icons.view_timeline_outlined),
            tooltip: 'Schedule board',
            onPressed: () => context.go('/schedules/timeline'),
          ),
        ],
      ),
      body: Column(
        children: [
          const UnsupportedTimezoneBanner(),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () async {
                ref.invalidate(shiftsForVenueProvider(venue.id));
                ref.invalidate(shiftSwapsForVenueProvider(venue.id));
              },
              child: shiftsAsync.when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (_, __) => Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('Could not load the schedule.'),
                      const SizedBox(height: 12),
                      OutlinedButton(
                        onPressed: () =>
                            ref.invalidate(shiftsForVenueProvider(venue.id)),
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                ),
                data: (shifts) {
                  final pendingSwaps = swapsAsync.maybeWhen(
                    data: (swaps) =>
                        swaps.where((s) => s.status.isOpen).toList(),
                    orElse: () => const <ShiftSwap>[],
                  );
                  final shiftsById = {for (final s in shifts) s.id: s};
                  if (shifts.isEmpty && pendingSwaps.isEmpty) {
                    return LayoutBuilder(
                      builder: (context, constraints) => SingleChildScrollView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        child: SizedBox(
                          height: constraints.maxHeight,
                          child: const Center(
                            child: Text('No shifts scheduled yet.'),
                          ),
                        ),
                      ),
                    );
                  }
                  return ListView(
                    children: [
                      if (pendingSwaps.isNotEmpty) ...[
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                          child: Text(
                            'Shift swaps',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ),
                        for (final swap in pendingSwaps)
                          _SwapCard(
                            swap: swap,
                            shift: shiftsById[swap.shiftId],
                            allShifts: shifts,
                            currentUserId: currentUserId,
                            canManage: canManage,
                          ),
                        const Divider(),
                      ],
                      for (final shift in shifts)
                        _ShiftTile(
                          shift: shift,
                          currentUserId: currentUserId,
                          canManage: canManage,
                        ),
                    ],
                  );
                },
              ),
            ),
          ),
        ],
      ),
      floatingActionButton: canManage
          ? Column(
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
            )
          : null,
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
    final clock = ref.read(venueClockProvider);
    if (!ensureSupported(context, clock)) return;

    // Who can be assigned: the venue's roster (RPC venue_schedule_roster), not a typed user id.
    List<RosterMember> roster;
    try {
      roster = await ref.read(scheduleRosterForVenueProvider(venueId).future);
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Couldn't load your team. Please retry.")),
      );
      return;
    }
    if (!context.mounted) return;
    final people = [...roster]..sort(
        (a, b) => (a.displayName ?? '').toLowerCase().compareTo(
              (b.displayName ?? '').toLowerCase(),
            ),
      );

    await showDialog<void>(
      context: context,
      builder: (context) => _AddShiftDialog(
        venueId: venueId,
        people: people,
        initialStaffId: people.any((m) => m.userId == prefillStaffId)
            ? prefillStaffId
            : null,
        initialRole: prefillRoleLabel,
        initialStart: prefillStart,
        initialEnd: prefillEnd,
      ),
    );
  }

  /// An AI-suggested time as a venue wall time: a value with an offset or `Z` is an instant and
  /// is converted to the venue's clock; one without is taken to already be the venue's clock.
  DateTime? _suggestedWall(WidgetRef ref, String? raw) {
    final parsed = DateTime.tryParse(raw ?? '');
    if (parsed == null) return null;
    if (parsed.isUtc) return ref.read(venueClockProvider).wall(parsed);
    return DateTime.utc(
      parsed.year,
      parsed.month,
      parsed.day,
      parsed.hour,
      parsed.minute,
    );
  }

  Future<void> _showSuggestDialog(
    BuildContext context,
    WidgetRef ref,
    String venueId,
  ) async {
    // The assistant answers with roster keys, which map back to real people below.
    List<RosterMember> members;
    try {
      members = await ref.read(scheduleRosterForVenueProvider(venueId).future);
    } catch (_) {
      members = const [];
    }
    final roster = CoverageRoster(members);
    if (!context.mounted) return;

    final result = await showDialog<SchedulingSuggestionResult>(
      context: context,
      builder: (context) =>
          _SuggestCoverageDialog(venueId: venueId, roster: roster),
    );
    if (result == null || !context.mounted) return;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Review suggestions'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final suggestion in result.suggestions)
                Builder(
                  builder: (context) {
                    final member = roster.resolve(suggestion);
                    final start = _suggestedWall(ref, suggestion.startTime);
                    final end = _suggestedWall(ref, suggestion.endTime);
                    return ListTile(
                      title: Text(
                        member?.displayName ??
                            suggestion.staffName ??
                            'Unmatched team member',
                      ),
                      subtitle: Text(
                        [
                          if (suggestion.roleLabel?.isNotEmpty ?? false)
                            suggestion.roleLabel!,
                          if (start != null && end != null)
                            '${VenueClock.formatWallDateTime(start)} → '
                                '${VenueClock.formatWallDateTime(end)}',
                          if (member == null)
                            "Not on this venue's roster. Pick someone when adding.",
                          suggestion.reason,
                        ].join('\n'),
                      ),
                      isThreeLine: true,
                      trailing: TextButton(
                        onPressed: () {
                          Navigator.of(dialogContext).pop();
                          _showAddShiftDialog(
                            context,
                            ref,
                            venueId,
                            prefillStaffId: member?.userId,
                            prefillRoleLabel: suggestion.roleLabel,
                            prefillStart: start,
                            prefillEnd: end,
                          );
                        },
                        child: const Text('Add'),
                      ),
                    );
                  },
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}

/// Display names by user id for the venue's schedule roster (empty until it loads).
Map<String, String> _rosterNames(WidgetRef ref, String venueId) {
  final roster = ref.watch(scheduleRosterForVenueProvider(venueId)).valueOrNull;
  return {
    for (final m in roster ?? const <RosterMember>[])
      m.userId: m.displayName ?? 'Team member',
  };
}

class _ShiftTile extends ConsumerWidget {
  const _ShiftTile({
    required this.shift,
    required this.currentUserId,
    required this.canManage,
  });

  final Shift shift;
  final String? currentUserId;
  final bool canManage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isMine = currentUserId != null && shift.staffId == currentUserId;
    final clock = ref.watch(venueClockProvider);
    final names = _rosterNames(ref, shift.venueId);

    return ListTile(
      leading: const Icon(Icons.schedule_outlined),
      title: Text(shift.roleLabel ?? 'Shift'),
      subtitle: Text(
        '${clock.formatDateTime(shift.startTime)} → ${clock.formatDateTime(shift.endTime)}'
        '${shift.staffId != null ? '\nStaff: ${names[shift.staffId] ?? 'Team member'}' : '\n(open shift)'}'
        '${shift.status == ShiftStatus.cancelled ? '\nCancelled' : ''}',
      ),
      isThreeLine: true,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isMine)
            IconButton(
              icon: const Icon(Icons.swap_horiz_outlined),
              tooltip: 'Request a swap',
              onPressed: () => _requestSwap(context, ref),
            ),
          if (canManage && shift.status != ShiftStatus.cancelled)
            IconButton(
              icon: const Icon(Icons.event_busy_outlined),
              tooltip: 'Remove or cancel shift',
              onPressed: () => _delete(context, ref),
            ),
        ],
      ),
    );
  }

  Future<void> _requestSwap(BuildContext context, WidgetRef ref) async {
    try {
      await ref
          .read(schedulesRepositoryProvider)
          .requestSwap(shiftId: shift.id);
      ref.invalidate(shiftSwapsForVenueProvider(shift.venueId));
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Swap requested. A teammate can offer to take it, then a manager approves.',
          ),
        ),
      );
    } on PostgrestException catch (error) {
      if (!context.mounted) return;
      final message = switch (error.code) {
        '42501' => 'You can only request a swap for your own shift.',
        '23505' => 'This shift already has a swap request.',
        _ => 'Something went wrong. Please try again.',
      };
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    try {
      await ref.read(schedulesRepositoryProvider).deleteShift(shift.id);
      ref.invalidate(shiftsForVenueProvider(shift.venueId));
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Shift removed locally or marked cancelled. Publish the schedule to sync a connected POS.',
          ),
        ),
      );
    } on PostgrestException catch (error) {
      if (!context.mounted) return;
      final message = error.code == '42501'
          ? "You don't have permission to remove this shift."
          : 'Something went wrong. Please try again.';
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }
}

/// One open swap: which shift it is (day, time, role and section), who offered it, who is
/// taking it, and the actions the viewer may take. Taking and approving both confirm first,
/// naming the person who ends up on the shift and warning about a double-booking (U1).
class _SwapCard extends ConsumerWidget {
  const _SwapCard({
    required this.swap,
    required this.shift,
    required this.allShifts,
    required this.currentUserId,
    required this.canManage,
  });

  final ShiftSwap swap;

  /// Null when the shift is outside the loaded schedule window.
  final Shift? shift;
  final List<Shift> allShifts;
  final String? currentUserId;
  final bool canManage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final clock = ref.watch(venueClockProvider);
    final names = _rosterNames(ref, swap.venueId);
    String nameOf(String? id) => names[id] ?? 'A teammate';

    final me = currentUserId;
    final isRequester = me != null && swap.requestedBy == me;
    final claimed = swap.status == ShiftSwapStatus.claimed;
    final taker = swap.taker;
    final canTake = me != null &&
        !isRequester &&
        swap.status == ShiftSwapStatus.pending &&
        (swap.offeredTo == null || swap.offeredTo == me);
    final s = shift;

    final offeredLine = swap.offeredTo == null
        ? 'Offered by ${nameOf(swap.requestedBy)} · open to anyone'
        : 'Offered by ${nameOf(swap.requestedBy)} to ${swap.offeredTo == me ? 'you' : nameOf(swap.offeredTo)}';

    return Card(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.swap_horiz_outlined),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    s == null
                        ? 'Shift outside the schedule window'
                        : '${shiftDayLabel(clock, s)} · ${shiftRoleLabel(s)}',
                    style: theme.textTheme.titleSmall,
                  ),
                ),
              ],
            ),
            if (s != null) ...[
              const SizedBox(height: 2),
              Text(
                shiftTimeRangeLabel(clock, s),
                style: theme.textTheme.bodyMedium,
              ),
            ],
            const SizedBox(height: 2),
            Text(
              offeredLine,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (claimed) ...[
              const SizedBox(height: 8),
              StatusChip(
                label: '${taker == me ? 'You are' : '${nameOf(taker)} is'} '
                    'taking it · awaiting manager approval',
                tone: Tone.warning,
                icon: Icons.hourglass_top,
                dense: true,
              ),
            ],
            OverflowBar(
              alignment: MainAxisAlignment.end,
              spacing: 8,
              children: [
                if (claimed && me != null && swap.acceptedBy == me)
                  TextButton(
                    onPressed: () => _withdraw(context, ref),
                    child: const Text('Withdraw'),
                  ),
                if (isRequester)
                  TextButton(
                    onPressed: () => _cancel(context, ref),
                    child: const Text('Cancel request'),
                  ),
                if (canManage && !isRequester)
                  TextButton(
                    onPressed: () => _decline(context, ref),
                    child: const Text('Decline'),
                  ),
                if (canTake && canManage && s != null)
                  TextButton(
                    onPressed: () => _take(context, ref, s, names),
                    child: const Text('Take it myself'),
                  ),
                if (canManage && taker != null && s != null)
                  FilledButton(
                    onPressed: () => _approve(context, ref, s, taker, names),
                    child: Text('Approve for ${nameOf(taker)}'),
                  )
                else if (canTake && !canManage && s != null)
                  FilledButton(
                    onPressed: () => _take(context, ref, s, names),
                    child: const Text('Take shift'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Confirms a take or approval, warning when [personId] already works then. Returns null if
  /// dismissed, else whether the person explicitly chose to double-book.
  Future<bool?> _confirm(
    BuildContext context,
    WidgetRef ref, {
    required String title,
    required String question,
    required String? note,
    required String personId,
    required String personLabel,
    required String confirmLabel,
    required Shift shift,
  }) async {
    final clock = ref.read(venueClockProvider);
    final clashes = overlappingShiftsFor(allShifts, personId, shift);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        final theme = Theme.of(context);
        return AlertDialog(
          title: Text(title),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(question),
              if (note != null) ...[
                const SizedBox(height: 8),
                Text(note, style: theme.textTheme.bodySmall),
              ],
              for (final clash in clashes) ...[
                const SizedBox(height: 12),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.warning_amber_rounded,
                      color: context.ops.danger.fg,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '$personLabel already ${personLabel == 'You' ? 'work' : 'works'} '
                        '${shiftRoleLabel(clash)} ${shiftDayLabel(clock, clash)}, '
                        '${shiftTimeRangeLabel(clock, clash)}. This would double-book '
                        '${personLabel == 'You' ? 'you' : 'them'}.',
                        style: TextStyle(color: context.ops.danger.fg),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Not now'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child:
                  Text(clashes.isEmpty ? confirmLabel : '$confirmLabel anyway'),
            ),
          ],
        );
      },
    );
    if (confirmed != true) return null;
    return clashes.isNotEmpty;
  }

  Future<void> _take(
    BuildContext context,
    WidgetRef ref,
    Shift shift,
    Map<String, String> names,
  ) async {
    final me = currentUserId;
    if (me == null) return;
    final clock = ref.read(venueClockProvider);
    final owner = names[swap.requestedBy] ?? 'your teammate';
    final allowOverlap = await _confirm(
      context,
      ref,
      title: 'Take this shift?',
      question: "Take $owner's ${shiftSentenceLabel(clock, shift)}?",
      note: canManage
          ? 'It moves to you straight away.'
          : 'A manager approves it before it becomes yours.',
      personId: me,
      personLabel: 'You',
      confirmLabel: 'Take shift',
      shift: shift,
    );
    if (allowOverlap == null || !context.mounted) return;
    try {
      final status = await ref
          .read(schedulesRepositoryProvider)
          .claimSwap(swapId: swap.id, allowOverlap: allowOverlap);
      _refresh(ref);
      if (!context.mounted) return;
      _snack(
        context,
        status == ShiftSwapStatus.accepted
            ? 'The shift is yours.'
            : 'Sent. A manager will approve it, and $owner will be told.',
      );
    } on PostgrestException catch (error) {
      _refresh(ref);
      if (context.mounted) _snack(context, _swapError(error));
    }
  }

  Future<void> _approve(
    BuildContext context,
    WidgetRef ref,
    Shift shift,
    String taker,
    Map<String, String> names,
  ) async {
    final clock = ref.read(venueClockProvider);
    final takerName = names[taker] ?? 'this teammate';
    final owner = names[swap.requestedBy] ?? 'the current assignee';
    final allowOverlap = await _confirm(
      context,
      ref,
      title: 'Approve swap?',
      question:
          "Give $owner's ${shiftSentenceLabel(clock, shift)} to $takerName?",
      note: null,
      personId: taker,
      personLabel: takerName,
      confirmLabel: 'Approve',
      shift: shift,
    );
    if (allowOverlap == null || !context.mounted) return;
    try {
      await ref
          .read(schedulesRepositoryProvider)
          .approveSwap(swapId: swap.id, allowOverlap: allowOverlap);
      _refresh(ref);
      if (context.mounted) {
        _snack(context, "Approved. The shift is now $takerName's.");
      }
    } on PostgrestException catch (error) {
      _refresh(ref);
      if (context.mounted) _snack(context, _swapError(error));
    }
  }

  Future<void> _decline(BuildContext context, WidgetRef ref) async {
    try {
      await ref.read(schedulesRepositoryProvider).declineSwap(swap.id);
      _refresh(ref);
    } on PostgrestException catch (error) {
      if (context.mounted) _snack(context, _swapError(error));
    }
  }

  Future<void> _cancel(BuildContext context, WidgetRef ref) async {
    try {
      await ref.read(schedulesRepositoryProvider).cancelSwap(swap.id);
      _refresh(ref);
    } on PostgrestException catch (error) {
      if (context.mounted) _snack(context, _swapError(error));
    }
  }

  Future<void> _withdraw(BuildContext context, WidgetRef ref) async {
    try {
      await ref.read(schedulesRepositoryProvider).unclaimShiftSwap(swap.id);
      _refresh(ref);
    } on PostgrestException catch (error) {
      if (context.mounted) _snack(context, _swapError(error));
    }
  }

  void _refresh(WidgetRef ref) {
    ref.invalidate(shiftSwapsForVenueProvider(swap.venueId));
    ref.invalidate(shiftsForVenueProvider(swap.venueId));
  }

  static void _snack(BuildContext context, String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  static String _swapError(PostgrestException error) => switch (error.code) {
        '42501' => 'This swap is no longer available to you.',
        '40001' =>
          'This shift changed in the meantime. The list has been refreshed.',
        '23P01' => 'That would double-book: '
            '${error.message.replaceFirst('shift_overlap: ', '')}.',
        '22023' => error.message,
        _ => 'Something went wrong. Please try again.',
      };
}

/// Manual "Add shift": saves from inside the dialog, so a refused save (end before start,
/// permissions, network) keeps everything entered and shows why in place.
class _AddShiftDialog extends ConsumerStatefulWidget {
  const _AddShiftDialog({
    required this.venueId,
    required this.people,
    this.initialStaffId,
    this.initialRole,
    this.initialStart,
    this.initialEnd,
  });

  final String venueId;
  final List<RosterMember> people;
  final String? initialStaffId;
  final String? initialRole;
  final DateTime? initialStart;
  final DateTime? initialEnd;

  @override
  ConsumerState<_AddShiftDialog> createState() => _AddShiftDialogState();
}

class _AddShiftDialogState extends ConsumerState<_AddShiftDialog> {
  late final _role = TextEditingController(text: widget.initialRole);
  late String? _staffId = widget.initialStaffId;
  // Venue wall times (see VenueClock): what the manager reads on the venue's clock.
  late DateTime _start;
  late DateTime _end;
  bool _saving = false;
  String? _error;

  VenueClock get _clock => ref.read(venueClockProvider);

  @override
  void initState() {
    super.initState();
    _start = widget.initialStart ?? _clock.now;
    final end = widget.initialEnd ?? _start.add(const Duration(hours: 4));
    _end = end.isAfter(_start) ? end : _start.add(const Duration(hours: 4));
  }

  @override
  void dispose() {
    _role.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_end.isAfter(_start)) {
      setState(() => _error = 'The end time must be after the start.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref.read(schedulesRepositoryProvider).createShift(
            venueId: widget.venueId,
            staffId: _staffId,
            roleLabel: _role.text.trim().isEmpty ? null : _role.text.trim(),
            startTime: _clock.instant(_start),
            endTime: _clock.instant(_end),
          );
      ref.invalidate(shiftsForVenueProvider(widget.venueId));
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = switch (error) {
          PostgrestException(code: '42501') =>
            "You don't have permission to schedule shifts here.",
          PostgrestException(code: '23514') =>
            'The shift end time must be after its start time.',
          _ => 'Could not add the shift. Please try again.',
        };
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final clock = ref.watch(venueClockProvider);
    return PopScope(
      canPop: !_saving,
      child: AlertDialog(
        title: const Text('Add shift'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              DropdownButtonFormField<String?>(
                initialValue: _staffId,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Assigned to'),
                items: [
                  const DropdownMenuItem<String?>(
                    value: null,
                    child: Text('Open shift (unassigned)'),
                  ),
                  for (final member in widget.people)
                    DropdownMenuItem<String?>(
                      value: member.userId,
                      child: Text(member.displayName ?? 'Team member'),
                    ),
                ],
                onChanged: (value) => setState(() => _staffId = value),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _role,
                decoration:
                    const InputDecoration(labelText: 'Role (e.g. bartender)'),
              ),
              const SizedBox(height: 12),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Start'),
                subtitle: Text(VenueClock.formatWallDateTime(_start)),
                trailing: const Icon(Icons.edit_calendar_outlined),
                onTap: () async {
                  final picked = await pickVenueDateTime(
                    context,
                    initial: _start,
                    nowWall: clock.now,
                  );
                  if (picked != null) {
                    setState(() {
                      final length = _end.difference(_start);
                      _start = picked;
                      if (!_end.isAfter(_start)) _end = _start.add(length);
                      _error = null;
                    });
                  }
                },
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('End'),
                subtitle: Text(VenueClock.formatWallDateTime(_end)),
                trailing: const Icon(Icons.edit_calendar_outlined),
                onTap: () async {
                  final picked = await pickVenueDateTime(
                    context,
                    initial: _end,
                    nowWall: clock.now,
                  );
                  if (picked != null) {
                    setState(() {
                      _end = picked;
                      _error = null;
                    });
                  }
                },
              ),
              if (_end.isBefore(clock.now))
                Text(
                  'This shift is in the past. Check the date before adding it.',
                  style: TextStyle(color: context.ops.warning.fg),
                ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    _error!,
                    style: TextStyle(color: context.ops.danger.fg),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _saving ? null : () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: _saving ? null : _save,
            child: const Text('Add'),
          ),
        ],
      ),
    );
  }
}

/// "Suggest coverage" prompt. The request runs from inside the dialog: an empty description,
/// an AI error or an empty answer keeps the dialog (and the text) open with the reason shown.
/// Pops with the suggestions on success.
class _SuggestCoverageDialog extends ConsumerStatefulWidget {
  const _SuggestCoverageDialog({required this.venueId, required this.roster});

  final String venueId;
  final CoverageRoster roster;

  @override
  ConsumerState<_SuggestCoverageDialog> createState() =>
      _SuggestCoverageDialogState();
}

class _SuggestCoverageDialogState
    extends ConsumerState<_SuggestCoverageDialog> {
  final _text = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _suggest() async {
    final request = _text.text.trim();
    if (request.isEmpty) {
      setState(() => _error = 'Describe the shifts that need coverage first.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final clock = ref.read(venueClockProvider);
    try {
      final result = await ref.read(aiRepositoryProvider).suggestScheduling(
            venueId: widget.venueId,
            context: coverageRequestInput(
              request: request,
              roster: widget.roster,
              todayWall: clock.now,
              timezoneId: clock.timezoneId,
            ),
          );
      if (!mounted) return;
      if (result.suggestions.isEmpty) {
        setState(() {
          _busy = false;
          _error = 'No suggestions could be made from that description. '
              'Add who is available and try again.';
        });
        return;
      }
      Navigator.of(context).pop(result);
    } on AppError catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = error.message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Suggest shift coverage'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _text,
            autofocus: true,
            maxLines: 8,
            enabled: !_busy,
            decoration: const InputDecoration(
              hintText:
                  'Describe the roster, target headcount, and any constraints '
                  '(time-off requests, required roles)…',
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _error!,
                style: TextStyle(color: context.ops.danger.fg),
              ),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy ? null : _suggest,
          child: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Suggest'),
        ),
      ],
    );
  }
}

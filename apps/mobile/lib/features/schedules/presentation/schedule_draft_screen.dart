import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/errors/app_error.dart';
import '../../../core/theme/app_radii.dart';
import '../../../core/theme/ops_colors.dart';
import '../../ai/application/ai_providers.dart';
import '../../staff_requests/application/staff_requests_providers.dart';
import '../../venues/application/venue_clock.dart';
import '../../venues/domain/venue_timezone.dart';
import '../../venues/presentation/venue_time_widgets.dart';
import '../../workforce/domain/workforce_models.dart';
import '../application/schedules_providers.dart';
import '../domain/schedule_draft.dart';
import '../domain/shift.dart';

/// "Draft a week": a manager describes the week in plain language, the assistant proposes
/// shifts, and every proposal lands in a review list with warnings computed from the real
/// schedule. Nothing is created until "Add selected" is tapped, a refused save stays on its
/// line with the selection kept, and the manual "Add shift" on the schedule is always there.
class ScheduleDraftScreen extends ConsumerStatefulWidget {
  const ScheduleDraftScreen({super.key, required this.venueId});

  final String venueId;

  @override
  ConsumerState<ScheduleDraftScreen> createState() =>
      _ScheduleDraftScreenState();
}

class _ScheduleDraftScreenState extends ConsumerState<ScheduleDraftScreen> {
  final _rules = TextEditingController();
  final _maxHours =
      TextEditingController(text: '$scheduleDraftDefaultMaxHours');
  late DateTime _weekStart;
  bool _drafting = false;
  bool _creating = false;
  String? _formError;

  // Review state; [_input] is null while the form is showing.
  ScheduleDraftInput? _input;
  List<Shift> _existing = const [];
  List<DraftShift> _drafts = const [];
  final _selected = <int>{};
  final _added = <int>{};
  final _lineErrors = <int, String>{};
  String? _notice;
  String? _summary;

  VenueClock get _clock => ref.read(venueClockProvider);

  @override
  void initState() {
    super.initState();
    // Planning ahead is the usual job: start on next week.
    _weekStart = weekStartFor(_clock.now).add(const Duration(days: 7));
  }

  @override
  void dispose() {
    _rules.dispose();
    _maxHours.dispose();
    super.dispose();
  }

  List<Shift> _weekShifts(Iterable<Shift> all, DateTime weekStart) {
    final from = _clock.instant(weekStart);
    final to = _clock.instant(weekStart.add(const Duration(days: 7)));
    return [
      for (final s in all)
        if (s.status != ShiftStatus.cancelled &&
            s.startTime.isBefore(to) &&
            s.endTime.isAfter(from))
          s,
    ];
  }

  Map<int, List<DraftWarning>> _warnings() {
    final input = _input;
    if (input == null) return const {};
    return draftWarnings(
      drafts: _drafts,
      selected: _selected,
      existing: _existing,
      timeOff: input.timeOff,
      clock: _clock,
      weekStartWall: input.weekStart,
      maxHours: input.maxHours,
      nowWall: _clock.now,
    );
  }

  Future<void> _draft() async {
    final rules = _rules.text.trim();
    if (rules.isEmpty) {
      setState(() => _formError = 'Describe the week you need first.');
      return;
    }
    final maxHours = int.tryParse(_maxHours.text.trim());
    if (maxHours == null || maxHours < 1 || maxHours > 168) {
      setState(() => _formError = 'Enter a weekly hours limit from 1 to 168.');
      return;
    }
    if (!ensureSupported(context, _clock)) return;
    setState(() {
      _drafting = true;
      _formError = null;
    });
    final venueId = widget.venueId;
    final clock = _clock;
    final ScheduleDraftInput input;
    try {
      // Read fresh data: the draft is checked against what is on the schedule right now.
      ref
        ..invalidate(shiftsForVenueProvider(venueId))
        ..invalidate(staffRequestsForVenueProvider(venueId));
      final roster =
          await ref.read(scheduleRosterForVenueProvider(venueId).future);
      final shifts = await ref.read(shiftsForVenueProvider(venueId).future);
      final requests =
          await ref.read(staffRequestsForVenueProvider(venueId).future);
      if (!mounted) return;
      if (roster.isEmpty) {
        setState(() {
          _drafting = false;
          _formError = 'There is nobody on the roster to schedule yet.';
        });
        return;
      }
      input = buildScheduleDraftInput(
        rules: rules,
        members: roster,
        shifts: shifts,
        requests: requests,
        clock: clock,
        weekStartWall: _weekStart,
        maxHours: maxHours,
        todayWall: clock.now,
      );
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _drafting = false;
        _formError = "Couldn't load the roster, schedule and time off, so "
            'nothing was sent. Please try again.';
      });
      return;
    }
    if (input.tooLarge) {
      setState(() {
        _drafting = false;
        _formError = 'That is too much to draft at once. Shorten the rules '
            'and try again.';
      });
      return;
    }
    try {
      final result = await ref.read(aiRepositoryProvider).draftSchedule(
            venueId: venueId,
            context: input.text,
          );
      if (!mounted) return;
      final outcome = resolveDraftShifts(result, input.roster, clock);
      final dropped = [
        if (outcome.droppedUnknownStaff > 0)
          '${outcome.droppedUnknownStaff} naming someone not on the roster',
        if (outcome.droppedBadTimes > 0)
          '${outcome.droppedBadTimes} with unreadable times',
      ];
      if (outcome.shifts.isEmpty) {
        setState(() {
          _drafting = false;
          _formError = 'No shifts could be drafted from that description'
              '${dropped.isEmpty ? '' : ' (left out: ${dropped.join(', ')})'}. '
              'Add the roles, days and times you need and try again.';
        });
        return;
      }
      setState(() {
        _drafting = false;
        _input = input;
        _existing = input.existing;
        _drafts = outcome.shifts;
        _added.clear();
        _lineErrors.clear();
        _summary = null;
        _notice = dropped.isEmpty
            ? null
            : 'Left out ${dropped.join(' and ')}. Review the rest below.';
        _selected
          ..clear()
          ..addAll(_cleanPicks());
      });
    } on AppError catch (error) {
      if (!mounted) return;
      setState(() {
        _drafting = false;
        _formError = error.message;
      });
    }
  }

  /// Proposals that start selected: those with no warning, picked one at a time so two
  /// proposals that clash with each other are never both preselected.
  Set<int> _cleanPicks() {
    final picks = <int>{};
    for (final d in _drafts) {
      final trial = {...picks, d.id};
      final warnings = draftWarnings(
        drafts: _drafts,
        selected: trial,
        existing: _existing,
        timeOff: _input!.timeOff,
        clock: _clock,
        weekStartWall: _input!.weekStart,
        maxHours: _input!.maxHours,
        nowWall: _clock.now,
      );
      if ((warnings[d.id] ?? const []).isEmpty) picks.add(d.id);
    }
    return picks;
  }

  Future<void> _addSelected() async {
    if (!ensureSupported(context, _clock)) return;
    final warnings = _warnings();
    final ids = [
      for (final d in _drafts)
        if (_selected.contains(d.id) &&
            !_added.contains(d.id) &&
            !(warnings[d.id] ?? const []).any((w) => w.blocking))
          d.id,
    ];
    if (ids.isEmpty) return;
    setState(() {
      _creating = true;
      _summary = null;
      for (final id in ids) {
        _lineErrors.remove(id);
      }
    });
    final repo = ref.read(schedulesRepositoryProvider);
    final clock = _clock;
    var created = 0;
    for (final id in ids) {
      final d = _drafts[id];
      final role = d.roleLabel.trim();
      try {
        await repo.createShift(
          venueId: widget.venueId,
          staffId: d.member?.userId,
          roleLabel: role.isEmpty
              ? null
              : (role.length > 60 ? role.substring(0, 60) : role),
          startTime: clock.instant(d.start),
          endTime: clock.instant(d.end),
        );
        created++;
        _added.add(id);
        _selected.remove(id);
      } catch (error) {
        _lineErrors[id] = _createError(error);
      }
      if (!mounted) return;
    }
    ref.invalidate(shiftsForVenueProvider(widget.venueId));
    try {
      final all = await ref.read(shiftsForVenueProvider(widget.venueId).future);
      _existing = _weekShifts(all, _input!.weekStart);
    } catch (_) {
      // Warnings keep using the schedule as it was when drafted.
    }
    if (!mounted) return;
    final failed = ids.length - created;
    final everythingAdded = _added.length == _drafts.length;
    if (failed == 0 && everythingAdded) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            created == 1 ? 'Added 1 shift.' : 'Added $created shifts.',
          ),
        ),
      );
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _creating = false;
      _summary = failed == 0
          ? 'Added $created ${created == 1 ? 'shift' : 'shifts'}.'
          : 'Added $created, but $failed could not be added. '
              '${failed == 1 ? 'It stays' : 'They stay'} selected so you can retry.';
    });
  }

  static String _createError(Object error) => switch (error) {
        PostgrestException(code: '42501') =>
          "You don't have permission to schedule shifts here.",
        PostgrestException(code: '23514') =>
          'The shift end time must be after its start time.',
        PostgrestException(code: '23P01') =>
          'That would double-book this person.',
        _ => 'Could not add this shift. Please try again.',
      };

  Future<void> _edit(DraftShift draft, List<RosterMember> people) async {
    final updated = await showDialog<DraftShift>(
      context: context,
      builder: (_) => _EditDraftDialog(draft: draft, people: people),
    );
    if (updated == null || !mounted) return;
    setState(() {
      _drafts = [
        for (final d in _drafts) d.id == updated.id ? updated : d,
      ];
      _lineErrors.remove(updated.id);
    });
  }

  void _startOver() {
    setState(() {
      _input = null;
      _drafts = const [];
      _selected.clear();
      _added.clear();
      _lineErrors.clear();
      _notice = null;
      _summary = null;
      _creating = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final reviewing = _input != null;
    return Scaffold(
      appBar: AppBar(
        title: Text(reviewing ? 'Review drafted shifts' : 'Draft a week'),
      ),
      body: SafeArea(child: reviewing ? _review(context) : _form(context)),
    );
  }

  Widget _form(BuildContext context) {
    final theme = Theme.of(context);
    final weekEnd = _weekStart.add(const Duration(days: 6));
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          'Describe the week in plain language. The assistant proposes shifts '
          'using your roster, what is already scheduled, approved time off and '
          'hours so far. You review every shift before anything is added.',
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            IconButton(
              tooltip: 'Previous week',
              icon: const Icon(Icons.chevron_left),
              onPressed: _drafting
                  ? null
                  : () => setState(
                        () => _weekStart =
                            _weekStart.subtract(const Duration(days: 7)),
                      ),
            ),
            Expanded(
              child: Text(
                '${draftDayLabel(_weekStart)} – ${draftDayLabel(weekEnd)}',
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium,
              ),
            ),
            IconButton(
              tooltip: 'Next week',
              icon: const Icon(Icons.chevron_right),
              onPressed: _drafting
                  ? null
                  : () => setState(
                        () => _weekStart =
                            _weekStart.add(const Duration(days: 7)),
                      ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _rules,
          maxLines: 6,
          maxLength: scheduleDraftMaxRulesChars,
          enabled: !_drafting,
          decoration: const InputDecoration(
            labelText: 'Rules for the week',
            hintText: 'e.g. two bartenders and three servers Fri–Sat nights, '
                'one host weeknights, respect time off',
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _maxHours,
          enabled: !_drafting,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'Most hours per person this week',
          ),
        ),
        if (_formError != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              _formError!,
              style: TextStyle(color: context.ops.danger.fg),
            ),
          ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: _drafting ? null : _draft,
          icon: _drafting
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.auto_awesome_outlined),
          label: const Text('Draft shifts'),
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: _drafting ? null : () => Navigator.of(context).pop(),
          child: const Text('Add shifts manually instead'),
        ),
      ],
    );
  }

  Widget _review(BuildContext context) {
    final theme = Theme.of(context);
    final roster = ref.watch(scheduleRosterForVenueProvider(widget.venueId));
    final people = [...(roster.valueOrNull ?? const <RosterMember>[])]..sort(
        (a, b) => (a.displayName ?? '')
            .toLowerCase()
            .compareTo((b.displayName ?? '').toLowerCase()),
      );
    final warnings = _warnings();
    final pending = [
      for (final d in _drafts)
        if (!_added.contains(d.id)) d,
    ];
    final count = _selected.where((id) => !_added.contains(id)).length;
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                'Nothing is added until you tap "Add selected". Tick the '
                'shifts you want, edit any that need changing, and check the '
                'warnings.',
                style: theme.textTheme.bodyMedium,
              ),
              if (_notice != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    _notice!,
                    style: TextStyle(color: context.ops.warning.fg),
                  ),
                ),
              if (_summary != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    _summary!,
                    style: TextStyle(
                      color: _lineErrors.isEmpty
                          ? context.ops.success.fg
                          : context.ops.danger.fg,
                    ),
                  ),
                ),
              const SizedBox(height: 8),
              Row(
                children: [
                  TextButton(
                    onPressed: _creating
                        ? null
                        : () => setState(
                              () => _selected
                                ..clear()
                                ..addAll(
                                  pending
                                      .where(
                                        (d) => !(warnings[d.id] ?? const [])
                                            .any((w) => w.blocking),
                                      )
                                      .map((d) => d.id),
                                ),
                            ),
                    child: const Text('Select all'),
                  ),
                  TextButton(
                    onPressed:
                        _creating ? null : () => setState(_selected.clear),
                    child: const Text('Clear'),
                  ),
                ],
              ),
              for (final d in _drafts)
                _DraftCard(
                  draft: d,
                  selected: _selected.contains(d.id),
                  added: _added.contains(d.id),
                  busy: _creating,
                  warnings: warnings[d.id] ?? const [],
                  error: _lineErrors[d.id],
                  onChanged: (value) => setState(() {
                    if (value) {
                      _selected.add(d.id);
                    } else {
                      _selected.remove(d.id);
                    }
                  }),
                  onEdit: () => _edit(d, people),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Row(
            children: [
              OutlinedButton(
                onPressed: _creating ? null : _startOver,
                child: const Text('Start over'),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: _creating || count == 0 ? null : _addSelected,
                  child: _creating
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text('Add selected ($count)'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _DraftCard extends StatelessWidget {
  const _DraftCard({
    required this.draft,
    required this.selected,
    required this.added,
    required this.busy,
    required this.warnings,
    required this.error,
    required this.onChanged,
    required this.onEdit,
  });

  final DraftShift draft;
  final bool selected;
  final bool added;
  final bool busy;
  final List<DraftWarning> warnings;
  final String? error;
  final ValueChanged<bool> onChanged;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final blocked = warnings.any((w) => w.blocking);
    final who = draft.member?.displayName ??
        (draft.member == null ? 'Open shift' : 'Team member');
    final role = draft.roleLabel.isEmpty ? '' : ' · ${draft.roleLabel}';
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 8, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Checkbox(
              value: added || selected,
              onChanged: added || busy || blocked
                  ? null
                  : (v) => onChanged(v ?? false),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('$who$role', style: theme.textTheme.titleSmall),
                    const SizedBox(height: 2),
                    Text(
                      '${draftDayLabel(draft.start)} · '
                      '${VenueTimezone.formatWallTime(draft.start)}'
                      ' – ${VenueTimezone.formatWallTime(draft.end)}',
                    ),
                    if (draft.reason.isNotEmpty)
                      Text(
                        draft.reason,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    if (added)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          'Added to the schedule',
                          style: TextStyle(color: context.ops.success.fg),
                        ),
                      ),
                    for (final w in warnings)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(
                              w.blocking
                                  ? Icons.error_outline
                                  : Icons.warning_amber_rounded,
                              size: 16,
                              color: w.blocking
                                  ? context.ops.danger.fg
                                  : context.ops.warning.fg,
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                w.message,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: w.blocking
                                      ? context.ops.danger.fg
                                      : context.ops.warning.fg,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    if (error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          error!,
                          style: TextStyle(color: context.ops.danger.fg),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            IconButton(
              tooltip: 'Edit shift',
              icon: const Icon(Icons.edit_outlined),
              onPressed: added || busy ? null : onEdit,
            ),
          ],
        ),
      ),
    );
  }
}

/// Edits one proposal (person, role, start and end on the venue's clock) without touching the
/// schedule; the review list recomputes its warnings from the result.
class _EditDraftDialog extends ConsumerStatefulWidget {
  const _EditDraftDialog({required this.draft, required this.people});

  final DraftShift draft;
  final List<RosterMember> people;

  @override
  ConsumerState<_EditDraftDialog> createState() => _EditDraftDialogState();
}

class _EditDraftDialogState extends ConsumerState<_EditDraftDialog> {
  late final _role = TextEditingController(text: widget.draft.roleLabel);
  late String? _staffId = widget.draft.member?.userId;
  late DateTime _start = widget.draft.start;
  late DateTime _end = widget.draft.end;

  @override
  void dispose() {
    _role.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final clock = ref.watch(venueClockProvider);
    return AlertDialog(
      title: const Text('Edit drafted shift'),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadii.dialog),
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
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
                for (final m in widget.people)
                  DropdownMenuItem<String?>(
                    value: m.userId,
                    child: Text(m.displayName ?? 'Team member'),
                  ),
              ],
              onChanged: (v) => setState(() => _staffId = v),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _role,
              decoration:
                  const InputDecoration(labelText: 'Role (e.g. bartender)'),
            ),
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
                if (picked == null) return;
                setState(() {
                  final length = _end.difference(_start);
                  _start = picked;
                  if (!_end.isAfter(_start)) _end = _start.add(length);
                });
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
                if (picked != null) setState(() => _end = picked);
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            final member =
                widget.people.where((m) => m.userId == _staffId).firstOrNull;
            Navigator.of(context).pop(
              widget.draft.copyWith(
                member: member,
                clearMember: member == null,
                roleLabel: _role.text.trim(),
                start: _start,
                end: _end,
              ),
            );
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}

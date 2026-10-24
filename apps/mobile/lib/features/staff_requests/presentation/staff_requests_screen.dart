import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/auth/auth_providers.dart';
import '../../../core/theme/ops_colors.dart';
import '../../schedules/application/schedules_providers.dart';
import '../../schedules/domain/shift.dart';
import '../../schedules/domain/shift_labels.dart';
import '../../venues/application/venue_clock.dart';
import '../../venues/application/venues_providers.dart';
import '../../workforce/domain/workforce_models.dart';
import '../application/staff_requests_providers.dart';
import '../domain/staff_request.dart';

const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// "Sat Oct 24" for a calendar date (a `yyyy-mm-dd` string or a picked date).
String _dayLabel(DateTime d) =>
    '${_weekdays[d.weekday - 1]} ${_months[d.month - 1]} ${d.day}';

String? _dateText(String? isoDate) {
  final parsed = DateTime.tryParse(isoDate ?? '');
  return parsed == null ? isoDate : _dayLabel(parsed);
}

/// Display names by user id for the venue's schedule roster — the same name source as the
/// schedule screens (empty until it loads).
Map<String, String> _rosterNames(WidgetRef ref, String venueId) {
  final roster = ref.watch(scheduleRosterForVenueProvider(venueId)).valueOrNull;
  return {
    for (final m in roster ?? const <RosterMember>[])
      m.userId: m.displayName ?? 'Team member',
  };
}

/// Requests for the active venue. Staff see and file their own (time off, dropping one of their
/// shifts, picking up an open one); managers see everyone's, with names and shift details, and
/// approve or deny them. RLS enforces both (20261002205115_staff_requests_schema.sql).
class StaffRequestsScreen extends ConsumerWidget {
  const StaffRequestsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final venue = ref.watch(activeVenueProvider);
    if (venue == null) {
      return const Scaffold(
        body: Center(
          child: Text('No venue selected.'),
        ),
      );
    }

    final requestsAsync = ref.watch(staffRequestsForVenueProvider(venue.id));
    final currentUserId = ref.watch(currentUserIdProvider);
    final canReview =
        ref.watch(canManageActiveVenueProvider).valueOrNull ?? false;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Requests'),
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(staffRequestsForVenueProvider(venue.id));
          ref.invalidate(shiftsForVenueProvider(venue.id));
        },
        child: requestsAsync.when(
          loading: () => const Center(
            child: CircularProgressIndicator(),
          ),
          error: (error, _) => Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Could not load staff requests.'),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: () =>
                      ref.invalidate(staffRequestsForVenueProvider(venue.id)),
                  child: const Text('Retry'),
                ),
              ],
            ),
          ),
          data: (requests) {
            // Pending first, newest first within each group (the fetch order).
            final sorted = [
              ...requests.where((r) => r.isPending),
              ...requests.where((r) => !r.isPending),
            ];
            return ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.only(bottom: 96),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                  child: Text(
                    canReview
                        ? 'Time off and shift changes from your team. Approving a '
                            'drop or pick-up updates the schedule.'
                        : 'Ask for time off, or to drop or pick up a shift. A '
                            'manager reviews every request and you will be notified.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                if (sorted.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(32),
                    child: Center(child: Text('No staff requests yet.')),
                  ),
                for (final request in sorted) ...[
                  _StaffRequestTile(
                    request: request,
                    isOwner: request.userId == currentUserId,
                    canReview: canReview,
                  ),
                  const Divider(height: 1),
                ],
              ],
            );
          },
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => showDialog<void>(
          context: context,
          builder: (context) => _CreateStaffRequestDialog(venueId: venue.id),
        ),
        icon: const Icon(Icons.add),
        label: const Text('New Request'),
      ),
    );
  }
}

class _StaffRequestTile extends ConsumerWidget {
  const _StaffRequestTile({
    required this.request,
    required this.isOwner,
    required this.canReview,
  });

  final StaffRequest request;
  final bool isOwner;
  final bool canReview;

  Tone _statusTone() {
    return switch (request.status) {
      StaffRequestStatus.pending => Tone.warning,
      StaffRequestStatus.approved => Tone.success,
      StaffRequestStatus.denied => Tone.danger,
      StaffRequestStatus.cancelled => Tone.neutral,
    };
  }

  Shift? _shift(WidgetRef ref) {
    final id = request.requestedShiftId;
    if (id == null) return null;
    final shifts =
        ref.watch(shiftsForVenueProvider(request.venueId)).valueOrNull;
    return shifts?.where((s) => s.id == id).firstOrNull;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final statusColor = context.ops.of(_statusTone()).fg;
    final clock = ref.watch(venueClockProvider);
    final names = _rosterNames(ref, request.venueId);
    final shift = _shift(ref);
    final who = isOwner ? 'You' : (names[request.userId] ?? 'Team member');
    final start = _dateText(request.requestedRangeStart);
    final end = _dateText(request.requestedRangeEnd);

    return ListTile(
      leading: CircleAvatar(
        backgroundColor: statusColor.withValues(alpha: 0.15),
        child: Icon(
          _kindIcon(request.kind),
          color: statusColor,
          size: 20,
        ),
      ),
      title: Text(request.title),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${request.kind.displayLabel} • ${request.status.displayLabel}',
            style: Theme.of(context)
                .textTheme
                .labelLarge
                ?.copyWith(color: statusColor),
          ),
          Text('From: $who'),
          if (shift != null)
            Text(
              'Shift: ${shiftDayLabel(clock, shift)} · '
              '${shiftTimeRangeLabel(clock, shift)} · ${shiftRoleLabel(shift)}',
            )
          else if (request.requestedShiftId != null)
            const Text('Shift: no longer on the schedule'),
          if (start != null)
            Text(
              end != null && end != start
                  ? 'Dates: $start – $end'
                  : 'Date: $start',
            ),
          if (request.details.isNotEmpty) Text(request.details),
          if (request.responseNotes != null &&
              request.responseNotes!.isNotEmpty)
            Text(
              'Response: ${request.responseNotes}',
              style: const TextStyle(fontStyle: FontStyle.italic),
            ),
        ],
      ),
      isThreeLine: true,
      trailing: request.isPending
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (isOwner)
                  TextButton(
                    onPressed: () => _cancelRequest(context, ref),
                    child: const Text('Cancel'),
                  ),
                if (canReview && !isOwner)
                  PopupMenuButton<String>(
                    tooltip: 'Review',
                    onSelected: (action) => showDialog<void>(
                      context: context,
                      builder: (context) => _ReviewDialog(
                        request: request,
                        requesterName: who,
                        shift: shift,
                        status: action == 'approve'
                            ? StaffRequestStatus.approved
                            : StaffRequestStatus.denied,
                      ),
                    ),
                    itemBuilder: (context) => const [
                      PopupMenuItem(
                        value: 'approve',
                        child: Text('Approve'),
                      ),
                      PopupMenuItem(
                        value: 'deny',
                        child: Text('Deny'),
                      ),
                    ],
                  ),
              ],
            )
          : null,
    );
  }

  IconData _kindIcon(StaffRequestKind kind) {
    return switch (kind) {
      StaffRequestKind.addShift => Icons.add_circle_outline,
      StaffRequestKind.dropShift => Icons.remove_circle_outline,
      StaffRequestKind.timeOff => Icons.beach_access_outlined,
      StaffRequestKind.shiftSwap => Icons.swap_horiz_outlined,
      StaffRequestKind.openShift => Icons.event_available_outlined,
      StaffRequestKind.sickLeave => Icons.healing_outlined,
      StaffRequestKind.timeCorrection => Icons.access_time_outlined,
      StaffRequestKind.other => Icons.help_outline,
    };
  }

  Future<void> _cancelRequest(BuildContext context, WidgetRef ref) async {
    try {
      await ref.read(staffRequestsRepositoryProvider).cancelRequest(request.id);
      ref.invalidate(staffRequestsForVenueProvider(request.venueId));
    } catch (error) {
      // Any failure (permission, constraint, or network) must surface; silence would leave the
      // person unsure whether the cancel happened.
      if (!context.mounted) return;
      final message = error is PostgrestException && error.code == '42501'
          ? 'You do not have permission to cancel this request.'
          : 'Could not cancel request. Please try again.';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
    }
  }
}

/// Approve/deny with optional notes. Saves from inside the dialog and keeps it open with the
/// error on failure; approving a pick-up that would double-book the requester warns first and
/// needs "Approve anyway".
class _ReviewDialog extends ConsumerStatefulWidget {
  const _ReviewDialog({
    required this.request,
    required this.requesterName,
    required this.shift,
    required this.status,
  });

  final StaffRequest request;
  final String requesterName;
  final Shift? shift;
  final StaffRequestStatus status;

  @override
  ConsumerState<_ReviewDialog> createState() => _ReviewDialogState();
}

class _ReviewDialogState extends ConsumerState<_ReviewDialog> {
  final _notes = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _notes.dispose();
    super.dispose();
  }

  List<Shift> _clashes() {
    final shift = widget.shift;
    if (widget.status != StaffRequestStatus.approved ||
        widget.request.kind != StaffRequestKind.addShift ||
        shift == null) {
      return const [];
    }
    final shifts =
        ref.watch(shiftsForVenueProvider(widget.request.venueId)).valueOrNull ??
            const <Shift>[];
    return overlappingShiftsFor(shifts, widget.request.userId, shift);
  }

  Future<void> _submit({required bool allowOverlap}) async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref.read(staffRequestsRepositoryProvider).reviewRequest(
            requestId: widget.request.id,
            status: widget.status,
            responseNotes: _notes.text.trim(),
            allowOverlap: allowOverlap,
          );
      ref.invalidate(staffRequestsForVenueProvider(widget.request.venueId));
      ref.invalidate(shiftsForVenueProvider(widget.request.venueId));
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = switch (error) {
          PostgrestException(code: '42501') =>
            'You do not have permission to review this request.',
          PostgrestException(code: '23P01') =>
            'This would double-book ${widget.requesterName}: '
                '${error.message.replaceFirst('shift_overlap: ', '')}.',
          PostgrestException(code: '40001' || '22023') => error.message,
          _ => 'Could not review request. Please try again.',
        };
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final clock = ref.watch(venueClockProvider);
    final clashes = _clashes();
    final shift = widget.shift;
    final approving = widget.status == StaffRequestStatus.approved;
    final danger = context.ops.danger.fg;
    return PopScope(
      canPop: !_saving,
      child: AlertDialog(
        title: Text('${widget.status.displayLabel} Request'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${widget.requesterName}: ${widget.request.kind.displayLabel}'
                '${shift != null ? ', ${shiftSentenceLabel(clock, shift)}' : ''}',
              ),
              for (final clash in clashes) ...[
                const SizedBox(height: 12),
                Text(
                  '${widget.requesterName} already works ${shiftRoleLabel(clash)} '
                  '${shiftDayLabel(clock, clash)}, ${shiftTimeRangeLabel(clock, clash)}. '
                  'Approving would double-book them.',
                  style: TextStyle(color: danger),
                ),
              ],
              const SizedBox(height: 12),
              TextField(
                controller: _notes,
                decoration: const InputDecoration(
                  labelText: 'Response notes (optional)',
                ),
                maxLines: 2,
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(_error!, style: TextStyle(color: danger)),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _saving ? null : () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: _saving
                ? null
                : () => _submit(allowOverlap: clashes.isNotEmpty),
            child: Text(
              approving && clashes.isNotEmpty
                  ? 'Approve anyway'
                  : widget.status.displayLabel,
            ),
          ),
        ],
      ),
    );
  }
}

class _CreateStaffRequestDialog extends ConsumerStatefulWidget {
  const _CreateStaffRequestDialog({required this.venueId});

  final String venueId;

  @override
  ConsumerState<_CreateStaffRequestDialog> createState() =>
      _CreateStaffRequestDialogState();
}

class _CreateStaffRequestDialogState
    extends ConsumerState<_CreateStaffRequestDialog> {
  final _formKey = GlobalKey<FormState>();
  StaffRequestKind _kind = StaffRequestKind.timeOff;
  final _titleController = TextEditingController();
  final _detailsController = TextEditingController();
  DateTime? _startDate;
  DateTime? _endDate;
  String? _selectedShiftId;
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _titleController.dispose();
    _detailsController.dispose();
    super.dispose();
  }

  Future<void> _pickDate({required bool isStart}) async {
    final today = DateTime.now();
    final initial = (isStart ? _startDate : _endDate) ?? _startDate ?? today;
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: today.subtract(const Duration(days: 1)),
      lastDate: today.add(const Duration(days: 365)),
    );
    if (picked == null) return;
    setState(() {
      _error = null;
      if (isStart) {
        _startDate = picked;
        if (_endDate != null && _endDate!.isBefore(picked)) _endDate = null;
      } else {
        _endDate = picked;
      }
    });
  }

  String _formatDate(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

  bool get _needsDates =>
      _kind == StaffRequestKind.timeOff || _kind == StaffRequestKind.sickLeave;

  List<Shift> _shiftChoices() {
    final userId = ref.watch(currentUserIdProvider);
    final shifts =
        ref.watch(shiftsForVenueProvider(widget.venueId)).valueOrNull ??
            const <Shift>[];
    final now = DateTime.now().toUtc();
    return [
      for (final shift in shifts)
        if (shift.status != ShiftStatus.cancelled &&
            shift.startTime.isAfter(now) &&
            (_kind == StaffRequestKind.addShift
                ? shift.staffId == null
                : shift.staffId == userId))
          shift,
    ];
  }

  /// A title for the manager's list when the person leaves it blank.
  String _defaultTitle(VenueClock clock, Shift? shift) {
    switch (_kind) {
      case StaffRequestKind.dropShift:
      case StaffRequestKind.addShift:
        final verb = _kind == StaffRequestKind.addShift ? 'Pick up' : 'Drop';
        return shift == null
            ? '$verb shift'
            : '$verb ${shiftDayLabel(clock, shift)} ${shiftRoleLabel(shift)}';
      case StaffRequestKind.timeOff:
      case StaffRequestKind.sickLeave:
        final label = _kind.displayLabel;
        final start = _startDate;
        if (start == null) return label;
        final end = _endDate;
        return end == null || end == start
            ? '$label ${_dayLabel(start)}'
            : '$label ${_dayLabel(start)} – ${_dayLabel(end)}';
      default:
        return _kind.displayLabel;
    }
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    if (_kind.needsShift && _selectedShiftId == null) {
      setState(() => _error = 'Choose the shift for this request.');
      return;
    }
    if (_needsDates && _startDate == null) {
      setState(() => _error = 'Choose the first day you need off.');
      return;
    }
    final clock = ref.read(venueClockProvider);
    final shift = _shiftChoices().where((s) => s.id == _selectedShiftId);
    final typed = _titleController.text.trim();

    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await ref.read(staffRequestsRepositoryProvider).createRequest(
            venueId: widget.venueId,
            kind: _kind,
            title:
                typed.isEmpty ? _defaultTitle(clock, shift.firstOrNull) : typed,
            details: _detailsController.text.trim(),
            requestedRangeStart: !_needsDates || _startDate == null
                ? null
                : _formatDate(_startDate!),
            requestedRangeEnd: !_needsDates || _endDate == null
                ? null
                : _formatDate(_endDate!),
            requestedShiftId: _kind.needsShift ? _selectedShiftId : null,
          );
      if (!mounted) return;
      ref.invalidate(staffRequestsForVenueProvider(widget.venueId));
      Navigator.of(context).pop();
    } catch (error) {
      // Keep the dialog and everything typed; say what went wrong in place.
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = switch (error) {
          PostgrestException(code: '42501') =>
            'You can only ask to drop your own shifts at this venue.',
          PostgrestException(code: '22023') => error.message,
          _ => 'Could not submit request. Please try again.',
        };
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final clock = ref.watch(venueClockProvider);
    final userId = ref.watch(currentUserIdProvider);
    final allShifts =
        ref.watch(shiftsForVenueProvider(widget.venueId)).valueOrNull ??
            const <Shift>[];
    final choices = _kind.needsShift ? _shiftChoices() : const <Shift>[];
    return AlertDialog(
      title: const Text('New Staff Request'),
      content: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<StaffRequestKind>(
                initialValue: _kind,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Request Type'),
                items: [
                  for (final k in StaffRequestKind.creatable)
                    DropdownMenuItem(value: k, child: Text(k.displayLabel)),
                ],
                onChanged: (val) {
                  if (val != null) {
                    setState(() {
                      _kind = val;
                      _selectedShiftId = null;
                      _error = null;
                    });
                  }
                },
              ),
              if (_kind.needsShift) ...[
                const SizedBox(height: 12),
                if (choices.isEmpty)
                  Text(
                    _kind == StaffRequestKind.addShift
                        ? 'There are no open shifts to pick up right now.'
                        : 'You have no upcoming shifts to drop.',
                  )
                else
                  DropdownButtonFormField<String>(
                    initialValue: _selectedShiftId,
                    isExpanded: true,
                    decoration: InputDecoration(
                      labelText: _kind == StaffRequestKind.addShift
                          ? 'Open shift'
                          : 'Your shift',
                    ),
                    items: [
                      for (final shift in choices)
                        DropdownMenuItem(
                          value: shift.id,
                          child: Text(
                            '${shiftDayLabel(clock, shift)} · '
                            '${shiftTimeRangeLabel(clock, shift)} · '
                            '${shiftRoleLabel(shift)}'
                            '${_kind == StaffRequestKind.addShift && userId != null && overlappingShiftsFor(allShifts, userId, shift).isNotEmpty ? ' (overlaps your shift)' : ''}',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: (value) => setState(() {
                      _selectedShiftId = value;
                      _error = null;
                    }),
                  ),
              ],
              const SizedBox(height: 12),
              TextFormField(
                controller: _titleController,
                decoration: const InputDecoration(
                  labelText: 'Title',
                  hintText: 'Optional, e.g. Family wedding',
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _detailsController,
                decoration: const InputDecoration(
                  labelText: 'Details (optional)',
                ),
                maxLines: 2,
              ),
              if (_needsDates) ...[
                const SizedBox(height: 12),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('First day'),
                  subtitle: Text(
                    _startDate == null ? 'Not set' : _dayLabel(_startDate!),
                  ),
                  trailing: const Icon(Icons.edit_calendar_outlined),
                  onTap: () => _pickDate(isStart: true),
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Last day (optional)'),
                  subtitle: Text(
                    _endDate == null ? 'Same day' : _dayLabel(_endDate!),
                  ),
                  trailing: const Icon(Icons.edit_calendar_outlined),
                  onTap: () => _pickDate(isStart: false),
                ),
              ],
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
      ),
      actions: [
        TextButton(
          onPressed: _submitting ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _submitting ? null : _submit,
          child: _submitting
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Submit'),
        ),
      ],
    );
  }
}

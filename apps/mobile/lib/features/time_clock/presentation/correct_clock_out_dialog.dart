import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/errors/app_error.dart';
import '../../venues/application/venue_clock.dart';
import '../../venues/presentation/venue_time_widgets.dart';
import '../application/timesheet_providers.dart';

/// Lets a manager set the clock-out of someone's punch (a missed clock-out, or a wrong one),
/// in the venue's time, with a required reason. Saves inside the dialog and returns true once
/// the server accepted it; the change and the original value are audited server-side.
class CorrectClockOutDialog extends ConsumerStatefulWidget {
  const CorrectClockOutDialog({
    super.key,
    required this.timeEntryId,
    required this.personName,
    required this.clockInAt,
    this.clockOutAt,
  });

  final String timeEntryId;
  final String personName;
  final DateTime clockInAt;
  final DateTime? clockOutAt;

  static Future<bool> show(
    BuildContext context, {
    required String timeEntryId,
    required String personName,
    required DateTime clockInAt,
    DateTime? clockOutAt,
  }) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => CorrectClockOutDialog(
        timeEntryId: timeEntryId,
        personName: personName,
        clockInAt: clockInAt,
        clockOutAt: clockOutAt,
      ),
    );
    return saved ?? false;
  }

  @override
  ConsumerState<CorrectClockOutDialog> createState() =>
      _CorrectClockOutDialogState();
}

class _CorrectClockOutDialogState extends ConsumerState<CorrectClockOutDialog> {
  final _form = GlobalKey<FormState>();
  final _reason = TextEditingController();

  /// The chosen clock-out as a venue wall time.
  DateTime? _wall;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final clock = ref.read(venueClockProvider);
    if (widget.clockOutAt != null) {
      _wall = clock.wall(widget.clockOutAt!);
    }
  }

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    final clock = ref.read(venueClockProvider);
    final inWall = clock.wall(widget.clockInAt);
    final nowWall = clock.now;
    // Suggest the original clock-out, else eight hours after clock-in (capped at now).
    var suggested = _wall ?? inWall.add(const Duration(hours: 8));
    if (suggested.isAfter(nowWall)) suggested = nowWall;
    final picked = await pickVenueDateTime(
      context,
      initial: suggested,
      nowWall: nowWall,
      daysBack: nowWall.difference(inWall).inDays + 1,
      daysForward: 0,
    );
    if (picked != null && mounted) setState(() => _wall = picked);
  }

  String? _timeProblem(VenueClock clock) {
    final wall = _wall;
    if (wall == null) return 'Choose the clock-out time';
    final instant = clock.instant(wall);
    if (!instant.isAfter(widget.clockInAt)) {
      return 'Clock-out must be after the clock-in';
    }
    if (instant.isAfter(DateTime.now().add(const Duration(minutes: 1)))) {
      return 'Clock-out cannot be in the future';
    }
    return null;
  }

  Future<void> _save() async {
    final clock = ref.read(venueClockProvider);
    if (!ensureSupported(context, clock)) return;
    final problem = _timeProblem(clock);
    final formOk = _form.currentState?.validate() ?? false;
    if (problem != null || !formOk) {
      setState(() => _error = problem);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref.read(timesheetRepositoryProvider).correctClockOut(
            timeEntryId: widget.timeEntryId,
            clockOutAt: clock.instant(_wall!),
            reason: _reason.text.trim(),
          );
      if (mounted) Navigator.of(context).pop(true);
    } on AppError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Could not save the change. Try again.');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final clock = ref.watch(venueClockProvider);
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(
        widget.clockOutAt == null ? 'Close missed clock-out' : 'Fix clock-out',
      ),
      content: Form(
        key: _form,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.personName, style: theme.textTheme.titleMedium),
              const SizedBox(height: 4),
              Text(
                'Clocked in ${clock.formatDateTime(widget.clockInAt)}',
                style: theme.textTheme.bodyMedium,
              ),
              if (widget.clockOutAt != null)
                Text(
                  'Recorded clock-out ${clock.formatDateTime(widget.clockOutAt!)}',
                  style: theme.textTheme.bodyMedium,
                ),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                key: const ValueKey('pick-clock-out'),
                onPressed: _saving ? null : _pick,
                icon: const Icon(Icons.schedule),
                label: Text(
                  _wall == null
                      ? 'Choose clock-out time'
                      : 'Clock-out ${VenueClock.formatWallDateTime(_wall!)}',
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Venue time (${clock.timezoneId})',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: const ValueKey('correction-reason'),
                controller: _reason,
                enabled: !_saving,
                maxLength: 500,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: 'Reason',
                  hintText: 'e.g. Forgot to clock out; left at close',
                ),
                validator: (value) => (value ?? '').trim().length < 3
                    ? 'Say why you are changing this punch'
                    : null,
              ),
              Text(
                'Your name, the original time and this reason are kept with the punch.',
                style: theme.textTheme.bodySmall,
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(
                  _error!,
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: const Text('Save'),
        ),
      ],
    );
  }
}

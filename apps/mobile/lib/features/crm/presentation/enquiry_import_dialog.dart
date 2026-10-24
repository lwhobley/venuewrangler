import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/errors/app_error.dart';
import '../../../core/theme/ops_colors.dart';
import '../../ai/application/ai_providers.dart';
import '../../ai/domain/ai_models.dart';
import '../../venues/application/venue_clock.dart';
import '../../venues/domain/venue_timezone.dart';
import '../application/crm_providers.dart';
import '../domain/enquiry_import.dart';

/// "New lead/BEO from enquiry": the manager pastes a client email or message, AI extracts the
/// details, and the manager reviews them in an editable form before anything is created. As with
/// the manual forms, saving happens inside the dialog and it closes (popping `true`) only once
/// everything succeeded, so typed or pasted text is never lost to an error. Without AI (off for
/// the organization, declined, or failing) "Fill in by hand" opens the same form empty.
class EnquiryImportDialog extends ConsumerStatefulWidget {
  const EnquiryImportDialog({
    super.key,
    required this.venueId,
    required this.clock,
  });

  final String venueId;
  final VenueClock clock;

  @override
  ConsumerState<EnquiryImportDialog> createState() =>
      _EnquiryImportDialogState();
}

enum _Step { paste, review }

class _EnquiryImportDialogState extends ConsumerState<EnquiryImportDialog> {
  final _pasted = TextEditingController();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _phone = TextEditingController();
  final _company = TextEditingController();
  final _eventName = TextEditingController();
  final _eventType = TextEditingController();
  final _guests = TextEditingController();
  final _budget = TextEditingController();
  final _items = TextEditingController();
  final _notes = TextEditingController();

  _Step _step = _Step.paste;
  bool _extracting = false;
  String? _extractError;

  /// Wall date (UTC-flagged midnight) and minutes since midnight on the venue's clock.
  DateTime? _date;
  int? _start;
  int? _end;
  Set<String> _uncertain = {};
  List<String> _missing = const [];

  bool _alsoBeo = true;
  bool _saving = false;
  String? _error;
  final _fieldErrors = <String, String>{};

  // Steps already written, so a retry after a partial failure never duplicates them.
  String? _leadId;
  bool _noteSaved = false;
  bool _beoSaved = false;

  @override
  void dispose() {
    for (final c in [
      _pasted,
      _name,
      _email,
      _phone,
      _company,
      _eventName,
      _eventType,
      _guests,
      _budget,
      _items,
      _notes,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _extract() async {
    final text = _pasted.text.trim();
    if (text.isEmpty) {
      setState(() => _extractError = 'Paste the email or message first.');
      return;
    }
    setState(() {
      _extracting = true;
      _extractError = null;
    });
    try {
      final result = await ref.read(aiRepositoryProvider).parseEventEnquiry(
            venueId: widget.venueId,
            enquiryText: enquiryAiInput(text, widget.clock.now),
          );
      if (!mounted) return;
      _apply(result);
      setState(() {
        _extracting = false;
        _step = _Step.review;
      });
    } on AppError catch (error) {
      if (!mounted) return;
      setState(() {
        _extracting = false;
        _extractError = error.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _extracting = false;
        _extractError = 'Something went wrong reading that message.';
      });
    }
  }

  void _apply(EventEnquiryResult r) {
    _name.text = r.contactName ?? '';
    _email.text = r.contactEmail ?? '';
    _phone.text = r.contactPhone ?? '';
    _company.text = r.company ?? '';
    _eventName.text = r.eventName ?? '';
    _eventType.text = r.eventType ?? '';
    _guests.text = r.guestCount?.toString() ?? '';
    final budget = r.budgetUsd;
    _budget.text = budget == null
        ? ''
        : (budget == budget.roundToDouble()
            ? budget.round().toString()
            : budget.toStringAsFixed(2));
    _items.text = r.requestedItems.join('\n');
    _notes.text = r.notes ?? '';
    _date = r.eventDate;
    _start = r.startMinutes;
    _end = r.endMinutes;
    _uncertain = {...r.uncertain};
    _missing = r.missing;
    _alsoBeo = r.eventName != null || r.eventDate != null;
  }

  void _fillByHand() {
    setState(() {
      _alsoBeo = false;
      _step = _Step.review;
    });
  }

  /// Editing a field the AI was unsure about clears its highlight.
  void _confirmed(String key) {
    if (_uncertain.contains(key) || _fieldErrors.containsKey(key)) {
      setState(() {
        _uncertain.remove(key);
        _fieldErrors.remove(key);
      });
    }
  }

  InputDecoration _decoration(String key, String label, {String? hint}) {
    final unsure = _uncertain.contains(key);
    final warning = context.ops.warning.fg;
    return InputDecoration(
      labelText: label,
      hintText: hint,
      errorText: _fieldErrors[key],
      helperText: unsure ? 'Check this: the AI was not sure.' : null,
      helperStyle: unsure ? TextStyle(color: warning) : null,
      enabledBorder: unsure
          ? OutlineInputBorder(
              borderRadius: const BorderRadius.all(Radius.circular(12)),
              borderSide: BorderSide(color: warning, width: 2),
            )
          : null,
      suffixIcon:
          unsure ? Icon(Icons.help_outline, color: warning, size: 20) : null,
    );
  }

  Future<void> _pickDate() async {
    final now = widget.clock.now;
    final today = DateTime(now.year, now.month, now.day);
    final current = _date;
    final initial = current == null
        ? today
        : DateTime(current.year, current.month, current.day);
    final picked = await showDatePicker(
      context: context,
      initialDate: initial.isBefore(today) ? today : initial,
      firstDate: today,
      lastDate: DateTime(today.year + 2, today.month, today.day),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _date = DateTime.utc(picked.year, picked.month, picked.day);
      _uncertain.remove('event_date');
      _fieldErrors.remove('event_date');
    });
  }

  Future<void> _pickTime({required bool start}) async {
    final current = start ? _start : _end;
    final picked = await showTimePicker(
      context: context,
      initialTime: current == null
          ? const TimeOfDay(hour: 18, minute: 0)
          : TimeOfDay(hour: current ~/ 60, minute: current % 60),
    );
    if (picked == null || !mounted) return;
    setState(() {
      final minutes = picked.hour * 60 + picked.minute;
      if (start) {
        _start = minutes;
        _uncertain.remove('start_time');
        _fieldErrors.remove('start_time');
      } else {
        _end = minutes;
        _uncertain.remove('end_time');
      }
    });
  }

  String? _optional(TextEditingController c) {
    final v = c.text.trim();
    return v.isEmpty ? null : v;
  }

  bool _validate() {
    final errors = <String, String>{};
    if (_name.text.trim().isEmpty) {
      errors['contact_name'] = "Enter the contact's name.";
    }
    final email = _email.text.trim();
    if (email.isNotEmpty &&
        !RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(email)) {
      errors['contact_email'] = 'Enter a valid email or leave it blank.';
    }
    final guests = _guests.text.trim();
    if (guests.isNotEmpty && ((int.tryParse(guests) ?? 0) < 1)) {
      errors['guest_count'] = 'Enter a whole number of guests.';
    }
    final budget = _budget.text.trim();
    if (budget.isNotEmpty && ((num.tryParse(budget) ?? -1) < 0)) {
      errors['budget_usd'] = 'Enter an amount in dollars, like 2500.';
    }
    if (_alsoBeo) {
      if (_eventName.text.trim().isEmpty) {
        errors['event_name'] = 'Name the event to create a BEO.';
      }
      if (_date != null && _start == null) {
        errors['start_time'] = 'Pick a start time to create a BEO.';
      }
    }
    setState(() {
      _fieldErrors
        ..clear()
        ..addAll(errors);
    });
    return errors.isEmpty;
  }

  String _saveError(Object error) {
    if (error is PostgrestException && error.code == '42501') {
      return "You don't have permission to create this here.";
    }
    return 'Could not save. Check your connection and try again.';
  }

  Future<void> _save() async {
    if (!_validate()) return;
    if (!ensureSupported(context, widget.clock)) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    final repo = ref.read(crmRepositoryProvider);
    final guests = int.tryParse(_guests.text.trim());
    final budget = num.tryParse(_budget.text.trim());
    final items = [
      for (final line in _items.text.split('\n'))
        if (line.trim().isNotEmpty) line.trim(),
    ];
    try {
      if (_leadId == null) {
        final lead = await repo.createLead(
          venueId: widget.venueId,
          fullName: _name.text.trim(),
          email: _optional(_email),
          phone: _optional(_phone),
          company: _optional(_company),
          source: 'Enquiry',
          estimatedValueCents: budget == null ? null : (budget * 100).round(),
        );
        _leadId = lead.id;
      }
      if (!_noteSaved) {
        await repo.addNote(
          leadId: _leadId!,
          text: buildEnquiryNote(
            eventName: _optional(_eventName),
            eventType: _optional(_eventType),
            eventDate: _date,
            startMinutes: _start,
            endMinutes: _end,
            guestCount: guests,
            budgetUsd: budget,
            requestedItems: items,
            notes: _optional(_notes),
            missing: _missing,
          ),
        );
        _noteSaved = true;
      }
      if (_alsoBeo && !_beoSaved) {
        final date = _date;
        final start = _start;
        await repo.createBeo(
          venueId: widget.venueId,
          leadId: _leadId,
          eventName: _eventName.text.trim(),
          eventDate: date == null || start == null
              ? null
              : widget.clock.instant(
                  DateTime.utc(
                    date.year,
                    date.month,
                    date.day,
                    start ~/ 60,
                    start % 60,
                  ),
                ),
          guestCount: guests,
        );
        _beoSaved = true;
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      final created = _leadId != null;
      setState(() {
        _saving = false;
        _error = created
            ? 'The lead was created, but the rest did not save. '
                '${_saveError(e)} Tapping Create again finishes the rest '
                'without duplicating the lead.'
            : _saveError(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return switch (_step) {
      _Step.paste => _pasteStep(context),
      _Step.review => _reviewStep(context),
    };
  }

  Widget _pasteStep(BuildContext context) {
    return AlertDialog(
      title: const Text('New lead/BEO from enquiry'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Paste the client email or message. AI reads it and fills in a '
              'form for you to check; nothing is created until you confirm. '
              'The pasted text, including the client\'s contact details, is '
              'sent to our AI provider.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _pasted,
              autofocus: true,
              enabled: !_extracting,
              minLines: 5,
              maxLines: 10,
              maxLength: kMaxEnquiryChars,
              decoration: const InputDecoration(
                labelText: 'Email or message',
                alignLabelWithHint: true,
              ),
            ),
            if (_extractError != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _extractError!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed:
              _extracting ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: _extracting ? null : _fillByHand,
          child: const Text('Fill in by hand'),
        ),
        FilledButton(
          onPressed: _extracting ? null : _extract,
          child: _extracting
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Read with AI'),
        ),
      ],
    );
  }

  Widget _reviewStep(BuildContext context) {
    final theme = Theme.of(context);
    Widget field(
      String key,
      String label,
      TextEditingController controller, {
      TextInputType? keyboardType,
      int maxLines = 1,
    }) =>
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: TextField(
            key: ValueKey('enquiry-$key'),
            controller: controller,
            enabled: !_saving,
            keyboardType: keyboardType,
            minLines: 1,
            maxLines: maxLines,
            onChanged: (_) => _confirmed(key),
            decoration: _decoration(key, label),
          ),
        );

    Widget picker(
      String key,
      String label,
      String? value,
      VoidCallback onTap,
    ) =>
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: InkWell(
            key: ValueKey('enquiry-$key'),
            onTap: _saving ? null : onTap,
            child: InputDecorator(
              decoration: _decoration(key, label),
              child: Text(value ?? 'Not set'),
            ),
          ),
        );

    return AlertDialog(
      title: const Text('Check the enquiry'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Review and edit before saving. Fields marked "check this" were '
              'unclear in the message.',
              style: theme.textTheme.bodySmall,
            ),
            field('contact_name', 'Contact name', _name),
            field(
              'contact_email',
              'Email (optional)',
              _email,
              keyboardType: TextInputType.emailAddress,
            ),
            field(
              'contact_phone',
              'Phone (optional)',
              _phone,
              keyboardType: TextInputType.phone,
            ),
            field('company', 'Company (optional)', _company),
            field('event_name', 'Event name', _eventName),
            field('event_type', 'Event type (optional)', _eventType),
            picker(
              'event_date',
              'Date (venue time)',
              _date == null ? null : VenueTimezone.formatWallDate(_date!),
              _pickDate,
            ),
            picker(
              'start_time',
              'Start time',
              _start == null ? null : enquiryTimeLabel(_start!),
              () => _pickTime(start: true),
            ),
            picker(
              'end_time',
              'End time',
              _end == null ? null : enquiryTimeLabel(_end!),
              () => _pickTime(start: false),
            ),
            field(
              'guest_count',
              'Guests (optional)',
              _guests,
              keyboardType: TextInputType.number,
            ),
            field(
              'budget_usd',
              'Budget in dollars (optional)',
              _budget,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
            ),
            field(
              'requested_items',
              'Requested items, one per line',
              _items,
              maxLines: 6,
            ),
            field('notes', 'Notes', _notes, maxLines: 4),
            if (_missing.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text(
                'Still to ask the client',
                style: theme.textTheme.titleSmall,
              ),
              const SizedBox(height: 4),
              for (final item in _missing) Text('• $item'),
            ],
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _alsoBeo,
              onChanged: _saving ? null : (v) => setState(() => _alsoBeo = v),
              title: const Text('Also create a BEO draft'),
              subtitle: const Text(
                'Name, start time and guests go on the BEO. End time, items, '
                'budget and notes are saved as a note on the lead.',
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _error!,
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed:
              _saving ? null : () => Navigator.of(context).pop(_leadId != null),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(_saving ? 'Creating…' : 'Create'),
        ),
      ],
    );
  }
}

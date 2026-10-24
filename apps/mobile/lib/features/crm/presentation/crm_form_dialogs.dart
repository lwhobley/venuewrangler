import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../venues/domain/venue_clock.dart';
import '../../venues/presentation/venue_time_widgets.dart';
import '../application/crm_providers.dart';
import '../domain/beo_time.dart';

// The CRM create forms save from inside their dialog and close only once the write succeeded
// (popping `true`): a blank required field or a refused save is shown in place, so nothing the
// person typed is lost. Each owns its controllers so they are disposed only after the route has
// finished animating away.

String _saveErrorMessage(Object error, String what) {
  if (error is PostgrestException && error.code == '42501') {
    return "You don't have permission to $what here.";
  }
  return 'Could not $what. Check your connection and try again.';
}

Widget _errorLine(BuildContext context, String? error) => error == null
    ? const SizedBox.shrink()
    : Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Text(
          error,
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
      );

String? _optional(TextEditingController c) {
  final value = c.text.trim();
  return value.isEmpty ? null : value;
}

/// "New lead".
class NewLeadDialog extends ConsumerStatefulWidget {
  const NewLeadDialog({super.key, required this.venueId});

  final String venueId;

  @override
  ConsumerState<NewLeadDialog> createState() => _NewLeadDialogState();
}

class _NewLeadDialogState extends ConsumerState<NewLeadDialog> {
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _phone = TextEditingController();
  final _company = TextEditingController();
  String? _nameError;
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _phone.dispose();
    _company.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _nameError = "Enter the lead's name.");
      return;
    }
    setState(() {
      _nameError = null;
      _error = null;
      _saving = true;
    });
    try {
      await ref.read(crmRepositoryProvider).createLead(
            venueId: widget.venueId,
            fullName: name,
            email: _optional(_email),
            phone: _optional(_phone),
            company: _optional(_company),
          );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = _saveErrorMessage(e, 'create this lead');
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_saving,
      child: AlertDialog(
        title: const Text('New lead'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _name,
                autofocus: true,
                enabled: !_saving,
                decoration: InputDecoration(
                  labelText: 'Full name',
                  errorText: _nameError,
                ),
              ),
              TextField(
                controller: _email,
                enabled: !_saving,
                decoration:
                    const InputDecoration(labelText: 'Email (optional)'),
              ),
              TextField(
                controller: _phone,
                enabled: !_saving,
                decoration:
                    const InputDecoration(labelText: 'Phone (optional)'),
              ),
              TextField(
                controller: _company,
                enabled: !_saving,
                decoration:
                    const InputDecoration(labelText: 'Company (optional)'),
              ),
              _errorLine(context, _error),
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
            child: Text(_saving ? 'Creating…' : 'Create'),
          ),
        ],
      ),
    );
  }
}

/// "New BEO". The start time is picked and shown on the venue's clock (launch review D6) and
/// converted to an instant only when saved.
class NewBeoDialog extends ConsumerStatefulWidget {
  const NewBeoDialog({super.key, required this.venueId, required this.clock});

  final String venueId;
  final VenueClock clock;

  @override
  ConsumerState<NewBeoDialog> createState() => _NewBeoDialogState();
}

class _NewBeoDialogState extends ConsumerState<NewBeoDialog> {
  final _name = TextEditingController();
  final _guests = TextEditingController();

  /// A venue wall time, or null for no date yet.
  DateTime? _eventDate;
  String? _nameError;
  String? _guestsError;
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    _guests.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    final guestsText = _guests.text.trim();
    final guests = guestsText.isEmpty ? null : int.tryParse(guestsText);
    setState(() {
      _nameError = name.isEmpty ? 'Enter a name for the event.' : null;
      _guestsError = guestsText.isNotEmpty && (guests == null || guests < 1)
          ? 'Enter a whole number of guests.'
          : null;
      _error = null;
    });
    if (_nameError != null || _guestsError != null) return;
    setState(() => _saving = true);
    try {
      await ref.read(crmRepositoryProvider).createBeo(
            venueId: widget.venueId,
            eventName: name,
            eventDate:
                _eventDate == null ? null : widget.clock.instant(_eventDate!),
            guestCount: guests,
          );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = _saveErrorMessage(e, 'create this BEO');
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_saving,
      child: AlertDialog(
        title: const Text('New BEO'),
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
              TextField(
                controller: _guests,
                enabled: !_saving,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: 'Guest count (optional)',
                  errorText: _guestsError,
                ),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(
                  _eventDate == null
                      ? 'Event date and start time (optional)'
                      : VenueClock.formatWallDateTime(_eventDate!),
                ),
                trailing: const Icon(Icons.calendar_today_outlined),
                onTap: _saving
                    ? null
                    : () async {
                        final nowWall = widget.clock.now;
                        final picked = await pickVenueDateTime(
                          context,
                          initial: _eventDate ?? defaultBeoStartWall(nowWall),
                          nowWall: nowWall,
                          daysBack: 0,
                          daysForward: 730,
                        );
                        if (picked != null && mounted) {
                          setState(() => _eventDate = picked);
                        }
                      },
              ),
              _errorLine(context, _error),
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
            child: Text(_saving ? 'Creating…' : 'Create'),
          ),
        ],
      ),
    );
  }
}

/// "Add note" on a lead.
class AddLeadNoteDialog extends ConsumerStatefulWidget {
  const AddLeadNoteDialog({super.key, required this.leadId});

  final String leadId;

  @override
  ConsumerState<AddLeadNoteDialog> createState() => _AddLeadNoteDialogState();
}

class _AddLeadNoteDialogState extends ConsumerState<AddLeadNoteDialog> {
  final _text = TextEditingController();
  String? _textError;
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final text = _text.text.trim();
    if (text.isEmpty) {
      setState(() => _textError = 'Write the note first.');
      return;
    }
    setState(() {
      _textError = null;
      _error = null;
      _saving = true;
    });
    try {
      await ref
          .read(crmRepositoryProvider)
          .addNote(leadId: widget.leadId, text: text);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = _saveErrorMessage(e, 'add this note');
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_saving,
      child: AlertDialog(
        title: const Text('Add note'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _text,
              autofocus: true,
              enabled: !_saving,
              maxLines: 4,
              decoration: InputDecoration(
                labelText: 'Note',
                errorText: _textError,
              ),
            ),
            _errorLine(context, _error),
          ],
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

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../ai/application/ai_providers.dart';
import '../../ai/domain/ai_models.dart';
import '../../../core/errors/app_error.dart';
import '../application/workforce_providers.dart';
import '../data/workforce_repository.dart';
import '../domain/workforce_models.dart';

/// Opens the invite form for [venueId]. The dialog saves the invite and asks
/// `invite-send-email` to deliver it before closing; a refused invite keeps the dialog open
/// with the reason (nothing typed is lost). Reports the outcome in a snack bar.
Future<void> showInviteStaffDialog(
  BuildContext context, {
  required String venueId,
  required String? actorRole,
  String? prefillEmail,
  String? prefillName,
}) async {
  final outcome = await showDialog<InviteOutcome>(
    context: context,
    builder: (_) => InviteStaffDialog(
      venueId: venueId,
      actorRole: actorRole,
      prefillEmail: prefillEmail,
      prefillName: prefillName,
    ),
  );
  if (outcome == null || !context.mounted) return;
  ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(outcome.message)));
}

/// What happened to an invite the dialog or the Resend button issued.
class InviteOutcome {
  const InviteOutcome({required this.email, this.emailError});

  final String email;

  /// Set when the invite was saved but the email did not go out.
  final String? emailError;

  String get message => emailError == null
      ? 'Invitation emailed to $email.'
      : 'Invite saved for $email, but the email was not sent: $emailError';
}

/// Emails [invite] and reports how that went (never throws).
Future<InviteOutcome> deliverInvite(
  WorkforceRepository repository,
  Invite invite,
) async {
  try {
    await repository.sendInviteEmail(invite.id);
    return InviteOutcome(email: invite.email);
  } on InviteActionException catch (error) {
    return InviteOutcome(email: invite.email, emailError: error.message);
  }
}

class InviteStaffDialog extends ConsumerStatefulWidget {
  const InviteStaffDialog({
    super.key,
    required this.venueId,
    required this.actorRole,
    this.prefillEmail,
    this.prefillName,
  });

  final String venueId;

  /// The inviter's role for the venue: managers are not offered manager invites.
  final String? actorRole;
  final String? prefillEmail;
  final String? prefillName;

  @override
  ConsumerState<InviteStaffDialog> createState() => _InviteStaffDialogState();
}

class _InviteStaffDialogState extends ConsumerState<InviteStaffDialog> {
  final _formKey = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.prefillName);
  late final _email = TextEditingController(text: widget.prefillEmail);
  late final _roles = WorkforceRole.invitableBy(widget.actorRole);
  late var _role = WorkforceRole.staff;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    final repository = ref.read(workforceRepositoryProvider);
    try {
      final invite = await repository.createInvite(
        venueId: widget.venueId,
        email: _email.text.trim(),
        role: _role,
        fullName: _name.text.trim(),
      );
      ref.invalidate(invitesForVenueProvider(widget.venueId));
      final outcome = await deliverInvite(repository, invite);
      ref.invalidate(invitesForVenueProvider(widget.venueId));
      if (mounted) Navigator.of(context).pop(outcome);
    } on InviteActionException catch (error) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = error.message;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('Invite staff'),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextFormField(
                controller: _name,
                autofocus: widget.prefillName == null,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(labelText: 'Full name'),
                validator: (value) {
                  final name = value?.trim() ?? '';
                  if (name.isEmpty) return 'Enter their name';
                  if (name.length > 120) return 'Use 120 characters or fewer';
                  return null;
                },
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(labelText: 'Email'),
                validator: (value) {
                  final email = value?.trim() ?? '';
                  return RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(email)
                      ? null
                      : 'Enter a valid email address';
                },
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<WorkforceRole>(
                initialValue: _role,
                decoration: const InputDecoration(labelText: 'Role'),
                items: [
                  for (final value in _roles)
                    DropdownMenuItem(value: value, child: Text(value.label)),
                ],
                onChanged: _saving
                    ? null
                    : (value) => setState(() => _role = value ?? _role),
              ),
              const SizedBox(height: 12),
              Text(
                'We email them a link to join. They sign up with this '
                'address and land straight in your venue.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
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
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving ? null : _submit,
          child: _saving
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Send invite'),
        ),
      ],
    );
  }
}

/// "Paste a staff list": parses inside the dialog and closes only with a result, so a failed
/// parse keeps the pasted text and shows why.
class StaffImportDialog extends ConsumerStatefulWidget {
  const StaffImportDialog({super.key, required this.venueId});

  final String venueId;

  @override
  ConsumerState<StaffImportDialog> createState() => _StaffImportDialogState();
}

class _StaffImportDialogState extends ConsumerState<StaffImportDialog> {
  final _text = TextEditingController();
  bool _parsing = false;
  String? _error;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _parse() async {
    final pasted = _text.text.trim();
    if (pasted.isEmpty) {
      setState(() => _error = 'Paste the list first.');
      return;
    }
    setState(() {
      _parsing = true;
      _error = null;
    });
    try {
      final result = await ref
          .read(aiRepositoryProvider)
          .parseStaffImport(venueId: widget.venueId, pastedText: pasted);
      if (!mounted) return;
      if (result.staff.isEmpty) {
        setState(() {
          _parsing = false;
          _error = 'Nothing could be parsed from that text.';
        });
        return;
      }
      Navigator.of(context).pop(result);
    } on AppError catch (error) {
      if (mounted) {
        setState(() {
          _parsing = false;
          _error = error.message;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _parsing = false;
          _error = 'Could not read that list. Please try again.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Paste a staff list'),
      content: TextField(
        controller: _text,
        autofocus: true,
        maxLines: 8,
        enabled: !_parsing,
        decoration: InputDecoration(
          hintText:
              'Paste names/emails/phones copied from a spreadsheet or email…',
          errorText: _error,
          errorMaxLines: 3,
        ),
      ),
      actions: [
        TextButton(
          onPressed: _parsing ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _parsing ? null : _parse,
          child: _parsing
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Parse'),
        ),
      ],
    );
  }
}

/// Shows a parsed staff list; each row with an email opens a pre-filled invite.
Future<void> showStaffImportFlow(
  BuildContext context, {
  required String venueId,
  required String? actorRole,
}) async {
  final result = await showDialog<StaffImportResult>(
    context: context,
    builder: (_) => StaffImportDialog(venueId: venueId),
  );
  if (result == null || !context.mounted) return;

  await showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Review parsed staff'),
      content: SizedBox(
        width: double.maxFinite,
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final row in result.staff)
              ListTile(
                title: Text(row.fullName),
                subtitle: Text(
                  [
                    if (row.email != null) row.email!,
                    if (row.roleHint != null) row.roleHint!,
                  ].join(' · '),
                ),
                trailing: row.email == null
                    ? null
                    : TextButton(
                        onPressed: () {
                          Navigator.of(dialogContext).pop();
                          showInviteStaffDialog(
                            context,
                            venueId: venueId,
                            actorRole: actorRole,
                            prefillEmail: row.email,
                            prefillName: row.fullName,
                          );
                        },
                        child: const Text('Invite'),
                      ),
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

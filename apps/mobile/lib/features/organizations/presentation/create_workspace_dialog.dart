import 'package:flutter/material.dart';

import '../domain/workspace_name.dart';
import '../domain/workspace_timezones.dart';

typedef NewWorkspaceDetails = ({String name, String timezone});

/// Asks a signed-in user with no organization for the name and time zone of the workspace to
/// create. Returns null if dismissed. A stateful widget of its own (rather than a builder
/// closure) so it owns, and disposes, its controller only once the dialog is really gone.
class CreateWorkspaceDialog extends StatefulWidget {
  const CreateWorkspaceDialog({super.key});

  static Future<NewWorkspaceDetails?> show(BuildContext context) {
    return showDialog<NewWorkspaceDetails>(
      context: context,
      builder: (_) => const CreateWorkspaceDialog(),
    );
  }

  @override
  State<CreateWorkspaceDialog> createState() => _CreateWorkspaceDialogState();
}

class _CreateWorkspaceDialogState extends State<CreateWorkspaceDialog> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  String? _timezone = guessWorkspaceTimezone();

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _submit() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    Navigator.of(context).pop((name: _name.text.trim(), timezone: _timezone!));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Create your workspace'),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              controller: _name,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Venue name',
                hintText: 'The name above your door',
              ),
              validator: workspaceNameProblem,
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _timezone,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Time zone'),
              items: [
                for (final zone in kWorkspaceTimezones)
                  DropdownMenuItem(value: zone.id, child: Text(zone.label)),
              ],
              onChanged: (value) => setState(() => _timezone = value),
              validator: (value) =>
                  value == null ? 'Select your time zone' : null,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Create')),
      ],
    );
  }
}

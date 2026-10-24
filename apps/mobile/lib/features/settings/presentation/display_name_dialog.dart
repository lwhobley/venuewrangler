import 'package:flutter/material.dart';

/// Longest display name accepted; longer names break roster rows and chat headers.
const kMaxDisplayNameLength = 80;

/// Edits the signed-in person's display name. The name is validated and saved inside the
/// dialog: it stays open on a blank name or a failed save (showing why, keeping what was
/// typed) and closes only once [save] succeeds, returning true. Shared by Settings and the
/// staff Profile screen.
class DisplayNameDialog extends StatefulWidget {
  const DisplayNameDialog({super.key, this.initialName, required this.save});

  final String? initialName;

  /// Persists the trimmed name; throws on failure.
  final Future<void> Function(String name) save;

  static Future<bool> show(
    BuildContext context, {
    String? initialName,
    required Future<void> Function(String name) save,
  }) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => DisplayNameDialog(initialName: initialName, save: save),
    );
    return saved ?? false;
  }

  @override
  State<DisplayNameDialog> createState() => _DisplayNameDialogState();
}

class _DisplayNameDialogState extends State<DisplayNameDialog> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _name =
      TextEditingController(text: widget.initialName ?? '');
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_saving || !(_form.currentState?.validate() ?? false)) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.save(_name.text.trim());
      if (mounted) Navigator.of(context).pop(true);
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'Could not save your name. Check your connection and try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Display name'),
      content: Form(
        key: _form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextFormField(
              controller: _name,
              autofocus: true,
              enabled: !_saving,
              maxLength: kMaxDisplayNameLength,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                hintText: 'How your team sees you',
              ),
              onFieldSubmitted: (_) => _submit(),
              validator: (value) => (value ?? '').trim().isEmpty
                  ? 'Enter a name your team will recognise'
                  : null,
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving ? null : _submit,
          child: _saving
              ? const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Save'),
        ),
      ],
    );
  }
}

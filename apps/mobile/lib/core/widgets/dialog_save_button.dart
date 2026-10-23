import 'package:flutter/material.dart';

/// Keep a form and its controllers alive until validation and persistence both succeed.
class DialogSaveButton extends StatefulWidget {
  const DialogSaveButton({
    super.key,
    required this.label,
    required this.save,
    this.validate,
  });
  final String label;
  final Future<void> Function() save;
  final String? Function()? validate;
  @override
  State<DialogSaveButton> createState() => _DialogSaveButtonState();
}

class _DialogSaveButtonState extends State<DialogSaveButton> {
  bool _saving = false;
  String? _error;
  @override
  Widget build(BuildContext context) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_error != null)
            SizedBox(
              width: 240,
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          FilledButton(
            onPressed: _saving
                ? null
                : () async {
                    final problem = widget.validate?.call();
                    if (problem != null) {
                      setState(() => _error = problem);
                      return;
                    }
                    setState(() {
                      _saving = true;
                      _error = null;
                    });
                    try {
                      await widget.save();
                      if (context.mounted) Navigator.of(context).pop(true);
                    } catch (_) {
                      if (mounted) {
                        setState(
                          () => _error =
                              'Could not save. Your details are still here. Please try again.',
                        );
                      }
                    } finally {
                      if (mounted) setState(() => _saving = false);
                    }
                  },
            child: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(widget.label),
          ),
        ],
      );
}

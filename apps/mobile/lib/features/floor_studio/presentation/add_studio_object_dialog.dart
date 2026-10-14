import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../domain/floor_studio.dart';

/// Form for a new room object. The kind follows the description, and the size defaults to
/// that kind's usual footprint until the manager types their own. Position is the centre in
/// feet, pre-filled with the middle of the room. Pops with the new [StudioObject].
class AddStudioObjectDialog extends StatefulWidget {
  const AddStudioObjectDialog({
    super.key,
    required this.widthFeet,
    required this.depthFeet,
  });

  final double widthFeet;
  final double depthFeet;

  @override
  State<AddStudioObjectDialog> createState() => _AddStudioObjectDialogState();
}

class _AddStudioObjectDialogState extends State<AddStudioObjectDialog> {
  final _description = TextEditingController();
  final _width = TextEditingController();
  final _depth = TextEditingController();
  final _x = TextEditingController();
  final _y = TextEditingController();
  var _sizeEdited = false;
  String? _error;

  StudioObjectKind get _kind => studioObjectKindFor(_description.text);

  @override
  void initState() {
    super.initState();
    _applyKindDefaults();
    _x.text = formatStudioFeet(widget.widthFeet / 2);
    _y.text = formatStudioFeet(widget.depthFeet / 2);
  }

  @override
  void dispose() {
    _description.dispose();
    _width.dispose();
    _depth.dispose();
    _x.dispose();
    _y.dispose();
    super.dispose();
  }

  void _applyKindDefaults() {
    _width.text = formatStudioFeet(_kind.defaultWidthFeet);
    _depth.text = formatStudioFeet(_kind.defaultDepthFeet);
  }

  void _add() {
    final description = _description.text.trim();
    final width = double.tryParse(_width.text);
    final depth = double.tryParse(_depth.text);
    final x = double.tryParse(_x.text);
    final y = double.tryParse(_y.text);
    if (description.isEmpty) {
      setState(() => _error = 'Describe the object, for example "Stage".');
      return;
    }
    if (width == null ||
        depth == null ||
        !width.isFinite ||
        !depth.isFinite ||
        width <= 0 ||
        depth <= 0) {
      setState(() => _error = 'Enter a positive width and depth in feet.');
      return;
    }
    if (x == null || y == null || !x.isFinite || !y.isFinite) {
      setState(() => _error = 'Enter the position in feet.');
      return;
    }
    Navigator.of(context).pop(
      StudioObject(
        id: const Uuid().v4(),
        kind: _kind,
        description: description,
        x: x,
        y: y,
        widthFeet: width,
        depthFeet: depth,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add object'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _description,
              autofocus: true,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Description',
                hintText: 'Stage, bar, dance floor…',
              ),
              onChanged: (_) => setState(() {
                if (!_sizeEdited) _applyKindDefaults();
              }),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 6, bottom: 10),
              child: Text(
                'Kind: ${_kind.label}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _width,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(labelText: 'Width (ft)'),
                    onChanged: (_) => _sizeEdited = true,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _depth,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(labelText: 'Depth (ft)'),
                    onChanged: (_) => _sizeEdited = true,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _x,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                      labelText: 'Centre X (ft)',
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _y,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                      labelText: 'Centre Y (ft)',
                    ),
                  ),
                ),
              ],
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _add, child: const Text('Add')),
      ],
    );
  }
}

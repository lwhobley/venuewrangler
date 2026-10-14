import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../floor/application/floor_providers.dart';
import '../../venues/application/venues_providers.dart';
import '../application/floor_studio_providers.dart';
import '../domain/floor_studio.dart';
import 'add_studio_object_dialog.dart';
import 'floor_studio_3d_view.dart';
import 'studio_object_plan.dart';

/// Measure a floor plan's room, generate a round-table layout for a guest count, place
/// custom objects (stage, bar, ...) in it, save it, and preview it in 3D. Managers only.
class FloorStudioScreen extends ConsumerStatefulWidget {
  const FloorStudioScreen({super.key});

  @override
  ConsumerState<FloorStudioScreen> createState() => _FloorStudioScreenState();
}

class _FloorStudioScreenState extends ConsumerState<FloorStudioScreen> {
  final _width = TextEditingController();
  final _depth = TextEditingController();
  final _guests = TextEditingController();
  String? _floorPlanId;
  var _verified = false;
  var _show3D = false;
  var _saving = false;
  List<StudioLayoutOption> _options = const [];
  int _selectedOption = 0;
  String? _error;
  var _loadedFor = '';
  var _objects = <StudioObject>[];
  String? _selectedObjectId;

  @override
  void dispose() {
    _width.dispose();
    _depth.dispose();
    _guests.dispose();
    super.dispose();
  }

  void _loadFromSaved(FloorStudioLayout? saved, String floorPlanId) {
    if (_loadedFor == floorPlanId) return;
    _loadedFor = floorPlanId;
    _options = const [];
    _error = null;
    _show3D = false;
    _objects = [...?saved?.objects];
    _selectedObjectId = null;
    if (saved == null) {
      _width.clear();
      _depth.clear();
      _guests.clear();
      _verified = false;
      return;
    }
    _width.text = saved.widthFeet.toStringAsFixed(1);
    _depth.text = saved.depthFeet.toStringAsFixed(1);
    _verified = saved.verified;
  }

  void _generate(FloorStudioLayout? saved) {
    final width = double.tryParse(_width.text);
    final depth = double.tryParse(_depth.text);
    final guests = int.tryParse(_guests.text);
    if (width == null || depth == null || guests == null) {
      setState(() => _error = 'Enter room width, depth, and a guest count.');
      return;
    }
    try {
      final options = generateStudioLayouts(
        widthFeet: width,
        depthFeet: depth,
        guestCount: guests,
        tableDiameterFeet: saved?.tableDiameterFeet ?? defaultTableDiameterFeet,
        seatsPerTable: saved?.seatsPerTable ?? defaultSeatsPerTable,
      );
      setState(() {
        _options = options;
        _selectedOption = 0;
        _error = null;
      });
    } on FormatException catch (e) {
      setState(() {
        _options = const [];
        _error = e.message;
      });
    }
  }

  Future<void> _save(String venueId, FloorStudioLayout? saved) async {
    final width = double.tryParse(_width.text);
    final depth = double.tryParse(_depth.text);
    final floorPlanId = _floorPlanId;
    if (width == null || depth == null || floorPlanId == null) {
      setState(() => _error = 'Enter room width and depth.');
      return;
    }
    // Tables come from the generated option, or else the saved layout, so objects can be
    // saved on their own.
    final tables = _options.isNotEmpty
        ? _options[_selectedOption].tables
        : saved?.tables ?? const <StudioTable>[];
    if (tables.isEmpty && _objects.isEmpty && saved == null) {
      setState(() => _error = 'Generate a layout before saving.');
      return;
    }
    final objects = [
      for (final object in _objects)
        clampStudioObject(object, widthFeet: width, depthFeet: depth),
    ];
    final issues = validateStudioLayout(
      widthFeet: width,
      depthFeet: depth,
      tableDiameterFeet: saved?.tableDiameterFeet ?? defaultTableDiameterFeet,
      tables: tables,
    );
    if (issues.isNotEmpty) {
      const message = 'Measurements changed since generating. Generate again.';
      setState(() => _error = message);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref.read(floorStudioRepositoryProvider).saveLayout(
            FloorStudioLayout(
              id: saved?.id,
              venueId: venueId,
              floorPlanId: floorPlanId,
              widthFeet: width,
              depthFeet: depth,
              verified: _verified,
              tableDiameterFeet:
                  saved?.tableDiameterFeet ?? defaultTableDiameterFeet,
              seatsPerTable: saved?.seatsPerTable ?? defaultSeatsPerTable,
              tables: tables,
              objects: objects,
            ),
          );
      ref.invalidate(floorStudioLayoutsProvider(venueId));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Floor plan layout saved.')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Could not save: $error')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _addObject(double width, double depth) async {
    final object = await showDialog<StudioObject>(
      context: context,
      builder: (_) => AddStudioObjectDialog(widthFeet: width, depthFeet: depth),
    );
    if (object == null || !mounted) return;
    final placed =
        clampStudioObject(object, widthFeet: width, depthFeet: depth);
    setState(() {
      _objects = [..._objects, placed];
      _selectedObjectId = placed.id;
    });
  }

  void _moveObject(StudioObject moved) => setState(() {
        _objects = [
          for (final object in _objects) object.id == moved.id ? moved : object,
        ];
      });

  void _rotateSelected(double width, double depth) {
    final selected = _selectedObject;
    if (selected == null) return;
    _moveObject(
      clampStudioObject(
        selected.copyWith(
          rotationDegrees: (selected.rotationDegrees + 90) % 360,
        ),
        widthFeet: width,
        depthFeet: depth,
      ),
    );
  }

  Future<void> _removeSelected() async {
    final selected = _selectedObject;
    if (selected == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove ${selected.description}?'),
        content: const Text(
          'The object leaves the plan when you save the floor plan layout.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _objects = [
        for (final object in _objects)
          if (object.id != selected.id) object,
      ];
      _selectedObjectId = null;
    });
  }

  StudioObject? get _selectedObject =>
      _objects.where((o) => o.id == _selectedObjectId).firstOrNull;

  @override
  Widget build(BuildContext context) {
    final venue = ref.watch(activeVenueProvider);
    final canManage =
        ref.watch(canManageActiveVenueProvider).valueOrNull ?? false;
    return Scaffold(
      appBar: AppBar(title: const Text('Floor plan studio')),
      body: venue == null
          ? const Center(child: Text('Select a venue first.'))
          : !canManage
              ? const Center(
                  child:
                      Text('Only venue managers can edit floor plan layouts.'),
                )
              : _body(venue.id),
    );
  }

  Widget _body(String venueId) {
    final plans = ref.watch(floorPlansProvider);
    final layouts = ref.watch(floorStudioLayoutsProvider(venueId));
    return plans.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => Center(child: Text('$error')),
      data: (items) {
        if (items.isEmpty) {
          return const Center(
            child: Text('Create a floor plan first, then measure it here.'),
          );
        }
        final selected = items.any((p) => p.id == _floorPlanId)
            ? _floorPlanId!
            : items.first.id;
        if (selected != _floorPlanId) _floorPlanId = selected;
        final saved = layouts.valueOrNull
            ?.where((l) => l.floorPlanId == selected)
            .firstOrNull;
        // Wait for the saved layouts: latching on a still-loading (null) result would
        // skip populating the fields once the real layout arrives.
        if (layouts.hasValue || layouts.hasError) {
          _loadFromSaved(saved, selected);
        }
        final previewTables = _options.isNotEmpty
            ? _options[_selectedOption].tables
            : saved?.tables ?? const <StudioTable>[];
        final width = double.tryParse(_width.text) ?? saved?.widthFeet ?? 0;
        final depth = double.tryParse(_depth.text) ?? saved?.depthFeet ?? 0;

        return ListView(
          padding: const EdgeInsets.all(20),
          children: [
            DropdownButtonFormField<String>(
              initialValue: selected,
              decoration: const InputDecoration(labelText: 'Floor plan'),
              items: [
                for (final p in items)
                  DropdownMenuItem(value: p.id, child: Text(p.name)),
              ],
              onChanged: (value) => setState(() {
                _floorPlanId = value;
                _loadedFor = '';
              }),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _width,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration:
                        const InputDecoration(labelText: 'Width (feet)'),
                    // The room plan redraws from these fields as they change.
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _depth,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration:
                        const InputDecoration(labelText: 'Depth (feet)'),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
              ],
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: _verified,
              onChanged: (value) => setState(() => _verified = value ?? false),
              title: const Text('I verified these measurements'),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _guests,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Guest count for layout',
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                FilledButton.icon(
                  onPressed: () => _generate(saved),
                  icon: const Icon(Icons.auto_fix_high),
                  label: const Text('Generate layouts'),
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
            if (_options.isNotEmpty) ...[
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                children: [
                  for (var i = 0; i < _options.length; i++)
                    ChoiceChip(
                      label: Text(
                        '${_options[i].name} · ${_options[i].tables.length} tables',
                      ),
                      selected: _selectedOption == i,
                      onSelected: (_) => setState(() => _selectedOption = i),
                    ),
                ],
              ),
            ],
            if (width > 0 && depth > 0) ...[
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Room plan',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => _addObject(width, depth),
                    icon: const Icon(Icons.add),
                    label: const Text('Add object'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              StudioObjectPlan(
                widthFeet: width,
                depthFeet: depth,
                tables: previewTables,
                tableDiameterFeet:
                    saved?.tableDiameterFeet ?? defaultTableDiameterFeet,
                objects: _objects,
                selectedId: _selectedObjectId,
                onSelect: (id) => setState(() => _selectedObjectId = id),
                onMove: _moveObject,
              ),
              const SizedBox(height: 6),
              const Text(
                'Drag an object to move it. Tap one to select it.',
                style: TextStyle(fontSize: 12),
              ),
              for (final object in _objects)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  selected: object.id == _selectedObjectId,
                  title: Text(object.description),
                  subtitle: Text(
                    '${object.kind.label} · '
                    '${object.widthFeet.toStringAsFixed(0)} × '
                    '${object.depthFeet.toStringAsFixed(0)} ft',
                  ),
                  onTap: () => setState(() => _selectedObjectId = object.id),
                ),
              if (_selectedObject != null)
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Selected: ${_selectedObject!.description}',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    TextButton.icon(
                      onPressed: () => _rotateSelected(width, depth),
                      icon: const Icon(Icons.rotate_90_degrees_ccw_outlined),
                      label: const Text('Rotate'),
                    ),
                    TextButton.icon(
                      onPressed: _removeSelected,
                      icon: const Icon(Icons.delete_outline),
                      label: const Text('Remove'),
                    ),
                  ],
                ),
            ],
            // A saved layout can always be saved again, so removing its last object sticks.
            if (previewTables.isNotEmpty ||
                _objects.isNotEmpty ||
                saved != null) ...[
              if (previewTables.isNotEmpty) ...[
                const SizedBox(height: 16),
                Builder(
                  builder: (context) {
                    final issues = validateStudioLayout(
                      widthFeet: width,
                      depthFeet: depth,
                      tableDiameterFeet:
                          saved?.tableDiameterFeet ?? defaultTableDiameterFeet,
                      tables: previewTables,
                    );
                    return Text(
                      issues.isEmpty
                          ? 'No table boundary or clearance conflicts detected.'
                          : issues.join('\n'),
                      style: TextStyle(
                        color: issues.isEmpty
                            ? Colors.green.shade800
                            : Theme.of(context).colorScheme.error,
                      ),
                    );
                  },
                ),
              ],
              const SizedBox(height: 10),
              FilledButton.icon(
                onPressed: _saving ? null : () => _save(venueId, saved),
                icon: const Icon(Icons.save_outlined),
                label: Text(_saving ? 'Saving…' : 'Save floor plan layout'),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: () => setState(() => _show3D = !_show3D),
                icon: const Icon(Icons.view_in_ar_outlined),
                label: Text(_show3D ? 'Hide 3D preview' : 'Show 3D preview'),
              ),
              if (_show3D) ...[
                const SizedBox(height: 10),
                FloorStudio3DView(
                  sceneData: buildStudioSceneData(
                    layout: FloorStudioLayout(
                      venueId: venueId,
                      floorPlanId: selected,
                      widthFeet: width,
                      depthFeet: depth,
                      verified: _verified,
                      tables: previewTables,
                      objects: _objects,
                    ),
                    guestCount: previewTables.length *
                        (saved?.seatsPerTable ?? defaultSeatsPerTable),
                  ),
                ),
                const SizedBox(height: 6),
                const Text(
                  '3D preview is an illustrative render of this layout, not a photograph. '
                  'People and food are stylized placeholders, not the actual guests or menu.',
                  style: TextStyle(fontSize: 12),
                ),
              ],
            ],
          ],
        );
      },
    );
  }
}

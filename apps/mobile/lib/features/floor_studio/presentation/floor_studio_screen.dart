import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../floor/application/floor_providers.dart';
import '../../venues/application/venues_providers.dart';
import '../application/floor_studio_providers.dart';
import '../domain/floor_studio.dart';
import 'floor_studio_3d_view.dart';

/// Measure a floor plan's room, generate a round-table layout for a guest count, save it,
/// and preview it in 3D. Managers only.
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
    if (_options.isEmpty) {
      setState(() => _error = 'Generate a layout before saving.');
      return;
    }
    final tables = _options[_selectedOption].tables;
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

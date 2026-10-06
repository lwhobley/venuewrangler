import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/ops_colors.dart';
import '../../../core/widgets/blueprint_grid.dart';
import '../../../core/widgets/state_views.dart';
import '../../venues/application/venues_providers.dart';
import '../application/floor_editor_controller.dart';
import '../application/floor_providers.dart';
import '../domain/editor_table.dart';
import '../domain/floor_plan.dart';

/// Visual floor plan layout editor: pan/zoom canvas, drag tables, create / resize / rotate,
/// snap-to-grid, undo, local draft and publish. Edits only touch layout columns — live table
/// status is never changed from here.
class FloorPlanEditorScreen extends ConsumerStatefulWidget {
  const FloorPlanEditorScreen({super.key});

  @override
  ConsumerState<FloorPlanEditorScreen> createState() =>
      _FloorPlanEditorScreenState();
}

class _FloorPlanEditorScreenState extends ConsumerState<FloorPlanEditorScreen> {
  final _viewerKey = GlobalKey();
  final _tc = TransformationController();

  FloorPlan? _plan;
  bool _loading = true;
  String? _loadError;
  bool _noPlan = false;
  bool _touchingTable = false;
  bool _fitted = false;

  // Offset between the pointer and the table centre at the start of a move.
  Offset _grab = Offset.zero;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _tc.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final venue = ref.read(activeVenueProvider);
    if (venue == null) return;
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final repo = ref.read(floorRepositoryProvider);
      final plans = await repo.getFloorPlans(venueId: venue.id);
      if (plans.isEmpty) {
        if (mounted) {
          setState(() {
            _noPlan = true;
            _loading = false;
          });
        }
        return;
      }
      final plan =
          plans.firstWhere((p) => p.isActive, orElse: () => plans.first);
      final tables = await repo.getFloorTables(floorPlanId: plan.id);
      if (!mounted) return;
      final editor = ref.read(floorEditorProvider.notifier);
      editor.load(
        live: tables,
        planWidth: plan.width,
        planHeight: plan.height,
      );
      setState(() {
        _plan = plan;
        _noPlan = false;
        _loading = false;
        _fitted = false;
      });
      if (await editor.hasDraft(plan.id) && mounted) {
        final resume = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Resume your draft?'),
            content: const Text(
              'You have an unpublished draft of this floor plan on this device.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Start from live'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Resume draft'),
              ),
            ],
          ),
        );
        if (resume == true) {
          await editor.restoreDraft(plan.id);
        } else if (resume == false) {
          await editor.discardDraft(plan.id);
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loadError = 'Could not load the floor plan: $e';
          _loading = false;
        });
      }
    }
  }

  Future<void> _createPlan() async {
    final venue = ref.read(activeVenueProvider);
    if (venue == null) return;
    try {
      await ref
          .read(floorRepositoryProvider)
          .createFloorPlan(venueId: venue.id, name: 'Main floor');
      await _load();
    } catch (e) {
      _toast('Could not create a floor plan: $e', error: true);
    }
  }

  void _toast(String message, {bool error = false}) {
    if (!mounted) return;
    final scheme = Theme.of(context).colorScheme;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: error ? TextStyle(color: scheme.onError) : null,
        ),
        backgroundColor: error ? scheme.error : null,
      ),
    );
  }

  // ---- coordinates ---------------------------------------------------------

  /// Pointer position (global) → plan coordinates, through pan/zoom.
  Offset _scene(Offset global) {
    final box = _viewerKey.currentContext!.findRenderObject()! as RenderBox;
    return _tc.toScene(box.globalToLocal(global));
  }

  Offset _viewportCentre() {
    final box = _viewerKey.currentContext!.findRenderObject()! as RenderBox;
    return _tc.toScene(box.size.center(Offset.zero));
  }

  void _fit(Size viewport, FloorEditorState s) {
    if (_fitted || viewport.isEmpty) return;
    _fitted = true;
    final scale = math.min(
          viewport.width / s.planWidth,
          viewport.height / s.planHeight,
        ) *
        0.95;
    final dx = (viewport.width - s.planWidth * scale) / 2;
    final dy = (viewport.height - s.planHeight * scale) / 2;
    final fitted = Matrix4.translationValues(dx, dy, 0)
      ..scaleByDouble(scale, scale, 1, 1);
    // Called from a LayoutBuilder; changing the controller notifies listeners, which must
    // not happen mid-layout.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _tc.value = fitted;
    });
  }

  // ---- actions -------------------------------------------------------------

  Future<void> _addTable() async {
    final editor = ref.read(floorEditorProvider.notifier);
    final result = await _showTableForm(
      title: 'Add table',
      initial: (
        label: editor.nextLabel(),
        shape: 'round',
        capacity: 4,
        section: 'main',
      ),
      confirmLabel: 'Add',
    );
    if (result == null) return;
    final c = _viewportCentre();
    editor.addTable(
      label: result.label,
      shape: result.shape,
      capacity: result.capacity,
      section: result.section,
      cx: c.dx,
      cy: c.dy,
    );
  }

  Future<void> _editSelected() async {
    final editor = ref.read(floorEditorProvider.notifier);
    final t = ref.read(floorEditorProvider).selected;
    if (t == null) return;
    final result = await _showTableForm(
      title: 'Edit ${t.label}',
      initial: (
        label: t.label,
        shape: t.shape,
        capacity: t.capacity,
        section: t.section,
      ),
      confirmLabel: 'Save',
    );
    if (result == null) return;
    editor.updateProps(
      t.id,
      label: result.label,
      shape: result.shape,
      capacity: result.capacity,
      section: result.section,
    );
  }

  Future<TableFormResult?> _showTableForm({
    required String title,
    required TableFormResult initial,
    required String confirmLabel,
  }) {
    return showModalBottomSheet<TableFormResult>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: _TableForm(
          title: title,
          initial: initial,
          confirmLabel: confirmLabel,
        ),
      ),
    );
  }

  void _delete() {
    final s = ref.read(floorEditorProvider);
    final id = s.selectedId;
    if (id == null) return;
    final error = ref.read(floorEditorProvider.notifier).deleteTable(id);
    if (error != null) _toast(error, error: true);
  }

  Future<void> _saveDraft() async {
    final plan = _plan;
    if (plan == null) return;
    await ref.read(floorEditorProvider.notifier).saveDraft(plan.id);
    _toast('Draft saved on this device.');
  }

  Future<void> _publish() async {
    final plan = _plan;
    final venue = ref.read(activeVenueProvider);
    if (plan == null || venue == null) return;
    final editor = ref.read(floorEditorProvider.notifier);
    final issues = editor.blockingIssues();
    if (issues.isNotEmpty) {
      _toast(issues.first, error: true);
      return;
    }
    final state = ref.read(floorEditorProvider);
    final overlaps = state.overlappingIds.length;
    final removed = state.published.keys
        .where((id) => !state.tables.any((t) => t.id == id))
        .length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Publish floor plan?'),
        content: Text(
          'This updates the live floor plan for everyone on this venue.'
          '${removed > 0 ? '\n\n$removed table${removed == 1 ? '' : 's'} will be removed.' : ''}'
          '${overlaps > 0 ? '\n\n$overlaps tables overlap each other.' : ''}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Publish'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await editor.publish(
        repo: ref.read(floorRepositoryProvider),
        venueId: venue.id,
        planId: plan.id,
      );
      _toast('Floor plan published.');
      await _load();
    } catch (e) {
      _toast('Publish failed: $e', error: true);
    }
  }

  Future<bool> _confirmLeave() async {
    final plan = _plan;
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Leave without publishing?'),
        content: const Text('Your changes are not live yet.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, 'stay'),
            child: const Text('Keep editing'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, 'discard'),
            child: const Text('Discard'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, 'draft'),
            child: const Text('Save draft'),
          ),
        ],
      ),
    );
    if (choice == 'draft' && plan != null) {
      await ref.read(floorEditorProvider.notifier).saveDraft(plan.id);
    }
    return choice == 'draft' || choice == 'discard';
  }

  // ---- build ---------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(floorEditorProvider);
    final editor = ref.read(floorEditorProvider.notifier);

    return PopScope(
      canPop: !state.hasChanges,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final leave = await _confirmLeave();
        if (leave && context.mounted) context.pop();
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Edit floor plan'),
          actions: [
            IconButton(
              icon: const Icon(Icons.undo),
              tooltip: 'Undo',
              onPressed: state.canUndo ? editor.undo : null,
            ),
            IconButton(
              icon: Icon(state.snap ? Icons.grid_on : Icons.grid_off),
              tooltip: state.snap ? 'Snap to grid: on' : 'Snap to grid: off',
              onPressed: editor.toggleSnap,
            ),
            IconButton(
              icon: const Icon(Icons.save_outlined),
              tooltip: 'Save draft',
              onPressed: state.hasChanges ? _saveDraft : null,
            ),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilledButton(
                onPressed: state.hasChanges && !state.saving ? _publish : null,
                child: state.saving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Publish'),
              ),
            ),
          ],
        ),
        floatingActionButton: _plan == null
            ? null
            : FloatingActionButton.extended(
                onPressed: _addTable,
                icon: const Icon(Icons.add),
                label: const Text('Add table'),
              ),
        body: _buildBody(state, editor),
      ),
    );
  }

  Widget _buildBody(FloorEditorState state, FloorEditorController editor) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_loadError != null) {
      return ErrorState(message: _loadError!, onRetry: _load);
    }
    if (_noPlan) {
      return EmptyState(
        icon: Icons.map_outlined,
        message: 'This venue has no floor plan yet.',
        action: FilledButton.icon(
          onPressed: _createPlan,
          icon: const Icon(Icons.add),
          label: const Text('Create floor plan'),
        ),
      );
    }

    final overlapping = state.overlappingIds;
    return Column(
      children: [
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              _fit(constraints.biggest, state);
              return ClipRect(
                child: InteractiveViewer(
                  key: _viewerKey,
                  transformationController: _tc,
                  constrained: false,
                  minScale: 0.2,
                  maxScale: 3,
                  boundaryMargin: const EdgeInsets.all(400),
                  panEnabled: !_touchingTable,
                  scaleEnabled: !_touchingTable,
                  child: ListenableBuilder(
                    listenable: _tc,
                    builder: (context, _) {
                      final scale = _tc.value.getMaxScaleOnAxis();
                      return _Canvas(
                        state: state,
                        overlapping: overlapping,
                        handleScale: scale,
                        onBackgroundTap: () => editor.select(null),
                        onSelect: editor.select,
                        onTouch: (down) =>
                            setState(() => _touchingTable = down),
                        onMoveStart: (t, global) {
                          editor.beginChange();
                          editor.select(t.id);
                          _grab = _scene(global) -
                              Offset(t.x + t.width / 2, t.y + t.height / 2);
                        },
                        onMove: (t, global) {
                          final c = _scene(global) - _grab;
                          editor.moveTo(
                            t.id,
                            c.dx - t.width / 2,
                            c.dy - t.height / 2,
                          );
                        },
                        onResizeStart: editor.beginChange,
                        onResize: (t, global) {
                          final c =
                              Offset(t.x + t.width / 2, t.y + t.height / 2);
                          final v = _scene(global) - c;
                          final a = -t.rotation * math.pi / 180;
                          final lx = v.dx * math.cos(a) - v.dy * math.sin(a);
                          final ly = v.dx * math.sin(a) + v.dy * math.cos(a);
                          editor.resizeTo(t.id, lx.abs() * 2, ly.abs() * 2);
                        },
                        onRotateStart: editor.beginChange,
                        onRotate: (t, global) {
                          final c =
                              Offset(t.x + t.width / 2, t.y + t.height / 2);
                          final v = _scene(global) - c;
                          editor.rotateTo(
                            t.id,
                            math.atan2(v.dy, v.dx) * 180 / math.pi + 90,
                          );
                        },
                      );
                    },
                  ),
                ),
              );
            },
          ),
        ),
        if (state.selected != null)
          _Inspector(
            table: state.selected!,
            overlaps: overlapping.contains(state.selectedId),
            onEdit: _editSelected,
            onDelete: _delete,
            onRotate: (delta) {
              final t = state.selected!;
              editor.beginChange();
              editor.rotateTo(t.id, t.rotation + delta);
            },
          )
        else
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              state.tables.isEmpty
                  ? 'Tap "Add table" to start laying out the floor.'
                  : 'Tap a table to select it. Drag to move; pinch to zoom.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ),
      ],
    );
  }
}

class _Canvas extends StatelessWidget {
  const _Canvas({
    required this.state,
    required this.overlapping,
    required this.handleScale,
    required this.onBackgroundTap,
    required this.onSelect,
    required this.onTouch,
    required this.onMoveStart,
    required this.onMove,
    required this.onResizeStart,
    required this.onResize,
    required this.onRotateStart,
    required this.onRotate,
  });

  final FloorEditorState state;
  final Set<String> overlapping;
  final double handleScale;
  final VoidCallback onBackgroundTap;
  final ValueChanged<String> onSelect;
  final ValueChanged<bool> onTouch;
  final void Function(EditorTable, Offset) onMoveStart;
  final void Function(EditorTable, Offset) onMove;
  final VoidCallback onResizeStart;
  final void Function(EditorTable, Offset) onResize;
  final VoidCallback onRotateStart;
  final void Function(EditorTable, Offset) onRotate;

  @override
  Widget build(BuildContext context) {
    final ops = context.ops;
    return GestureDetector(
      onTap: onBackgroundTap,
      child: Container(
        width: state.planWidth,
        height: state.planHeight,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          border: Border.all(color: ops.panelBorder, width: 2),
        ),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(child: BlueprintGrid(cell: kGridUnit)),
            for (final t in state.tables)
              _TableNode(
                table: t,
                selected: t.id == state.selectedId,
                overlapping: overlapping.contains(t.id),
                handleScale: handleScale,
                onTouch: onTouch,
                onSelect: () => onSelect(t.id),
                onMoveStart: (g) => onMoveStart(t, g),
                onMove: (g) => onMove(t, g),
                onResizeStart: onResizeStart,
                onResize: (g) => onResize(t, g),
                onRotateStart: onRotateStart,
                onRotate: (g) => onRotate(t, g),
              ),
          ],
        ),
      ),
    );
  }
}

class _TableNode extends StatelessWidget {
  const _TableNode({
    required this.table,
    required this.selected,
    required this.overlapping,
    required this.handleScale,
    required this.onTouch,
    required this.onSelect,
    required this.onMoveStart,
    required this.onMove,
    required this.onResizeStart,
    required this.onResize,
    required this.onRotateStart,
    required this.onRotate,
  });

  final EditorTable table;
  final bool selected;
  final bool overlapping;
  final double handleScale;
  final ValueChanged<bool> onTouch;
  final VoidCallback onSelect;
  final ValueChanged<Offset> onMoveStart;
  final ValueChanged<Offset> onMove;
  final VoidCallback onResizeStart;
  final ValueChanged<Offset> onResize;
  final VoidCallback onRotateStart;
  final ValueChanged<Offset> onRotate;

  BorderRadius _radius() => switch (table.shape) {
        'round' => BorderRadius.circular(math.max(table.width, table.height)),
        'booth' => const BorderRadius.vertical(
            top: Radius.circular(28),
            bottom: Radius.circular(6),
          ),
        _ => BorderRadius.circular(10),
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ops = context.ops;
    final scheme = theme.colorScheme;
    final handle = 30 / handleScale;

    final edge = overlapping
        ? ops.danger.fg
        : selected
            ? scheme.secondary
            : ops.panelBorder;

    final body = Container(
      decoration: BoxDecoration(
        color: ops.of(overlapping ? Tone.danger : Tone.neutral).bg,
        borderRadius: _radius(),
        border:
            Border.all(color: edge, width: selected || overlapping ? 3 : 1.5),
      ),
      alignment: Alignment.center,
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                table.label,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                  fontSize: 16,
                ),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.people_outline,
                    size: 13,
                    color: scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 2),
                  Text(
                    '${table.capacity}',
                    style: theme.textTheme.bodySmall?.copyWith(fontSize: 12),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );

    return Positioned(
      left: table.x,
      top: table.y,
      width: table.width,
      height: table.height,
      child: Transform.rotate(
        angle: table.rotation * math.pi / 180,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(
              child: Listener(
                onPointerDown: (_) => onTouch(true),
                onPointerUp: (_) => onTouch(false),
                onPointerCancel: (_) => onTouch(false),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: onSelect,
                  onPanStart: (d) => onMoveStart(d.globalPosition),
                  onPanUpdate: (d) => onMove(d.globalPosition),
                  child: Semantics(
                    label:
                        'Table ${table.label}, ${table.capacity} seats, ${table.shape}',
                    child: body,
                  ),
                ),
              ),
            ),
            if (selected) ...[
              // Rotate handle, above the top edge.
              Positioned(
                left: table.width / 2 - handle / 2,
                top: -handle * 1.4,
                width: handle,
                height: handle,
                child: _Handle(
                  icon: Icons.rotate_right,
                  onTouch: onTouch,
                  onStart: (_) => onRotateStart(),
                  onUpdate: onRotate,
                ),
              ),
              // Resize handle, bottom-right corner.
              Positioned(
                left: table.width - handle / 2,
                top: table.height - handle / 2,
                width: handle,
                height: handle,
                child: _Handle(
                  icon: Icons.open_in_full,
                  onTouch: onTouch,
                  onStart: (_) => onResizeStart(),
                  onUpdate: onResize,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Handle extends StatelessWidget {
  const _Handle({
    required this.icon,
    required this.onTouch,
    required this.onStart,
    required this.onUpdate,
  });

  final IconData icon;
  final ValueChanged<bool> onTouch;
  final ValueChanged<Offset> onStart;
  final ValueChanged<Offset> onUpdate;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Listener(
      onPointerDown: (_) => onTouch(true),
      onPointerUp: (_) => onTouch(false),
      onPointerCancel: (_) => onTouch(false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: (d) => onStart(d.globalPosition),
        onPanUpdate: (d) => onUpdate(d.globalPosition),
        child: FittedBox(
          child: Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: scheme.secondary,
              border: Border.all(color: scheme.surface, width: 2),
            ),
            child: Icon(icon, size: 16, color: scheme.onSecondary),
          ),
        ),
      ),
    );
  }
}

class _Inspector extends StatelessWidget {
  const _Inspector({
    required this.table,
    required this.overlaps,
    required this.onEdit,
    required this.onDelete,
    required this.onRotate,
  });

  final EditorTable table;
  final bool overlaps;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final ValueChanged<double> onRotate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ops = context.ops;
    return Material(
      color: theme.colorScheme.surfaceContainerHigh,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(table.label, style: theme.textTheme.titleMedium),
                    Text(
                      '${table.shape} · ${table.capacity} seats · ${table.section}',
                      style: theme.textTheme.bodySmall,
                    ),
                    if (overlaps)
                      Row(
                        children: [
                          Icon(
                            Icons.warning_amber_rounded,
                            size: 14,
                            color: ops.danger.fg,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            'Overlaps another table',
                            style: theme.textTheme.bodySmall
                                ?.copyWith(color: ops.danger.fg),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.rotate_left),
                tooltip: 'Rotate left 15°',
                onPressed: () => onRotate(-15),
              ),
              IconButton(
                icon: const Icon(Icons.rotate_right),
                tooltip: 'Rotate right 15°',
                onPressed: () => onRotate(15),
              ),
              IconButton(
                icon: const Icon(Icons.edit_outlined),
                tooltip: 'Edit table',
                onPressed: onEdit,
              ),
              IconButton(
                icon: Icon(Icons.delete_outline, color: ops.danger.fg),
                tooltip: 'Delete table',
                onPressed: onDelete,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

typedef TableFormResult = ({
  String label,
  String shape,
  int capacity,
  String section,
});

class _TableForm extends StatefulWidget {
  const _TableForm({
    required this.title,
    required this.initial,
    required this.confirmLabel,
  });

  final String title;
  final TableFormResult initial;
  final String confirmLabel;

  @override
  State<_TableForm> createState() => _TableFormState();
}

class _TableFormState extends State<_TableForm> {
  late final _label = TextEditingController(text: widget.initial.label);
  late final _section = TextEditingController(text: widget.initial.section);
  late String _shape = widget.initial.shape;
  late int _capacity = widget.initial.capacity;
  String? _error;

  @override
  void dispose() {
    _label.dispose();
    _section.dispose();
    super.dispose();
  }

  void _submit() {
    final label = _label.text.trim();
    if (label.isEmpty) {
      setState(() => _error = 'Give the table a label');
      return;
    }
    Navigator.pop(
      context,
      (
        label: label,
        shape: _shape,
        capacity: _capacity,
        section: _section.text.trim().isEmpty ? 'main' : _section.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.title, style: theme.textTheme.titleLarge),
            const SizedBox(height: 16),
            TextField(
              controller: _label,
              autofocus: true,
              textCapitalization: TextCapitalization.characters,
              decoration: InputDecoration(
                labelText: 'Label',
                errorText: _error,
              ),
              onChanged: (_) {
                if (_error != null) setState(() => _error = null);
              },
            ),
            const SizedBox(height: 16),
            Text('Shape', style: theme.textTheme.labelMedium),
            const SizedBox(height: 8),
            SegmentedButton<String>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: 'round', label: Text('Round')),
                ButtonSegment(value: 'square', label: Text('Square')),
                ButtonSegment(value: 'rect', label: Text('Rect')),
                ButtonSegment(value: 'booth', label: Text('Booth')),
              ],
              selected: {_shape},
              onSelectionChanged: (s) => setState(() => _shape = s.first),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Text('Seats', style: theme.textTheme.labelMedium),
                const Spacer(),
                IconButton.outlined(
                  icon: const Icon(Icons.remove),
                  tooltip: 'Fewer seats',
                  onPressed:
                      _capacity > 1 ? () => setState(() => _capacity--) : null,
                ),
                SizedBox(
                  width: 48,
                  child: Text(
                    '$_capacity',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                IconButton.outlined(
                  icon: const Icon(Icons.add),
                  tooltip: 'More seats',
                  onPressed:
                      _capacity < 30 ? () => setState(() => _capacity++) : null,
                ),
              ],
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _section,
              decoration: const InputDecoration(labelText: 'Section'),
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: _submit,
              child: Text(widget.confirmLabel),
            ),
          ],
        ),
      ),
    );
  }
}

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../data/floor_repository.dart';
import '../domain/editor_table.dart';
import '../domain/floor_table.dart';

/// Layout snap step, in plan units. The blueprint grid is drawn at the same pitch.
const double kGridUnit = 20;
const double kMinTableSize = 40;

class FloorEditorState {
  const FloorEditorState({
    this.tables = const [],
    this.selectedId,
    this.snap = true,
    this.history = const [],
    this.published = const {},
    this.planWidth = 1000,
    this.planHeight = 800,
    this.saving = false,
  });

  final List<EditorTable> tables;
  final String? selectedId;
  final bool snap;
  final List<List<EditorTable>> history;
  final Map<String, EditorTable> published;
  final double planWidth;
  final double planHeight;
  final bool saving;

  EditorTable? get selected {
    for (final t in tables) {
      if (t.id == selectedId) return t;
    }
    return null;
  }

  bool get canUndo => history.isNotEmpty;

  /// Differs from what's live (new, moved, edited or removed tables).
  bool get hasChanges {
    if (tables.length != published.length) return true;
    for (final t in tables) {
      final p = published[t.id];
      if (p == null || !p.sameLayoutAs(t)) return true;
    }
    return false;
  }

  Set<String> get overlappingIds {
    final ids = <String>{};
    for (var i = 0; i < tables.length; i++) {
      for (var j = i + 1; j < tables.length; j++) {
        if (tables[i].overlaps(tables[j])) {
          ids
            ..add(tables[i].id)
            ..add(tables[j].id);
        }
      }
    }
    return ids;
  }

  FloorEditorState copyWith({
    List<EditorTable>? tables,
    String? selectedId,
    bool clearSelection = false,
    bool? snap,
    List<List<EditorTable>>? history,
    Map<String, EditorTable>? published,
    double? planWidth,
    double? planHeight,
    bool? saving,
  }) =>
      FloorEditorState(
        tables: tables ?? this.tables,
        selectedId: clearSelection ? null : (selectedId ?? this.selectedId),
        snap: snap ?? this.snap,
        history: history ?? this.history,
        published: published ?? this.published,
        planWidth: planWidth ?? this.planWidth,
        planHeight: planHeight ?? this.planHeight,
        saving: saving ?? this.saving,
      );
}

class FloorEditorController extends StateNotifier<FloorEditorState> {
  FloorEditorController({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage(),
        super(const FloorEditorState());

  final FlutterSecureStorage _storage;
  int _newCounter = 0;

  static const _maxHistory = 50;

  double _snap(double v) =>
      state.snap ? (v / kGridUnit).round() * kGridUnit : v;

  void load({
    required List<FloorTable> live,
    required double planWidth,
    required double planHeight,
  }) {
    final tables = live.map(EditorTable.fromFloorTable).toList();
    state = FloorEditorState(
      tables: tables,
      published: {for (final t in tables) t.id: t},
      planWidth: planWidth,
      planHeight: planHeight,
    );
  }

  // ---- history -------------------------------------------------------------

  /// Call once at the start of a drag/resize/rotate gesture so the whole gesture undoes at once.
  void beginChange() {
    final h = [...state.history, state.tables];
    state = state.copyWith(
      history: h.length > _maxHistory ? h.sublist(h.length - _maxHistory) : h,
    );
  }

  void undo() {
    if (!state.canUndo) return;
    final h = [...state.history];
    final prev = h.removeLast();
    final stillSelected = prev.any((t) => t.id == state.selectedId);
    state = state.copyWith(
      tables: prev,
      history: h,
      clearSelection: !stillSelected,
    );
  }

  // ---- selection & mode ----------------------------------------------------

  void select(String? id) => state = id == null
      ? state.copyWith(clearSelection: true)
      : state.copyWith(selectedId: id);

  void toggleSnap() => state = state.copyWith(snap: !state.snap);

  // ---- editing -------------------------------------------------------------

  EditorTable _clamp(EditorTable t) {
    final b = t.bounds;
    var dx = 0.0;
    var dy = 0.0;
    if (b.left < 0) dx = -b.left;
    if (b.right > state.planWidth) dx = state.planWidth - b.right;
    if (b.top < 0) dy = -b.top;
    if (b.bottom > state.planHeight) dy = state.planHeight - b.bottom;
    return (dx == 0 && dy == 0) ? t : t.copyWith(x: t.x + dx, y: t.y + dy);
  }

  void _replace(EditorTable updated) {
    state = state.copyWith(
      tables: [
        for (final t in state.tables) t.id == updated.id ? updated : t,
      ],
    );
  }

  /// Moves a table's top-left to [x],[y] (snapped, kept inside the plan).
  void moveTo(String id, double x, double y) {
    final t = state.tables.firstWhere((t) => t.id == id);
    _replace(_clamp(t.copyWith(x: _snap(x), y: _snap(y))));
  }

  void resizeTo(String id, double width, double height) {
    final t = state.tables.firstWhere((t) => t.id == id);
    final square = t.shape == 'round' || t.shape == 'square';
    var w = math.max(kMinTableSize, _snap(width));
    var h = math.max(kMinTableSize, _snap(height));
    if (square) w = h = math.max(w, h);
    // Resize about the centre so rotated tables don't swing while a handle is dragged.
    final cx = t.x + t.width / 2;
    final cy = t.y + t.height / 2;
    _replace(
      _clamp(t.copyWith(x: cx - w / 2, y: cy - h / 2, width: w, height: h)),
    );
  }

  void rotateTo(String id, double degrees) {
    final t = state.tables.firstWhere((t) => t.id == id);
    var d = degrees % 360;
    if (d < 0) d += 360;
    if (state.snap) d = ((d / 15).round() * 15) % 360;
    _replace(_clamp(t.copyWith(rotation: d)));
  }

  void updateProps(
    String id, {
    String? label,
    String? shape,
    int? capacity,
    String? section,
  }) {
    beginChange();
    final t = state.tables.firstWhere((t) => t.id == id);
    var updated = t.copyWith(
      label: label,
      shape: shape,
      capacity: capacity,
      section: section,
    );
    if (shape == 'round' || shape == 'square') {
      final side = math.max(updated.width, updated.height);
      updated = updated.copyWith(width: side, height: side);
    }
    _replace(_clamp(updated));
  }

  String nextLabel() {
    final used = state.tables.map((t) => t.label).toSet();
    var n = state.tables.length + 1;
    while (used.contains('T$n')) {
      n++;
    }
    return 'T$n';
  }

  /// Adds a table centred on ([cx],[cy]) and selects it.
  EditorTable addTable({
    required String label,
    required String shape,
    required int capacity,
    String section = 'main',
    required double cx,
    required double cy,
  }) {
    beginChange();
    final (w, h) = switch (shape) {
      'round' => (80.0, 80.0),
      'square' => (80.0, 80.0),
      'booth' => (140.0, 60.0),
      _ => (120.0, 80.0),
    };
    final created = _clamp(
      EditorTable(
        id: '${EditorTable.newPrefix}${_newCounter++}',
        label: label,
        shape: shape,
        capacity: capacity,
        x: _snap(cx - w / 2),
        y: _snap(cy - h / 2),
        width: w,
        height: h,
        section: section,
      ),
    );
    state = state.copyWith(
      tables: [...state.tables, created],
      selectedId: created.id,
    );
    return created;
  }

  /// Returns an error message if the table can't be removed, otherwise removes it.
  String? deleteTable(String id) {
    final t = state.tables.firstWhere((t) => t.id == id);
    if (t.status != 'available' && !t.isNew) {
      return '${t.label} is in use (${t.status.replaceAll('_', ' ')}). '
          'Clear it first.';
    }
    beginChange();
    state = state.copyWith(
      tables: [
        for (final x in state.tables)
          if (x.id != id) x,
      ],
      clearSelection: true,
    );
    return null;
  }

  // ---- validation ----------------------------------------------------------

  /// Problems that must be fixed before publishing.
  List<String> blockingIssues() {
    final issues = <String>[];
    final seen = <String>{};
    for (final t in state.tables) {
      final key = t.label.trim().toLowerCase();
      if (key.isEmpty) issues.add('A table has no label.');
      if (!seen.add(key)) issues.add('Duplicate label "${t.label}".');
    }
    return issues;
  }

  // ---- drafts (local, per floor plan) -------------------------------------

  String _draftKey(String planId) => 'floor_draft_$planId';

  Future<void> saveDraft(String planId) async {
    try {
      await _storage.write(
        key: _draftKey(planId),
        value: jsonEncode([for (final t in state.tables) t.toJson()]),
      );
    } catch (_) {}
  }

  Future<bool> hasDraft(String planId) async {
    try {
      return (await _storage.read(key: _draftKey(planId))) != null;
    } catch (_) {
      return false;
    }
  }

  Future<void> restoreDraft(String planId) async {
    try {
      final raw = await _storage.read(key: _draftKey(planId));
      if (raw == null) return;
      final list = (jsonDecode(raw) as List)
          .map((e) => EditorTable.fromJson(e as Map<String, dynamic>))
          .toList();
      // Tables deleted on the server since the draft was saved shouldn't resurrect.
      final live = state.published;
      final kept = [
        for (final t in list)
          if (t.isNew || live.containsKey(t.id)) t,
      ];
      for (final t in kept.where((t) => t.isNew)) {
        final n =
            int.tryParse(t.id.substring(EditorTable.newPrefix.length)) ?? 0;
        _newCounter = math.max(_newCounter, n + 1);
      }
      state = state.copyWith(
        tables: kept,
        history: const [],
        clearSelection: true,
      );
    } catch (_) {}
  }

  Future<void> discardDraft(String planId) async {
    try {
      await _storage.delete(key: _draftKey(planId));
    } catch (_) {}
  }

  // ---- publish -------------------------------------------------------------

  /// Writes the layout to the live floor plan. Only geometry/label columns are sent, so live
  /// status and seating are never overwritten.
  Future<void> publish({
    required FloorRepository repo,
    required String venueId,
    required String planId,
  }) async {
    state = state.copyWith(saving: true);
    try {
      final removed = [
        for (final id in state.published.keys)
          if (!state.tables.any((t) => t.id == id)) id,
      ];
      await repo.saveLayout(
        venueId: venueId,
        floorPlanId: planId,
        created: [
          for (final t in state.tables)
            if (t.isNew) t,
        ],
        updated: [
          for (final t in state.tables)
            if (!t.isNew && !(state.published[t.id]?.sameLayoutAs(t) ?? false))
              t,
        ],
        removedIds: removed,
      );
      await discardDraft(planId);
    } finally {
      state = state.copyWith(saving: false);
    }
  }
}

final floorEditorProvider =
    StateNotifierProvider.autoDispose<FloorEditorController, FloorEditorState>(
  (ref) => FloorEditorController(),
);

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/theme/ops_colors.dart';
import '../../../core/widgets/home_button.dart';
import '../../../core/widgets/state_views.dart';
import '../../venues/application/venues_providers.dart';
import '../../workforce/application/workforce_providers.dart';
import '../../workforce/domain/workforce_models.dart';
import '../application/schedules_providers.dart';
import '../domain/schedule_timeline.dart';
import '../domain/shift.dart';

const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

enum _DragMode { move, resizeStart, resizeEnd }

class _Drag {
  _Drag(this.mode, this.shift, this.row);

  final _DragMode mode;
  final Shift shift;
  final int row;
  double dx = 0;
  double dy = 0;
}

class _Row {
  const _Row({required this.staffId, required this.name, this.role});

  final String? staffId;
  final String name;
  final String? role;
}

/// Drag-and-drop schedule board: one row per person (plus open shifts), a 24-hour business
/// day across. Drag a shift sideways to retime it, between rows to reassign it, or pull its
/// edges to change start/end. Changes save immediately and revert if the database refuses.
class ScheduleTimelineScreen extends ConsumerStatefulWidget {
  const ScheduleTimelineScreen({super.key});

  @override
  ConsumerState<ScheduleTimelineScreen> createState() =>
      _ScheduleTimelineScreenState();
}

class _ScheduleTimelineScreenState
    extends ConsumerState<ScheduleTimelineScreen> {
  static const double _leftWidth = 116;
  static const double _rowHeight = 68;
  static const double _headerHeight = 30;
  static const int _startHour = 6;

  late DateTime _date = businessDateFor(DateTime.now());
  double _hourWidth = 56;
  _Drag? _drag;
  final Map<String, Shift> _pending = {};
  late final ScrollController _hScroll = ScrollController(
    initialScrollOffset: 10 * _hourWidth,
  );

  @override
  void dispose() {
    _hScroll.dispose();
    super.dispose();
  }

  /// Zooms the hour scale while keeping the same time at the left edge in view.
  void _zoom(double delta) {
    final old = _hourWidth;
    final offset = _hScroll.hasClients ? _hScroll.offset : 0.0;
    setState(() => _hourWidth = old + delta);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_hScroll.hasClients) return;
      final target = offset * _hourWidth / old;
      _hScroll.jumpTo(target.clamp(0, _hScroll.position.maxScrollExtent));
    });
  }

  DateTime get _windowStart => businessDayStart(_date, startHour: _startHour);
  DateTime get _windowEnd => _windowStart.add(const Duration(hours: 24));

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

  String _errorMessage(Object e) {
    if (e is PostgrestException) {
      return switch (e.code) {
        '42501' => 'Only managers can change the schedule.',
        '23514' => 'A shift must end after it starts.',
        _ => 'Could not save the change. Please try again.',
      };
    }
    return 'Could not save the change. Please try again.';
  }

  // ---- data ----------------------------------------------------------------

  List<Shift> _effective(List<Shift> base) {
    final list = [for (final s in base) _pending[s.id] ?? s];
    final d = _drag;
    if (d == null) return list;
    final preview = _previewFor(d);
    return [for (final s in list) s.id == d.shift.id ? preview : s];
  }

  Shift _previewFor(_Drag d, {List<_Row>? rows}) {
    final s = d.shift;
    var times = (start: s.startTime, end: s.endTime);
    switch (d.mode) {
      case _DragMode.move:
        times = movedBy(s.startTime, s.endTime, d.dx, _hourWidth);
      case _DragMode.resizeStart:
        times = resizedStartBy(s.startTime, s.endTime, d.dx, _hourWidth);
      case _DragMode.resizeEnd:
        times = resizedEndBy(s.startTime, s.endTime, d.dx, _hourWidth);
    }
    var next = s.copyWith(startTime: times.start, endTime: times.end);
    final r = rows ?? _rows;
    if (d.mode == _DragMode.move && r.isNotEmpty) {
      final target =
          (d.row + (d.dy / _rowHeight).round()).clamp(0, r.length - 1);
      final staffId = r[target].staffId;
      next = staffId == null
          ? next.copyWith(clearStaff: true)
          : next.copyWith(staffId: staffId);
    }
    return next;
  }

  List<_Row> _rows = const [];

  List<_Row> _buildRows(List<RosterMember> roster, List<Shift> shifts) {
    final rows = <_Row>[];
    final seen = <String>{};
    final sorted = [...roster]..sort(
        (a, b) => (a.displayName ?? '').toLowerCase().compareTo(
              (b.displayName ?? '').toLowerCase(),
            ),
      );
    for (final m in sorted) {
      if (!seen.add(m.userId)) continue;
      rows.add(
        _Row(
          staffId: m.userId,
          name: m.displayName ?? 'Team member ${m.userId.substring(0, 4)}',
          role: WorkforceRole.values
              .where((r) => r.toDb() == m.role)
              .map((r) => r.label)
              .firstOrNull,
        ),
      );
    }
    for (final s in shifts) {
      final id = s.staffId;
      if (id != null && seen.add(id)) {
        rows.add(_Row(staffId: id, name: 'Former team member'));
      }
    }
    rows.add(const _Row(staffId: null, name: 'Open shifts'));
    return rows;
  }

  // ---- commands ------------------------------------------------------------

  Future<void> _commit(_Drag d, List<Shift> allEffectiveBefore) async {
    final updated = _previewFor(d);
    final orig = d.shift;
    final unchanged = updated.startTime == orig.startTime &&
        updated.endTime == orig.endTime &&
        updated.staffId == orig.staffId;
    setState(() => _drag = null);
    if (unchanged) return;

    final venueId = orig.venueId;
    setState(() => _pending[orig.id] = updated);
    try {
      await ref.read(schedulesRepositoryProvider).updateShift(
            shiftId: orig.id,
            staffId: updated.staffId,
            clearStaff: updated.staffId == null && orig.staffId != null,
            startTime: updated.startTime,
            endTime: updated.endTime,
          );
      ref.invalidate(shiftsForVenueProvider(venueId));
      await ref.read(shiftsForVenueProvider(venueId).future);
      if (mounted) setState(() => _pending.remove(orig.id));

      final others = allEffectiveBefore.where((s) => s.id != orig.id);
      if (updated.staffId != null &&
          others.any(
            (s) => s.staffId == updated.staffId && shiftsOverlap(s, updated),
          )) {
        _toast('Saved — but it overlaps another shift for the same person.');
      }
    } catch (e) {
      if (mounted) setState(() => _pending.remove(orig.id));
      _toast(_errorMessage(e), error: true);
    }
  }

  Future<void> _create({
    required String venueId,
    required List<_Row> rows,
    required String? staffId,
    required DateTime start,
  }) async {
    final result = await _showShiftForm(
      title: 'Add shift',
      confirmLabel: 'Add',
      rows: rows,
      initial: (
        staffId: staffId,
        role: '',
        start: start,
        end: start.add(const Duration(hours: 4)),
      ),
    );
    if (result == null) return;
    try {
      await ref.read(schedulesRepositoryProvider).createShift(
            venueId: venueId,
            staffId: result.staffId,
            roleLabel: result.role.isEmpty ? null : result.role,
            startTime: result.start,
            endTime: result.end,
          );
      ref.invalidate(shiftsForVenueProvider(venueId));
    } catch (e) {
      _toast(_errorMessage(e), error: true);
    }
  }

  Future<void> _edit(Shift shift, List<_Row> rows) async {
    final result = await _showShiftForm(
      title: 'Edit shift',
      confirmLabel: 'Save',
      rows: rows,
      allowDelete: true,
      initial: (
        staffId: shift.staffId,
        role: shift.roleLabel ?? '',
        start: shift.startTime,
        end: shift.endTime,
      ),
    );
    if (result == null) return;
    final repo = ref.read(schedulesRepositoryProvider);
    try {
      if (result.delete) {
        await repo.deleteShift(shift.id);
      } else {
        await repo.updateShift(
          shiftId: shift.id,
          staffId: result.staffId,
          clearStaff: result.staffId == null,
          roleLabel: result.role,
          startTime: result.start,
          endTime: result.end,
        );
      }
      ref.invalidate(shiftsForVenueProvider(shift.venueId));
    } catch (e) {
      _toast(_errorMessage(e), error: true);
    }
  }

  Future<_ShiftFormResult?> _showShiftForm({
    required String title,
    required String confirmLabel,
    required List<_Row> rows,
    required ({
      String? staffId,
      String role,
      DateTime start,
      DateTime end
    }) initial,
    bool allowDelete = false,
  }) {
    return showModalBottomSheet<_ShiftFormResult>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: _ShiftForm(
          title: title,
          confirmLabel: confirmLabel,
          rows: rows,
          initial: initial,
          allowDelete: allowDelete,
        ),
      ),
    );
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime.now().subtract(const Duration(days: 365)),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (picked != null) setState(() => _date = picked);
  }

  // ---- build ---------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final venue = ref.watch(activeVenueProvider);
    if (venue == null) {
      return const Scaffold(body: Center(child: Text('No venue selected.')));
    }
    final shiftsAsync = ref.watch(shiftsForVenueProvider(venue.id));
    final rosterAsync = ref.watch(rosterForVenueProvider(venue.id));

    return Scaffold(
      appBar: AppBar(
        leading: const HomeButton(),
        title: const Text('Schedule board'),
        actions: [
          IconButton(
            icon: const Icon(Icons.zoom_out),
            tooltip: 'Zoom out',
            onPressed: _hourWidth > 32 ? () => _zoom(-12) : null,
          ),
          IconButton(
            icon: const Icon(Icons.zoom_in),
            tooltip: 'Zoom in',
            onPressed: _hourWidth < 104 ? () => _zoom(12) : null,
          ),
          IconButton(
            icon: const Icon(Icons.view_list_outlined),
            tooltip: 'List view',
            onPressed: () => context.go('/schedules'),
          ),
        ],
      ),
      body: shiftsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, __) => ErrorState(
          message: 'Could not load the schedule.',
          onRetry: () => ref.invalidate(shiftsForVenueProvider(venue.id)),
        ),
        data: (shifts) {
          final roster = rosterAsync.valueOrNull ?? const <RosterMember>[];
          final canEdit =
              ref.watch(canManageActiveVenueProvider).valueOrNull ?? false;
          _rows = _buildRows(roster, shifts);
          return _buildBoard(venue.id, shifts, canEdit);
        },
      ),
    );
  }

  Widget _buildBoard(String venueId, List<Shift> baseShifts, bool canEdit) {
    final shifts = _effective(baseShifts);
    final conflicts = conflictingShiftIds(shifts);
    final rows = _rows;
    final windowStart = _windowStart;
    final windowEnd = _windowEnd;
    final weekFrom = weekStart(_date);
    final weekTo = weekFrom.add(const Duration(days: 7));
    final totalWidth = 24 * _hourWidth;
    final theme = Theme.of(context);

    final visible = [
      for (final s in shifts)
        if (s.status != ShiftStatus.cancelled &&
            s.startTime.isBefore(windowEnd) &&
            s.endTime.isAfter(windowStart))
          s,
    ];

    return Column(
      children: [
        _DayBar(
          date: _date,
          onPrev: () =>
              setState(() => _date = _date.subtract(const Duration(days: 1))),
          onNext: () =>
              setState(() => _date = _date.add(const Duration(days: 1))),
          onToday: () =>
              setState(() => _date = businessDateFor(DateTime.now())),
          onPick: _pickDate,
          shiftCount: visible.length,
          conflictCount: visible.where((s) => conflicts.contains(s.id)).length,
        ),
        Expanded(
          child: SingleChildScrollView(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: _leftWidth,
                  child: Column(
                    children: [
                      const SizedBox(height: _headerHeight),
                      for (final r in rows)
                        _StaffCell(
                          row: r,
                          height: _rowHeight,
                          dayHours: scheduledHours(
                            shifts,
                            r.staffId ?? '',
                            windowStart,
                            windowEnd,
                          ),
                          weekHours: scheduledHours(
                            shifts,
                            r.staffId ?? '',
                            weekFrom,
                            weekTo,
                          ),
                        ),
                    ],
                  ),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    controller: _hScroll,
                    scrollDirection: Axis.horizontal,
                    child: SizedBox(
                      width: totalWidth,
                      child: Column(
                        children: [
                          _HourHeader(
                            hourWidth: _hourWidth,
                            height: _headerHeight,
                            startHour: _startHour,
                          ),
                          Stack(
                            children: [
                              Column(
                                children: [
                                  for (var i = 0; i < rows.length; i++)
                                    _buildRow(
                                      i,
                                      rows[i],
                                      canEdit,
                                      venueId,
                                      theme,
                                    ),
                                ],
                              ),
                              // Blocks live in one overlay (keyed by shift) so a shift keeps
                              // its gesture while it is dragged from one person's row to another.
                              for (var i = 0; i < rows.length; i++)
                                ..._blocksForRow(
                                  i,
                                  visible,
                                  conflicts,
                                  canEdit,
                                  shifts,
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(8),
          child: Text(
            canEdit
                ? 'Press and hold a shift, then drag to move or reassign it. '
                    'Drag its edges to resize. Tap an empty slot to add one.'
                : 'View only — managers can change the schedule.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildRow(
    int index,
    _Row row,
    bool canEdit,
    String venueId,
    ThemeData theme,
  ) {
    final now = DateTime.now();
    final nowX = now.isAfter(_windowStart) && now.isBefore(_windowEnd)
        ? now.difference(_windowStart).inMinutes / 60 * _hourWidth
        : null;

    return SizedBox(
      height: _rowHeight,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: canEdit
            ? (d) {
                final minutes = d.localPosition.dx / _hourWidth * 60;
                final start = snapTime(
                  _windowStart.add(Duration(minutes: minutes.round())),
                  minutes: 60,
                );
                _create(
                  venueId: venueId,
                  rows: _rows,
                  staffId: row.staffId,
                  start: start,
                );
              }
            : null,
        child: CustomPaint(
          size: Size.infinite,
          painter: _RowPainter(
            hourWidth: _hourWidth,
            line: context.ops.gridLine,
            strong: context.ops.panelBorder,
            stripe: index.isOdd
                ? theme.colorScheme.onSurface.withValues(alpha: 0.03)
                : null,
            nowX: nowX,
            nowColor: theme.colorScheme.primary,
          ),
        ),
      ),
    );
  }

  List<Widget> _blocksForRow(
    int rowIndex,
    List<Shift> visible,
    Set<String> conflicts,
    bool canEdit,
    List<Shift> allShifts,
  ) {
    final row = _rows[rowIndex];
    final rowShifts = [
      for (final s in visible)
        if (s.staffId == row.staffId) s,
    ];
    final lanes = assignLanes(rowShifts);
    return [
      for (final s in rowShifts)
        _buildBlock(
          s,
          rowIndex,
          lanes[s.id]!,
          conflicts.contains(s.id),
          canEdit,
          allShifts,
        ),
    ];
  }

  Widget _buildBlock(
    Shift s,
    int rowIndex,
    ({int lane, int lanes}) lane,
    bool conflict,
    bool canEdit,
    List<Shift> allShifts,
  ) {
    final ops = context.ops;
    final theme = Theme.of(context);
    final dragging = _drag?.shift.id == s.id;

    final startMin = s.startTime.difference(_windowStart).inMinutes;
    final endMin = s.endTime.difference(_windowStart).inMinutes;
    final left = math.max(0, startMin) / 60 * _hourWidth;
    final right = math.min(24 * 60, endMin) / 60 * _hourWidth;
    final width = math.max(28.0, right - left);
    const pad = 4.0;
    final laneH = (_rowHeight - pad * 2) / lane.lanes;
    final top = rowIndex * _rowHeight + pad + lane.lane * laneH;

    final tone = conflict
        ? Tone.danger
        : s.staffId == null
            ? Tone.warning
            : Tone.info;
    final colors = ops.of(tone);
    final handleW = math.min(18.0, width / 3);

    final label = [
      if (s.roleLabel != null && s.roleLabel!.isNotEmpty) s.roleLabel!,
      '${clockLabel(s.startTime)}–${clockLabel(s.endTime)}',
    ].join(' · ');

    return Positioned(
      key: ValueKey(s.id),
      left: left,
      top: top,
      width: width,
      height: laneH - 2,
      child: Material(
        color: colors.bg,
        elevation: dragging ? 6 : 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(
            color: colors.fg.withValues(alpha: dragging ? 1 : 0.6),
            width: conflict || dragging ? 2 : 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => canEdit
                    ? _edit(s, _rows)
                    : _toast(
                        '${s.roleLabel ?? 'Shift'}: '
                        '${clockLabel(s.startTime)}–${clockLabel(s.endTime)}',
                      ),
                onLongPressStart: canEdit
                    ? (_) {
                        HapticFeedback.mediumImpact();
                        setState(
                          () => _drag = _Drag(_DragMode.move, s, rowIndex),
                        );
                      }
                    : null,
                onLongPressMoveUpdate: canEdit
                    ? (d) => setState(() {
                          _drag?.dx = d.offsetFromOrigin.dx;
                          _drag?.dy = d.offsetFromOrigin.dy;
                        })
                    : null,
                onLongPressEnd: canEdit ? (_) => _finishDrag(allShifts) : null,
                onLongPressCancel:
                    canEdit ? () => setState(() => _drag = null) : null,
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: handleW),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Row(
                      children: [
                        if (conflict) ...[
                          Icon(
                            Icons.warning_amber_rounded,
                            size: 14,
                            color: colors.fg,
                          ),
                          const SizedBox(width: 2),
                        ],
                        Expanded(
                          child: Text(
                            label,
                            maxLines: 1,
                            overflow: TextOverflow.clip,
                            softWrap: false,
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: colors.fg,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            if (canEdit) ...[
              _edgeHandle(s, rowIndex, handleW, true, colors.fg, allShifts),
              _edgeHandle(s, rowIndex, handleW, false, colors.fg, allShifts),
            ],
          ],
        ),
      ),
    );
  }

  Widget _edgeHandle(
    Shift s,
    int rowIndex,
    double w,
    bool leading,
    Color color,
    List<Shift> allShifts,
  ) {
    final mode = leading ? _DragMode.resizeStart : _DragMode.resizeEnd;
    return Positioned(
      left: leading ? 0 : null,
      right: leading ? null : 0,
      top: 0,
      bottom: 0,
      width: w,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: (_) =>
            setState(() => _drag = _Drag(mode, s, rowIndex)),
        onHorizontalDragUpdate: (d) => setState(() => _drag?.dx += d.delta.dx),
        onHorizontalDragEnd: (_) => _finishDrag(allShifts),
        onHorizontalDragCancel: () => setState(() => _drag = null),
        child: Center(
          child: Container(
            width: 3,
            height: 18,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.7),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
      ),
    );
  }

  void _finishDrag(List<Shift> effectiveNow) {
    final d = _drag;
    if (d == null) return;
    // Conflict check should compare against the board as it was before this drag.
    final before = [
      for (final s in effectiveNow) s.id == d.shift.id ? d.shift : s,
    ];
    _commit(d, before);
  }
}

class _StaffCell extends StatelessWidget {
  const _StaffCell({
    required this.row,
    required this.height,
    required this.dayHours,
    required this.weekHours,
  });

  final _Row row;
  final double height;
  final double dayHours;
  final double weekHours;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final open = row.staffId == null;
    return Container(
      height: height,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(
          bottom: BorderSide(color: context.ops.panelBorder),
          right: BorderSide(color: context.ops.panelBorder),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Row(
            children: [
              if (open)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: Icon(
                    Icons.person_add_alt,
                    size: 14,
                    color: context.ops.warning.fg,
                  ),
                ),
              Expanded(
                child: Text(
                  row.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall,
                ),
              ),
            ],
          ),
          if (row.role != null)
            Text(
              row.role!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
          if (!open)
            Text(
              'Day ${formatHours(dayHours)} · Wk ${formatHours(weekHours)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
  }
}

class _HourHeader extends StatelessWidget {
  const _HourHeader({
    required this.hourWidth,
    required this.height,
    required this.startHour,
  });

  final double hourWidth;
  final double height;
  final int startHour;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: height,
      child: Row(
        children: [
          for (var i = 0; i < 24; i++)
            Container(
              width: hourWidth,
              alignment: Alignment.centerLeft,
              padding: const EdgeInsets.only(left: 4),
              decoration: BoxDecoration(
                border: Border(
                  left: BorderSide(color: context.ops.panelBorder),
                  bottom: BorderSide(color: context.ops.panelBorder),
                ),
              ),
              child: Text(
                hourLabel(startHour + i),
                style: theme.textTheme.labelSmall,
              ),
            ),
        ],
      ),
    );
  }
}

class _RowPainter extends CustomPainter {
  const _RowPainter({
    required this.hourWidth,
    required this.line,
    required this.strong,
    required this.stripe,
    required this.nowX,
    required this.nowColor,
  });

  final double hourWidth;
  final Color line;
  final Color strong;
  final Color? stripe;
  final double? nowX;
  final Color nowColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (stripe != null) {
      canvas.drawRect(Offset.zero & size, Paint()..color = stripe!);
    }
    final minor = Paint()..color = line;
    final major = Paint()..color = strong;
    for (var h = 0; h <= 24; h++) {
      canvas.drawLine(
        Offset(h * hourWidth, 0),
        Offset(h * hourWidth, size.height),
        h % 3 == 0 ? major : minor,
      );
    }
    canvas.drawLine(
      Offset(0, size.height - 0.5),
      Offset(size.width, size.height - 0.5),
      major,
    );
    if (nowX != null) {
      canvas.drawLine(
        Offset(nowX!, 0),
        Offset(nowX!, size.height),
        Paint()
          ..color = nowColor
          ..strokeWidth = 2,
      );
    }
  }

  @override
  bool shouldRepaint(_RowPainter old) =>
      old.hourWidth != hourWidth ||
      old.line != line ||
      old.strong != strong ||
      old.stripe != stripe ||
      old.nowX != nowX ||
      old.nowColor != nowColor;
}

class _DayBar extends StatelessWidget {
  const _DayBar({
    required this.date,
    required this.onPrev,
    required this.onNext,
    required this.onToday,
    required this.onPick,
    required this.shiftCount,
    required this.conflictCount,
  });

  final DateTime date;
  final VoidCallback onPrev;
  final VoidCallback onNext;
  final VoidCallback onToday;
  final VoidCallback onPick;
  final int shiftCount;
  final int conflictCount;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label =
        '${_weekdays[date.weekday - 1]}, ${_months[date.month - 1]} ${date.day}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.chevron_left),
            tooltip: 'Previous day',
            onPressed: onPrev,
          ),
          TextButton.icon(
            onPressed: onPick,
            icon: const Icon(Icons.calendar_today_outlined, size: 16),
            label: Text(label),
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right),
            tooltip: 'Next day',
            onPressed: onNext,
          ),
          TextButton(onPressed: onToday, child: const Text('Today')),
          const Spacer(),
          if (conflictCount > 0)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.warning_amber_rounded,
                  size: 16,
                  color: context.ops.danger.fg,
                ),
                const SizedBox(width: 4),
                Text(
                  '$conflictCount overlap',
                  style: theme.textTheme.labelMedium
                      ?.copyWith(color: context.ops.danger.fg),
                ),
                const SizedBox(width: 8),
              ],
            ),
          Text('$shiftCount shifts', style: theme.textTheme.labelMedium),
        ],
      ),
    );
  }
}

class _ShiftFormResult {
  const _ShiftFormResult({
    required this.staffId,
    required this.role,
    required this.start,
    required this.end,
    this.delete = false,
  });

  final String? staffId;
  final String role;
  final DateTime start;
  final DateTime end;
  final bool delete;
}

class _ShiftForm extends StatefulWidget {
  const _ShiftForm({
    required this.title,
    required this.confirmLabel,
    required this.rows,
    required this.initial,
    required this.allowDelete,
  });

  final String title;
  final String confirmLabel;
  final List<_Row> rows;
  final ({String? staffId, String role, DateTime start, DateTime end}) initial;
  final bool allowDelete;

  @override
  State<_ShiftForm> createState() => _ShiftFormState();
}

class _ShiftFormState extends State<_ShiftForm> {
  late final _role = TextEditingController(text: widget.initial.role);
  late String? _staffId = widget.initial.staffId;
  late DateTime _start = widget.initial.start;
  late DateTime _end = widget.initial.end;
  String? _error;

  @override
  void dispose() {
    _role.dispose();
    super.dispose();
  }

  Future<DateTime?> _pick(DateTime initial) async {
    final date = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime.now().subtract(const Duration(days: 365)),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (date == null || !mounted) return null;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
    );
    if (time == null) return null;
    return DateTime(date.year, date.month, date.day, time.hour, time.minute);
  }

  String _fmt(DateTime t) =>
      '${_weekdays[t.weekday - 1]} ${_months[t.month - 1]} ${t.day}, ${clockLabel(t)}';

  void _submit() {
    if (!_end.isAfter(_start)) {
      setState(() => _error = 'The end time must be after the start.');
      return;
    }
    Navigator.pop(
      context,
      _ShiftFormResult(
        staffId: _staffId,
        role: _role.text.trim(),
        start: _start,
        end: _end,
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
            DropdownButtonFormField<String?>(
              initialValue: _staffId,
              decoration: const InputDecoration(labelText: 'Assigned to'),
              items: [
                for (final r in widget.rows)
                  DropdownMenuItem(value: r.staffId, child: Text(r.name)),
              ],
              onChanged: (v) => setState(() => _staffId = v),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _role,
              decoration: const InputDecoration(
                labelText: 'Role (e.g. bartender)',
              ),
            ),
            const SizedBox(height: 8),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Start'),
              subtitle: Text(_fmt(_start)),
              trailing: const Icon(Icons.edit_calendar_outlined),
              onTap: () async {
                final p = await _pick(_start);
                if (p != null) {
                  setState(() {
                    final length = _end.difference(_start);
                    _start = p;
                    if (!_end.isAfter(_start)) _end = _start.add(length);
                  });
                }
              },
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('End'),
              subtitle: Text(_fmt(_end)),
              trailing: const Icon(Icons.edit_calendar_outlined),
              onTap: () async {
                final p = await _pick(_end);
                if (p != null) setState(() => _end = p);
              },
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  _error!,
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
            const SizedBox(height: 16),
            FilledButton(onPressed: _submit, child: Text(widget.confirmLabel)),
            if (widget.allowDelete) ...[
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: () => Navigator.pop(
                  context,
                  _ShiftFormResult(
                    staffId: _staffId,
                    role: _role.text.trim(),
                    start: _start,
                    end: _end,
                    delete: true,
                  ),
                ),
                icon: Icon(Icons.delete_outline, color: context.ops.danger.fg),
                label: Text(
                  'Delete shift',
                  style: TextStyle(color: context.ops.danger.fg),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

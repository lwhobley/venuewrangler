/// See the note in features/organizations/domain/organization.dart about why this is a
/// hand-written model rather than `freezed` for now.
enum ShiftStatus {
  scheduled,
  completed,
  cancelled;

  static ShiftStatus fromDb(String value) => switch (value) {
        'scheduled' => ShiftStatus.scheduled,
        'completed' => ShiftStatus.completed,
        'cancelled' => ShiftStatus.cancelled,
        _ => throw ArgumentError('Unknown shift status: $value'),
      };

  String toDb() => name;
}

class Shift {
  const Shift({
    required this.id,
    required this.venueId,
    this.staffId,
    this.roleLabel,
    this.section,
    required this.startTime,
    required this.endTime,
    required this.status,
    this.version = 1,
  });

  final String id;
  final String venueId;
  final String? staffId;
  final String? roleLabel;

  /// Floor section worked on this shift (matches FloorTable.section), set by managers.
  final String? section;

  /// Instants (UTC) exactly as stored in the database. They are not in any timezone until a
  /// `VenueClock` turns them into the venue's wall time for display or editing; never format
  /// them with the device's local time.
  final DateTime startTime;
  final DateTime endTime;
  final ShiftStatus status;

  /// Bumped by the database on every update. An edit filters on the version it was made
  /// against, so a stale board cannot write over a newer change (see [StaleShiftException]).
  final int version;

  Shift copyWith({
    String? staffId,
    bool clearStaff = false,
    String? roleLabel,
    String? section,
    DateTime? startTime,
    DateTime? endTime,
    ShiftStatus? status,
  }) =>
      Shift(
        id: id,
        venueId: venueId,
        staffId: clearStaff ? null : (staffId ?? this.staffId),
        roleLabel: roleLabel ?? this.roleLabel,
        section: section ?? this.section,
        startTime: startTime ?? this.startTime,
        endTime: endTime ?? this.endTime,
        status: status ?? this.status,
        version: version,
      );

  factory Shift.fromJson(Map<String, dynamic> json) => Shift(
        id: json['id'] as String,
        venueId: json['venue_id'] as String,
        staffId: json['staff_id'] as String?,
        roleLabel: json['role_label'] as String?,
        section: json['section'] as String?,
        startTime: DateTime.parse(json['start_time'] as String).toUtc(),
        endTime: DateTime.parse(json['end_time'] as String).toUtc(),
        status: ShiftStatus.fromDb(json['status'] as String),
        version: (json['version'] as num?)?.toInt() ?? 1,
      );

  @override
  bool operator ==(Object other) => other is Shift && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

/// Thrown when a shift edit was made against an older version than the one now stored —
/// someone else changed the shift first. Reload and redo the edit.
class StaleShiftException implements Exception {
  const StaleShiftException();

  @override
  String toString() =>
      'StaleShiftException: the shift changed since it was loaded';
}

/// pending: open for a teammate to take. claimed: a teammate offered to take it and a manager
/// has to approve. accepted: approved and applied — the shift is the taker's.
enum ShiftSwapStatus {
  pending,
  claimed,
  accepted,
  declined,
  cancelled;

  /// Still in flight (not yet applied, declined or withdrawn).
  bool get isOpen =>
      this == ShiftSwapStatus.pending || this == ShiftSwapStatus.claimed;

  static ShiftSwapStatus fromDb(String value) => switch (value) {
        'pending' => ShiftSwapStatus.pending,
        'claimed' => ShiftSwapStatus.claimed,
        'accepted' => ShiftSwapStatus.accepted,
        'declined' => ShiftSwapStatus.declined,
        'cancelled' => ShiftSwapStatus.cancelled,
        _ => throw ArgumentError('Unknown shift swap status: $value'),
      };
}

/// A request from `shift_id`'s current assignee to give it up — to anyone (`offeredTo` is
/// null) or to one named person. See
/// supabase/migrations/20261002184109_shift_swaps_schema.sql and
/// 20261022120002_manager_approved_swaps.sql: a teammate takes it (`claim_shift_swap`), a manager
/// approves it on that teammate's behalf (`approve_shift_swap`), and only then does a database
/// trigger move the shift. This app never writes the reassignment itself.
class ShiftSwap {
  const ShiftSwap({
    required this.id,
    required this.venueId,
    required this.shiftId,
    required this.requestedBy,
    this.offeredTo,
    required this.status,
    this.acceptedBy,
    this.approvedBy,
  });

  final String id;
  final String venueId;
  final String shiftId;
  final String requestedBy;
  final String? offeredTo;
  final ShiftSwapStatus status;

  /// Who is taking (claimed) or took (accepted) the shift — never the approving manager.
  final String? acceptedBy;
  final String? approvedBy;

  /// The person a manager's approval would give the shift to, if anyone yet.
  String? get taker =>
      status == ShiftSwapStatus.claimed ? acceptedBy : offeredTo;

  factory ShiftSwap.fromJson(Map<String, dynamic> json) => ShiftSwap(
        id: json['id'] as String,
        venueId: json['venue_id'] as String,
        shiftId: json['shift_id'] as String,
        requestedBy: json['requested_by'] as String,
        offeredTo: json['offered_to'] as String?,
        status: ShiftSwapStatus.fromDb(json['status'] as String),
        acceptedBy: json['accepted_by'] as String?,
        approvedBy: json['approved_by'] as String?,
      );
}

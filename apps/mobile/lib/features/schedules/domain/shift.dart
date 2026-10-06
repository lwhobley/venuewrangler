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
    required this.startTime,
    required this.endTime,
    required this.status,
  });

  final String id;
  final String venueId;
  final String? staffId;
  final String? roleLabel;
  final DateTime startTime;
  final DateTime endTime;
  final ShiftStatus status;

  Shift copyWith({
    String? staffId,
    bool clearStaff = false,
    String? roleLabel,
    DateTime? startTime,
    DateTime? endTime,
    ShiftStatus? status,
  }) =>
      Shift(
        id: id,
        venueId: venueId,
        staffId: clearStaff ? null : (staffId ?? this.staffId),
        roleLabel: roleLabel ?? this.roleLabel,
        startTime: startTime ?? this.startTime,
        endTime: endTime ?? this.endTime,
        status: status ?? this.status,
      );

  factory Shift.fromJson(Map<String, dynamic> json) => Shift(
        id: json['id'] as String,
        venueId: json['venue_id'] as String,
        staffId: json['staff_id'] as String?,
        roleLabel: json['role_label'] as String?,
        startTime: DateTime.parse(json['start_time'] as String).toLocal(),
        endTime: DateTime.parse(json['end_time'] as String).toLocal(),
        status: ShiftStatus.fromDb(json['status'] as String),
      );

  @override
  bool operator ==(Object other) => other is Shift && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

enum ShiftSwapStatus {
  pending,
  accepted,
  declined,
  cancelled;

  static ShiftSwapStatus fromDb(String value) => switch (value) {
        'pending' => ShiftSwapStatus.pending,
        'accepted' => ShiftSwapStatus.accepted,
        'declined' => ShiftSwapStatus.declined,
        'cancelled' => ShiftSwapStatus.cancelled,
        _ => throw ArgumentError('Unknown shift swap status: $value'),
      };
}

/// A request from `shift_id`'s current assignee to give it up — to anyone (`offeredTo` is
/// null) or to one named person. See
/// supabase/migrations/20261002160000_shift_swaps_schema.sql for who may create/accept/cancel
/// one; this app never applies the reassignment itself, the database trigger does it the
/// moment a swap's status becomes accepted.
class ShiftSwap {
  const ShiftSwap({
    required this.id,
    required this.venueId,
    required this.shiftId,
    required this.requestedBy,
    this.offeredTo,
    required this.status,
    this.acceptedBy,
  });

  final String id;
  final String venueId;
  final String shiftId;
  final String requestedBy;
  final String? offeredTo;
  final ShiftSwapStatus status;
  final String? acceptedBy;

  factory ShiftSwap.fromJson(Map<String, dynamic> json) => ShiftSwap(
        id: json['id'] as String,
        venueId: json['venue_id'] as String,
        shiftId: json['shift_id'] as String,
        requestedBy: json['requested_by'] as String,
        offeredTo: json['offered_to'] as String?,
        status: ShiftSwapStatus.fromDb(json['status'] as String),
        acceptedBy: json['accepted_by'] as String?,
      );
}

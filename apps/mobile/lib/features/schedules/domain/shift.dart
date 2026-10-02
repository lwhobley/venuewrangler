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

  factory Shift.fromJson(Map<String, dynamic> json) => Shift(
        id: json['id'] as String,
        venueId: json['venue_id'] as String,
        staffId: json['staff_id'] as String?,
        roleLabel: json['role_label'] as String?,
        startTime: DateTime.parse(json['start_time'] as String),
        endTime: DateTime.parse(json['end_time'] as String),
        status: ShiftStatus.fromDb(json['status'] as String),
      );

  @override
  bool operator ==(Object other) => other is Shift && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

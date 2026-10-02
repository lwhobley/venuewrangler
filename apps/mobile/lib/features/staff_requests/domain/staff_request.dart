/// Staff request domain model for VenueWrangler.
///
/// See features/organizations/domain/organization.dart regarding hand-written models
/// vs. freezed.
library;

enum StaffRequestKind {
  addShift,
  dropShift,
  timeOff,
  shiftSwap,
  openShift,
  sickLeave,
  timeCorrection,
  other;

  static StaffRequestKind fromDb(String value) => switch (value) {
        'add_shift' => StaffRequestKind.addShift,
        'drop_shift' => StaffRequestKind.dropShift,
        'time_off' => StaffRequestKind.timeOff,
        'shift_swap' => StaffRequestKind.shiftSwap,
        'open_shift' => StaffRequestKind.openShift,
        'sick_leave' => StaffRequestKind.sickLeave,
        'time_correction' => StaffRequestKind.timeCorrection,
        'other' => StaffRequestKind.other,
        _ => throw ArgumentError('Unknown staff request kind: $value'),
      };

  String toDb() => switch (this) {
        StaffRequestKind.addShift => 'add_shift',
        StaffRequestKind.dropShift => 'drop_shift',
        StaffRequestKind.timeOff => 'time_off',
        StaffRequestKind.shiftSwap => 'shift_swap',
        StaffRequestKind.openShift => 'open_shift',
        StaffRequestKind.sickLeave => 'sick_leave',
        StaffRequestKind.timeCorrection => 'time_correction',
        StaffRequestKind.other => 'other',
      };

  String get displayLabel => switch (this) {
        StaffRequestKind.addShift => 'Add Shift',
        StaffRequestKind.dropShift => 'Drop Shift',
        StaffRequestKind.timeOff => 'Time Off',
        StaffRequestKind.shiftSwap => 'Shift Swap',
        StaffRequestKind.openShift => 'Open Shift',
        StaffRequestKind.sickLeave => 'Sick Leave',
        StaffRequestKind.timeCorrection => 'Time Correction',
        StaffRequestKind.other => 'Other',
      };
}

enum StaffRequestStatus {
  pending,
  approved,
  denied,
  cancelled;

  static StaffRequestStatus fromDb(String value) => switch (value) {
        'pending' => StaffRequestStatus.pending,
        'approved' => StaffRequestStatus.approved,
        'denied' => StaffRequestStatus.denied,
        'cancelled' => StaffRequestStatus.cancelled,
        _ => throw ArgumentError('Unknown staff request status: $value'),
      };

  String toDb() => switch (this) {
        StaffRequestStatus.pending => 'pending',
        StaffRequestStatus.approved => 'approved',
        StaffRequestStatus.denied => 'denied',
        StaffRequestStatus.cancelled => 'cancelled',
      };

  String get displayLabel => switch (this) {
        StaffRequestStatus.pending => 'Pending',
        StaffRequestStatus.approved => 'Approved',
        StaffRequestStatus.denied => 'Denied',
        StaffRequestStatus.cancelled => 'Cancelled',
      };
}

class StaffRequest {
  const StaffRequest({
    required this.id,
    required this.venueId,
    required this.organizationId,
    required this.userId,
    required this.kind,
    required this.status,
    required this.title,
    this.details = '',
    this.requestedForDate,
    this.requestedRangeStart,
    this.requestedRangeEnd,
    this.requestedShiftId,
    this.reviewerId,
    this.reviewedAt,
    this.responseNotes,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String venueId;
  final String organizationId;
  final String userId;
  final StaffRequestKind kind;
  final StaffRequestStatus status;
  final String title;
  final String details;
  final String? requestedForDate;
  final String? requestedRangeStart;
  final String? requestedRangeEnd;
  final String? requestedShiftId;
  final String? reviewerId;
  final DateTime? reviewedAt;
  final String? responseNotes;
  final DateTime createdAt;
  final DateTime updatedAt;

  bool get isPending => status == StaffRequestStatus.pending;

  factory StaffRequest.fromJson(Map<String, dynamic> json) => StaffRequest(
        id: json['id'] as String,
        venueId: json['venue_id'] as String,
        organizationId: json['organization_id'] as String,
        userId: json['user_id'] as String,
        kind: StaffRequestKind.fromDb(json['kind'] as String),
        status: StaffRequestStatus.fromDb(json['status'] as String),
        title: json['title'] as String,
        details: (json['details'] as String?) ?? '',
        requestedForDate: json['requested_for_date'] as String?,
        requestedRangeStart: json['requested_range_start'] as String?,
        requestedRangeEnd: json['requested_range_end'] as String?,
        requestedShiftId: json['requested_shift_id'] as String?,
        reviewerId: json['reviewer_id'] as String?,
        reviewedAt: json['reviewed_at'] == null
            ? null
            : DateTime.parse(json['reviewed_at'] as String),
        responseNotes: json['response_notes'] as String?,
        createdAt: DateTime.parse(json['created_at'] as String),
        updatedAt: DateTime.parse(json['updated_at'] as String),
      );
}

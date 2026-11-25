/// BrightHR integration models. Hand-written like `payroll_connection.dart`.
///
/// The client only ever sees the non-secret columns of `brighthr_connections`; the encrypted
/// client secret is excluded by a column-level grant
/// (supabase/migrations/20261125100000_brighthr_integration.sql).
class BrightHrConnection {
  const BrightHrConnection({
    required this.id,
    required this.venueId,
    required this.status,
    required this.clientId,
    this.lastSyncAt,
    this.lastSyncStatus,
    this.lastError,
  });

  final String id;
  final String venueId;

  /// `connected` or `error` (BrightHR rejected the stored credentials).
  final String status;
  final String clientId;
  final DateTime? lastSyncAt;

  /// `succeeded`, `partial` or `failed`; null before the first sync finishes.
  final String? lastSyncStatus;
  final String? lastError;

  bool get hasCredentialError => status == 'error';

  /// Client IDs are not secret, but there's no reason to show the whole value either.
  String get maskedClientId => clientId.length <= 4
      ? clientId
      : '••••${clientId.substring(clientId.length - 4)}';

  factory BrightHrConnection.fromJson(Map<String, dynamic> json) =>
      BrightHrConnection(
        id: json['id'] as String,
        venueId: json['venue_id'] as String,
        status: json['status'] as String,
        clientId: json['client_id'] as String,
        lastSyncAt: _parseDate(json['last_sync_at']),
        lastSyncStatus: json['last_sync_status'] as String?,
        lastError: json['last_error'] as String?,
      );
}

class BrightHrEmployee {
  const BrightHrEmployee({
    required this.externalEmployeeId,
    this.givenName,
    this.familyName,
    this.email,
    this.jobTitle,
    this.employmentEnd,
    this.linkedStaffId,
    this.externalReferenceSynced = false,
  });

  final String externalEmployeeId;
  final String? givenName;
  final String? familyName;
  final String? email;
  final String? jobTitle;
  final DateTime? employmentEnd;

  /// The team member this BrightHR employee is linked to, if any.
  final String? linkedStaffId;

  /// Whether the link has been written back to BrightHR as the external reference.
  final bool externalReferenceSynced;

  String get displayName {
    final name = [givenName, familyName]
        .whereType<String>()
        .where((part) => part.isNotEmpty)
        .join(' ');
    return name.isNotEmpty ? name : (email ?? externalEmployeeId);
  }

  bool get hasLeft =>
      employmentEnd != null && employmentEnd!.isBefore(DateTime.now());

  factory BrightHrEmployee.fromJson(
    Map<String, dynamic> json, {
    Map<String, dynamic>? mapping,
  }) =>
      BrightHrEmployee(
        externalEmployeeId: json['external_employee_id'] as String,
        givenName: json['given_name'] as String?,
        familyName: json['family_name'] as String?,
        email: json['email'] as String?,
        jobTitle: json['job_title'] as String?,
        employmentEnd: _parseDate(json['employment_end']),
        linkedStaffId: mapping?['staff_id'] as String?,
        externalReferenceSynced:
            mapping?['external_reference_synced_at'] != null,
      );
}

enum BrightHrAbsenceType {
  holiday('Holiday'),
  sickness('Sickness'),
  toil('TOIL'),
  other('Other');

  const BrightHrAbsenceType(this.label);

  final String label;

  static BrightHrAbsenceType fromDb(String value) => switch (value) {
        'Holiday' => BrightHrAbsenceType.holiday,
        'Sickness' => BrightHrAbsenceType.sickness,
        'Toil' => BrightHrAbsenceType.toil,
        _ => BrightHrAbsenceType.other,
      };
}

class BrightHrAbsence {
  const BrightHrAbsence({
    required this.externalAbsenceId,
    required this.externalEmployeeId,
    required this.type,
    required this.startDate,
    required this.startPart,
    required this.endDate,
    required this.endPart,
    this.displayName,
  });

  final String externalAbsenceId;
  final String externalEmployeeId;
  final BrightHrAbsenceType type;
  final String? displayName;

  /// Inclusive, local to the employee.
  final DateTime startDate;
  final String startPart;
  final DateTime endDate;
  final String endPart;

  String get label => displayName ?? type.label;

  /// True when the absence covers [day] (date only, inclusive).
  bool covers(DateTime day) {
    final d = DateTime(day.year, day.month, day.day);
    return !d.isBefore(startDate) && !d.isAfter(endDate);
  }

  factory BrightHrAbsence.fromJson(Map<String, dynamic> json) =>
      BrightHrAbsence(
        externalAbsenceId: json['external_absence_id'] as String,
        externalEmployeeId: json['external_employee_id'] as String,
        type: BrightHrAbsenceType.fromDb(json['absence_type'] as String),
        displayName: json['display_name'] as String?,
        startDate: _parseDateOnly(json['start_date'] as String),
        startPart: json['start_part'] as String? ?? 'FullDay',
        endDate: _parseDateOnly(json['end_date'] as String),
        endPart: json['end_part'] as String? ?? 'FullDay',
      );
}

class BrightHrClocking {
  const BrightHrClocking({
    required this.externalClockingId,
    required this.externalEmployeeId,
    required this.clockInAt,
    this.clockOutAt,
    this.breakCount = 0,
  });

  final String externalClockingId;
  final String externalEmployeeId;
  final DateTime clockInAt;
  final DateTime? clockOutAt;
  final int breakCount;

  Duration? get duration => clockOutAt?.difference(clockInAt);

  factory BrightHrClocking.fromJson(Map<String, dynamic> json) =>
      BrightHrClocking(
        externalClockingId: json['external_clocking_id'] as String,
        externalEmployeeId: json['external_employee_id'] as String,
        clockInAt: DateTime.parse(json['clock_in_at'] as String).toLocal(),
        clockOutAt: _parseDate(json['clock_out_at'])?.toLocal(),
        breakCount: (json['break_periods'] as List?)?.length ?? 0,
      );
}

DateTime? _parseDate(Object? value) =>
    value is String ? DateTime.tryParse(value) : null;

/// `YYYY-MM-DD` as a local calendar date (no time zone shift).
DateTime _parseDateOnly(String value) {
  final parts = value.split('-').map(int.parse).toList();
  return DateTime(parts[0], parts[1], parts[2]);
}

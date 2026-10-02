/// Shift insight domain model for VenueWrangler.
///
/// Represents Groq-powered AI insights (and operator notes) about shifts,
/// replacing legacy CosmicInsight with actionable, venue- and shift-scoped intelligence.
library;

enum ShiftInsightKind {
  shiftSummary,
  coverageWarning,
  laborEfficiency,
  rushPrep,
  fatigueRisk,
  stationBalance,
  complianceNote;

  static ShiftInsightKind fromDb(String value) => switch (value) {
        'shift_summary' => ShiftInsightKind.shiftSummary,
        'coverage_warning' => ShiftInsightKind.coverageWarning,
        'labor_efficiency' => ShiftInsightKind.laborEfficiency,
        'rush_prep' => ShiftInsightKind.rushPrep,
        'fatigue_risk' => ShiftInsightKind.fatigueRisk,
        'station_balance' => ShiftInsightKind.stationBalance,
        'compliance_note' => ShiftInsightKind.complianceNote,
        _ => ShiftInsightKind.shiftSummary,
      };

  String toDb() => switch (this) {
        ShiftInsightKind.shiftSummary => 'shift_summary',
        ShiftInsightKind.coverageWarning => 'coverage_warning',
        ShiftInsightKind.laborEfficiency => 'labor_efficiency',
        ShiftInsightKind.rushPrep => 'rush_prep',
        ShiftInsightKind.fatigueRisk => 'fatigue_risk',
        ShiftInsightKind.stationBalance => 'station_balance',
        ShiftInsightKind.complianceNote => 'compliance_note',
      };

  String get displayLabel => switch (this) {
        ShiftInsightKind.shiftSummary => 'Shift Summary',
        ShiftInsightKind.coverageWarning => 'Coverage Warning',
        ShiftInsightKind.laborEfficiency => 'Labor Efficiency',
        ShiftInsightKind.rushPrep => 'Rush Prep',
        ShiftInsightKind.fatigueRisk => 'Fatigue Risk',
        ShiftInsightKind.stationBalance => 'Station Balance',
        ShiftInsightKind.complianceNote => 'Compliance Note',
      };
}

class ShiftInsight {
  const ShiftInsight({
    required this.id,
    required this.organizationId,
    required this.venueId,
    this.shiftId,
    required this.kind,
    required this.title,
    required this.body,
    this.createdBy,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String organizationId;
  final String venueId;
  final String? shiftId;
  final ShiftInsightKind kind;
  final String title;
  final String body;
  final String? createdBy;
  final DateTime createdAt;
  final DateTime updatedAt;

  factory ShiftInsight.fromJson(Map<String, dynamic> json) => ShiftInsight(
        id: json['id'] as String,
        organizationId: json['organization_id'] as String,
        venueId: json['venue_id'] as String,
        shiftId: json['shift_id'] as String?,
        kind: ShiftInsightKind.fromDb(json['kind'] as String? ?? 'shift_summary'),
        title: json['title'] as String,
        body: json['body'] as String,
        createdBy: json['created_by'] as String?,
        createdAt: DateTime.parse(json['created_at'] as String),
        updatedAt: DateTime.parse(json['updated_at'] as String),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'organization_id': organizationId,
        'venue_id': venueId,
        if (shiftId != null) 'shift_id': shiftId,
        'kind': kind.toDb(),
        'title': title,
        'body': body,
        if (createdBy != null) 'created_by': createdBy,
        'created_at': createdAt.toIso8601String(),
        'updated_at': updatedAt.toIso8601String(),
      };

  ShiftInsight copyWith({
    String? id,
    String? organizationId,
    String? venueId,
    String? shiftId,
    ShiftInsightKind? kind,
    String? title,
    String? body,
    String? createdBy,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) =>
      ShiftInsight(
        id: id ?? this.id,
        organizationId: organizationId ?? this.organizationId,
        venueId: venueId ?? this.venueId,
        shiftId: shiftId ?? this.shiftId,
        kind: kind ?? this.kind,
        title: title ?? this.title,
        body: body ?? this.body,
        createdBy: createdBy ?? this.createdBy,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );
}

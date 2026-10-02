/// See the note in features/organizations/domain/organization.dart about why this is a
/// hand-written model rather than `freezed` for now.
enum IncidentSeverity {
  low,
  medium,
  high,
  critical;

  static IncidentSeverity fromDb(String value) => switch (value) {
        'low' => IncidentSeverity.low,
        'medium' => IncidentSeverity.medium,
        'high' => IncidentSeverity.high,
        'critical' => IncidentSeverity.critical,
        _ => throw ArgumentError('Unknown incident severity: $value'),
      };

  String toDb() => name;
}

enum IncidentStatus {
  open,
  investigating,
  resolved,
  closed;

  static IncidentStatus fromDb(String value) => switch (value) {
        'open' => IncidentStatus.open,
        'investigating' => IncidentStatus.investigating,
        'resolved' => IncidentStatus.resolved,
        'closed' => IncidentStatus.closed,
        _ => throw ArgumentError('Unknown incident status: $value'),
      };

  String toDb() => name;
}

class Incident {
  const Incident({
    required this.id,
    required this.venueId,
    required this.organizationId,
    required this.title,
    required this.severity,
    required this.status,
    this.description,
    this.reportedBy,
    this.resolvedAt,
    required this.createdAt,
  });

  final String id;
  final String venueId;
  final String organizationId;
  final String title;
  final String? description;
  final IncidentSeverity severity;
  final IncidentStatus status;
  final String? reportedBy;
  final DateTime? resolvedAt;
  final DateTime createdAt;

  bool get isOpen => status == IncidentStatus.open;

  factory Incident.fromJson(Map<String, dynamic> json) => Incident(
        id: json['id'] as String,
        venueId: json['venue_id'] as String,
        organizationId: json['organization_id'] as String,
        title: json['title'] as String,
        description: json['description'] as String?,
        severity: IncidentSeverity.fromDb(json['severity'] as String),
        status: IncidentStatus.fromDb(json['status'] as String),
        reportedBy: json['reported_by'] as String?,
        resolvedAt:
            json['resolved_at'] == null ? null : DateTime.parse(json['resolved_at'] as String),
        createdAt: DateTime.parse(json['created_at'] as String),
      );

  @override
  bool operator ==(Object other) => other is Incident && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

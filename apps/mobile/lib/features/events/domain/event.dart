/// See the note in features/organizations/domain/organization.dart about why this is a
/// hand-written model rather than `freezed` for now.
enum EventStatus {
  planned,
  confirmed,
  completed,
  cancelled;

  static EventStatus fromDb(String value) => switch (value) {
        'planned' => EventStatus.planned,
        'confirmed' => EventStatus.confirmed,
        'completed' => EventStatus.completed,
        'cancelled' => EventStatus.cancelled,
        _ => throw ArgumentError('Unknown event status: $value'),
      };

  String toDb() => name;
}

class VenueEvent {
  const VenueEvent({
    required this.id,
    required this.venueId,
    required this.name,
    required this.startTime,
    required this.endTime,
    required this.status,
    this.notes,
  });

  final String id;
  final String venueId;
  final String name;
  final DateTime startTime;
  final DateTime endTime;
  final EventStatus status;
  final String? notes;

  factory VenueEvent.fromJson(Map<String, dynamic> json) => VenueEvent(
        id: json['id'] as String,
        venueId: json['venue_id'] as String,
        name: json['name'] as String,
        startTime: DateTime.parse(json['start_time'] as String),
        endTime: DateTime.parse(json['end_time'] as String),
        status: EventStatus.fromDb(json['status'] as String),
        notes: json['notes'] as String?,
      );

  @override
  bool operator ==(Object other) => other is VenueEvent && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

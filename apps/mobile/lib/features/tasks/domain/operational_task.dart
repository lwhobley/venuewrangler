/// See the note in features/organizations/domain/organization.dart about why this is a
/// hand-written model rather than `freezed` for now.
enum TaskStatus {
  open,
  inProgress,
  completed,
  cancelled;

  static TaskStatus fromDb(String value) => switch (value) {
        'open' => TaskStatus.open,
        'in_progress' => TaskStatus.inProgress,
        'completed' => TaskStatus.completed,
        'cancelled' => TaskStatus.cancelled,
        _ => throw ArgumentError('Unknown task status: $value'),
      };

  String toDb() => switch (this) {
        TaskStatus.open => 'open',
        TaskStatus.inProgress => 'in_progress',
        TaskStatus.completed => 'completed',
        TaskStatus.cancelled => 'cancelled',
      };
}

class OperationalTask {
  const OperationalTask({
    required this.id,
    required this.venueId,
    required this.organizationId,
    required this.title,
    required this.status,
    this.description,
    this.assignedTo,
    this.dueAt,
    this.completedAt,
    required this.createdAt,
  });

  final String id;
  final String venueId;
  final String organizationId;
  final String title;
  final String? description;
  final TaskStatus status;
  final String? assignedTo;
  final DateTime? dueAt;
  final DateTime? completedAt;
  final DateTime createdAt;

  bool get isCompleted => status == TaskStatus.completed;

  factory OperationalTask.fromJson(Map<String, dynamic> json) => OperationalTask(
        id: json['id'] as String,
        venueId: json['venue_id'] as String,
        organizationId: json['organization_id'] as String,
        title: json['title'] as String,
        description: json['description'] as String?,
        status: TaskStatus.fromDb(json['status'] as String),
        assignedTo: json['assigned_to'] as String?,
        dueAt: json['due_at'] == null ? null : DateTime.parse(json['due_at'] as String),
        completedAt: json['completed_at'] == null
            ? null
            : DateTime.parse(json['completed_at'] as String),
        createdAt: DateTime.parse(json['created_at'] as String),
      );

  @override
  bool operator ==(Object other) => other is OperationalTask && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

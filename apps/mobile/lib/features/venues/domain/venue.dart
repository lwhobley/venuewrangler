/// See the note in features/organizations/domain/organization.dart about why this is a
/// hand-written model rather than `freezed` for now.
class Venue {
  const Venue({
    required this.id,
    required this.organizationId,
    required this.name,
    required this.createdAt,
  });

  final String id;
  final String organizationId;
  final String name;
  final DateTime createdAt;

  factory Venue.fromJson(Map<String, dynamic> json) => Venue(
        id: json['id'] as String,
        organizationId: json['organization_id'] as String,
        name: json['name'] as String,
        createdAt: DateTime.parse(json['created_at'] as String),
      );

  @override
  bool operator ==(Object other) => other is Venue && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

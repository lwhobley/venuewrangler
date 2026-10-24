/// See the note in features/organizations/domain/organization.dart about why this is a
/// hand-written model rather than `freezed` for now.
class Venue {
  const Venue({
    required this.id,
    required this.organizationId,
    required this.name,
    this.timezone = 'UTC',
    this.latitude,
    this.longitude,
    this.geofenceRadiusM = 100,
    this.address,
    required this.createdAt,
  });

  final String id;
  final String organizationId;
  final String name;
  final String timezone;

  /// Where the venue is; the time clock refuses clock-ins until it is set (see
  /// supabase/migrations/20261022100000_venue_location_and_hours.sql).
  final double? latitude;
  final double? longitude;
  final int geofenceRadiusM;

  /// The street address managers entered with the location, for people (not geocoded).
  final String? address;
  final DateTime createdAt;

  /// Same rule as `app_hidden.venue_has_location`: (0, 0) was the old "never set" value.
  bool get hasLocation =>
      latitude != null &&
      longitude != null &&
      !(latitude == 0 && longitude == 0);

  factory Venue.fromJson(Map<String, dynamic> json) => Venue(
        id: json['id'] as String,
        organizationId: json['organization_id'] as String,
        name: json['name'] as String,
        timezone: (json['timezone'] as String?)?.isNotEmpty == true
            ? json['timezone'] as String
            : 'UTC',
        latitude: (json['latitude'] as num?)?.toDouble(),
        longitude: (json['longitude'] as num?)?.toDouble(),
        geofenceRadiusM: (json['geofence_radius_m'] as num?)?.toInt() ?? 100,
        address: json['address'] as String?,
        createdAt: DateTime.parse(json['created_at'] as String),
      );

  @override
  bool operator ==(Object other) => other is Venue && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

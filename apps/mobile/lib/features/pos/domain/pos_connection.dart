class PosConnection {
  const PosConnection({
    required this.id,
    required this.organizationId,
    required this.venueId,
    required this.provider,
    this.externalLocationId,
    required this.status,
    this.lastSyncAt,
    required this.createdAt,
    required this.updatedAt,
  });

  factory PosConnection.fromJson(Map<String, dynamic> json) {
    return PosConnection(
      id: json['id'] as String,
      organizationId: json['organization_id'] as String,
      venueId: json['venue_id'] as String,
      provider: json['provider'] as String,
      externalLocationId: json['external_location_id'] as String?,
      status: json['status'] as String? ?? 'active',
      lastSyncAt: json['last_sync_at'] != null ? DateTime.parse(json['last_sync_at'] as String) : null,
      createdAt: DateTime.parse(json['created_at'] as String),
      updatedAt: DateTime.parse(json['updated_at'] as String),
    );
  }

  final String id;
  final String organizationId;
  final String venueId;
  final String provider;
  final String? externalLocationId;
  final String status;
  final DateTime? lastSyncAt;
  final DateTime createdAt;
  final DateTime updatedAt;

  bool get isActive => status == 'active';
}

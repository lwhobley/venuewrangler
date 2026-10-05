class FloorPlan {
  const FloorPlan({
    required this.id,
    required this.organizationId,
    required this.venueId,
    required this.name,
    this.width = 1000.0,
    this.height = 800.0,
    this.backgroundImageUrl,
    this.isActive = true,
    required this.createdAt,
    required this.updatedAt,
  });

  factory FloorPlan.fromJson(Map<String, dynamic> json) {
    return FloorPlan(
      id: json['id'] as String,
      organizationId: json['organization_id'] as String,
      venueId: json['venue_id'] as String,
      name: json['name'] as String,
      width: (json['width'] as num?)?.toDouble() ?? 1000.0,
      height: (json['height'] as num?)?.toDouble() ?? 800.0,
      backgroundImageUrl: json['background_image_url'] as String?,
      isActive: json['is_active'] as bool? ?? true,
      createdAt: DateTime.parse(json['created_at'] as String),
      updatedAt: DateTime.parse(json['updated_at'] as String),
    );
  }

  final String id;
  final String organizationId;
  final String venueId;
  final String name;
  final double width;
  final double height;
  final String? backgroundImageUrl;
  final bool isActive;
  final DateTime createdAt;
  final DateTime updatedAt;

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'organization_id': organizationId,
      'venue_id': venueId,
      'name': name,
      'width': width,
      'height': height,
      if (backgroundImageUrl != null)
        'background_image_url': backgroundImageUrl,
      'is_active': isActive,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
    };
  }
}

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
    this.labels = const [],
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
      labels: [
        for (final item in (json['labels'] as List?) ?? const [])
          if (FloorPlanLabel.tryFromJson(item) case final label?) label,
      ],
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

  /// Non-seatable areas (stage, bars, DJ booth, ...) drawn behind the tables.
  final List<FloorPlanLabel> labels;
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
      'labels': [for (final label in labels) label.toJson()],
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
    };
  }
}

/// A named, non-seatable area on a floor plan. [x]/[y] is the top-left corner, in the same
/// plan coordinates as floor tables.
class FloorPlanLabel {
  const FloorPlanLabel({
    required this.text,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  final String text;
  final double x;
  final double y;
  final double width;
  final double height;

  /// Returns null for a malformed element so one bad label never stops the plan loading.
  static FloorPlanLabel? tryFromJson(Object? json) {
    if (json is! Map) return null;
    double? number(Object? value) =>
        value is num && value.isFinite ? value.toDouble() : null;
    final text = json['text'];
    final x = number(json['x']);
    final y = number(json['y']);
    final width = number(json['width']);
    final height = number(json['height']);
    if (text is! String ||
        text.trim().isEmpty ||
        x == null ||
        y == null ||
        width == null ||
        width <= 0 ||
        height == null ||
        height <= 0) {
      return null;
    }
    return FloorPlanLabel(
      text: text.trim(),
      x: x,
      y: y,
      width: width,
      height: height,
    );
  }

  Map<String, dynamic> toJson() =>
      {'text': text, 'x': x, 'y': y, 'width': width, 'height': height};
}

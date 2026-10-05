class FloorTable {
  const FloorTable({
    required this.id,
    required this.organizationId,
    required this.venueId,
    required this.floorPlanId,
    required this.label,
    this.shape = 'rect',
    this.capacity = 4,
    this.x = 0.0,
    this.y = 0.0,
    this.width = 80.0,
    this.height = 80.0,
    this.rotation = 0.0,
    this.section = 'main',
    this.minSpendCents = 0,
    this.isReservable = true,
    this.status = 'available',
    this.partySize,
    this.seatedAt,
    required this.lastActivityAt,
    this.mergeGroupId,
    this.notes,
    required this.createdAt,
    required this.updatedAt,
  });

  factory FloorTable.fromJson(Map<String, dynamic> json) {
    return FloorTable(
      id: json['id'] as String,
      organizationId: json['organization_id'] as String,
      venueId: json['venue_id'] as String,
      floorPlanId: json['floor_plan_id'] as String,
      label: json['label'] as String,
      shape: json['shape'] as String? ?? 'rect',
      capacity: (json['capacity'] as num?)?.toInt() ?? 4,
      x: (json['x'] as num?)?.toDouble() ?? 0.0,
      y: (json['y'] as num?)?.toDouble() ?? 0.0,
      width: (json['width'] as num?)?.toDouble() ?? 80.0,
      height: (json['height'] as num?)?.toDouble() ?? 80.0,
      rotation: (json['rotation'] as num?)?.toDouble() ?? 0.0,
      section: json['section'] as String? ?? 'main',
      minSpendCents: (json['min_spend_cents'] as num?)?.toInt() ?? 0,
      isReservable: json['is_reservable'] as bool? ?? true,
      status: json['status'] as String? ?? 'available',
      partySize: (json['party_size'] as num?)?.toInt(),
      seatedAt: json['seated_at'] != null
          ? DateTime.parse(json['seated_at'] as String)
          : null,
      lastActivityAt: DateTime.parse(json['last_activity_at'] as String),
      mergeGroupId: json['merge_group_id'] as String?,
      notes: json['notes'] as String?,
      createdAt: DateTime.parse(json['created_at'] as String),
      updatedAt: DateTime.parse(json['updated_at'] as String),
    );
  }

  final String id;
  final String organizationId;
  final String venueId;
  final String floorPlanId;
  final String label;
  final String shape;
  final int capacity;
  final double x;
  final double y;
  final double width;
  final double height;
  final double rotation;
  final String section;
  final int minSpendCents;
  final bool isReservable;
  final String status;
  final int? partySize;
  final DateTime? seatedAt;
  final DateTime lastActivityAt;
  final String? mergeGroupId;
  final String? notes;
  final DateTime createdAt;
  final DateTime updatedAt;

  bool get isAvailable => status == 'available';
  bool get isSeated => status == 'seated';
  bool get isDirty => status == 'dirty';
  bool get isMerged => mergeGroupId != null;

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'organization_id': organizationId,
      'venue_id': venueId,
      'floor_plan_id': floorPlanId,
      'label': label,
      'shape': shape,
      'capacity': capacity,
      'x': x,
      'y': y,
      'width': width,
      'height': height,
      'rotation': rotation,
      'section': section,
      'min_spend_cents': minSpendCents,
      'is_reservable': isReservable,
      'status': status,
      if (partySize != null) 'party_size': partySize,
      if (seatedAt != null) 'seated_at': seatedAt!.toIso8601String(),
      'last_activity_at': lastActivityAt.toIso8601String(),
      if (mergeGroupId != null) 'merge_group_id': mergeGroupId,
      if (notes != null) 'notes': notes,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
    };
  }
}

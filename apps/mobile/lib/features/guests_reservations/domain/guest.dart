class Guest {
  const Guest({
    required this.id,
    required this.organizationId,
    required this.venueId,
    required this.fullName,
    this.phone,
    this.email,
    this.notes,
    this.dietaryNotes,
    this.tags = const [],
    this.guestTier = 'standard',
    this.lifecycleStage = 'lead',
    required this.createdAt,
    required this.updatedAt,
  });

  factory Guest.fromJson(Map<String, dynamic> json) {
    return Guest(
      id: json['id'] as String,
      organizationId: json['organization_id'] as String,
      venueId: json['venue_id'] as String,
      fullName: json['full_name'] as String,
      phone: json['phone'] as String?,
      email: json['email'] as String?,
      notes: json['notes'] as String?,
      dietaryNotes: json['dietary_notes'] as String?,
      tags: (json['tags'] as List<dynamic>?)?.map((e) => e.toString()).toList() ?? const [],
      guestTier: json['guest_tier'] as String? ?? 'standard',
      lifecycleStage: json['lifecycle_stage'] as String? ?? 'lead',
      createdAt: DateTime.parse(json['created_at'] as String),
      updatedAt: DateTime.parse(json['updated_at'] as String),
    );
  }

  final String id;
  final String organizationId;
  final String venueId;
  final String fullName;
  final String? phone;
  final String? email;
  final String? notes;
  final String? dietaryNotes;
  final List<String> tags;
  final String guestTier;
  final String lifecycleStage;
  final DateTime createdAt;
  final DateTime updatedAt;

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'organization_id': organizationId,
      'venue_id': venueId,
      'full_name': fullName,
      if (phone != null) 'phone': phone,
      if (email != null) 'email': email,
      if (notes != null) 'notes': notes,
      if (dietaryNotes != null) 'dietary_notes': dietaryNotes,
      'tags': tags,
      'guest_tier': guestTier,
      'lifecycle_stage': lifecycleStage,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
    };
  }
}

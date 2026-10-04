class CrmBeo {
  const CrmBeo({
    required this.id,
    required this.venueId,
    this.leadId,
    required this.eventName,
    this.eventDate,
    this.eventType,
    this.guestCount,
    this.venueSpace,
    this.fbMinimumCents,
    this.menuAppetizers,
    this.menuEntrees,
    this.menuDesserts,
    this.menuBarPackage,
    this.specialRequirements,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
  });

  factory CrmBeo.fromJson(Map<String, dynamic> json) => CrmBeo(
        id: json['id'] as String,
        venueId: json['venue_id'] as String,
        leadId: json['lead_id'] as String?,
        eventName: json['event_name'] as String,
        eventDate: json['event_date'] != null ? DateTime.parse(json['event_date'] as String) : null,
        eventType: json['event_type'] as String?,
        guestCount: json['guest_count'] as int?,
        venueSpace: json['venue_space'] as String?,
        fbMinimumCents: json['fb_minimum_cents'] as int?,
        menuAppetizers: json['menu_appetizers'] as String?,
        menuEntrees: json['menu_entrees'] as String?,
        menuDesserts: json['menu_desserts'] as String?,
        menuBarPackage: json['menu_bar_package'] as String?,
        specialRequirements: json['special_requirements'] as String?,
        status: json['status'] as String,
        createdAt: DateTime.parse(json['created_at'] as String),
        updatedAt: DateTime.parse(json['updated_at'] as String),
      );

  final String id;
  final String venueId;
  final String? leadId;
  final String eventName;
  final DateTime? eventDate;
  final String? eventType;
  final int? guestCount;
  final String? venueSpace;
  final int? fbMinimumCents;
  final String? menuAppetizers;
  final String? menuEntrees;
  final String? menuDesserts;
  final String? menuBarPackage;
  final String? specialRequirements;
  final String status;
  final DateTime createdAt;
  final DateTime updatedAt;

  static const statuses = ['draft', 'sent', 'reviewed', 'confirmed', 'amended', 'cancelled'];

  @override
  bool operator ==(Object other) => other is CrmBeo && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

class CrmContract {
  const CrmContract({
    required this.id,
    required this.venueId,
    this.leadId,
    this.beoId,
    required this.contractNumber,
    this.eventName,
    this.eventDate,
    this.guestCount,
    this.venueSpace,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
  });

  factory CrmContract.fromJson(Map<String, dynamic> json) => CrmContract(
        id: json['id'] as String,
        venueId: json['venue_id'] as String,
        leadId: json['lead_id'] as String?,
        beoId: json['beo_id'] as String?,
        contractNumber: json['contract_number'] as String,
        eventName: json['event_name'] as String?,
        eventDate: json['event_date'] != null ? DateTime.parse(json['event_date'] as String) : null,
        guestCount: json['guest_count'] as int?,
        venueSpace: json['venue_space'] as String?,
        status: json['status'] as String,
        createdAt: DateTime.parse(json['created_at'] as String),
        updatedAt: DateTime.parse(json['updated_at'] as String),
      );

  final String id;
  final String venueId;
  final String? leadId;
  final String? beoId;
  final String contractNumber;
  final String? eventName;
  final DateTime? eventDate;
  final int? guestCount;
  final String? venueSpace;
  final String status;
  final DateTime createdAt;
  final DateTime updatedAt;

  static const statuses = [
    'draft', 'sent', 'viewed', 'partially_signed', 'fully_signed', 'expired', 'cancelled', 'disputed',
  ];

  @override
  bool operator ==(Object other) => other is CrmContract && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

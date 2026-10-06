class Reservation {
  const Reservation({
    required this.id,
    required this.organizationId,
    required this.venueId,
    this.guestId,
    required this.guestName,
    this.guestPhone,
    this.guestEmail,
    required this.partySize,
    required this.reservationTime,
    this.durationMinutes = 90,
    this.source = 'direct',
    this.status = 'confirmed',
    this.specialRequests,
    this.tags = const [],
    this.estimatedValueCents,
    this.depositDueCents,
    this.depositStatus = 'none',
    this.depositCheckoutSessionId,
    this.depositPaymentIntentId,
    this.depositPaidAt,
    this.externalId,
    this.lastExternalEventAt,
    this.seatedAt,
    this.completedAt,
    this.cancelledAt,
    this.notes,
    this.assignedTo,
    required this.createdAt,
    required this.updatedAt,
  });

  factory Reservation.fromJson(Map<String, dynamic> json) {
    return Reservation(
      id: json['id'] as String,
      organizationId: json['organization_id'] as String,
      venueId: json['venue_id'] as String,
      guestId: json['guest_id'] as String?,
      guestName: json['guest_name'] as String,
      guestPhone: json['guest_phone'] as String?,
      guestEmail: json['guest_email'] as String?,
      partySize: (json['party_size'] as num).toInt(),
      reservationTime:
          DateTime.parse(json['reservation_time'] as String).toLocal(),
      durationMinutes: (json['duration_minutes'] as num?)?.toInt() ?? 90,
      source: json['source'] as String? ?? 'direct',
      status: json['status'] as String? ?? 'confirmed',
      specialRequests: json['special_requests'] as String?,
      tags:
          (json['tags'] as List<dynamic>?)?.map((e) => e.toString()).toList() ??
              const [],
      estimatedValueCents: (json['estimated_value_cents'] as num?)?.toInt(),
      depositDueCents: (json['deposit_due_cents'] as num?)?.toInt(),
      depositStatus: json['deposit_status'] as String? ?? 'none',
      depositCheckoutSessionId: json['deposit_checkout_session_id'] as String?,
      depositPaymentIntentId: json['deposit_payment_intent_id'] as String?,
      depositPaidAt: json['deposit_paid_at'] != null
          ? DateTime.parse(json['deposit_paid_at'] as String)
          : null,
      externalId: json['external_id'] as String?,
      lastExternalEventAt: json['last_external_event_at'] != null
          ? DateTime.parse(json['last_external_event_at'] as String)
          : null,
      seatedAt: json['seated_at'] != null
          ? DateTime.parse(json['seated_at'] as String)
          : null,
      completedAt: json['completed_at'] != null
          ? DateTime.parse(json['completed_at'] as String)
          : null,
      cancelledAt: json['cancelled_at'] != null
          ? DateTime.parse(json['cancelled_at'] as String)
          : null,
      notes: json['notes'] as String?,
      assignedTo: json['assigned_to'] as String?,
      createdAt: DateTime.parse(json['created_at'] as String),
      updatedAt: DateTime.parse(json['updated_at'] as String),
    );
  }

  /// Team member this reservation is assigned to (its server/host), if any.
  final String? assignedTo;
  final String id;
  final String organizationId;
  final String venueId;
  final String? guestId;
  final String guestName;
  final String? guestPhone;
  final String? guestEmail;
  final int partySize;
  final DateTime reservationTime;
  final int durationMinutes;
  final String source;
  final String status;
  final String? specialRequests;
  final List<String> tags;
  final int? estimatedValueCents;
  final int? depositDueCents;
  final String depositStatus;
  final String? depositCheckoutSessionId;
  final String? depositPaymentIntentId;
  final DateTime? depositPaidAt;
  final String? externalId;
  final DateTime? lastExternalEventAt;
  final DateTime? seatedAt;
  final DateTime? completedAt;
  final DateTime? cancelledAt;
  final String? notes;
  final DateTime createdAt;
  final DateTime updatedAt;

  bool get isDepositPaid => depositStatus == 'paid';
  bool get isConfirmed => status == 'confirmed';
  bool get isSeated => status == 'seated';

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'organization_id': organizationId,
      'venue_id': venueId,
      if (guestId != null) 'guest_id': guestId,
      'guest_name': guestName,
      if (guestPhone != null) 'guest_phone': guestPhone,
      if (guestEmail != null) 'guest_email': guestEmail,
      'party_size': partySize,
      'reservation_time': reservationTime.toUtc().toIso8601String(),
      'duration_minutes': durationMinutes,
      'source': source,
      'status': status,
      if (specialRequests != null) 'special_requests': specialRequests,
      'tags': tags,
      if (estimatedValueCents != null)
        'estimated_value_cents': estimatedValueCents,
      if (depositDueCents != null) 'deposit_due_cents': depositDueCents,
      'deposit_status': depositStatus,
      if (depositCheckoutSessionId != null)
        'deposit_checkout_session_id': depositCheckoutSessionId,
      if (depositPaymentIntentId != null)
        'deposit_payment_intent_id': depositPaymentIntentId,
      if (depositPaidAt != null)
        'deposit_paid_at': depositPaidAt!.toUtc().toIso8601String(),
      if (externalId != null) 'external_id': externalId,
      if (lastExternalEventAt != null)
        'last_external_event_at':
            lastExternalEventAt!.toUtc().toIso8601String(),
      if (seatedAt != null) 'seated_at': seatedAt!.toUtc().toIso8601String(),
      if (completedAt != null)
        'completed_at': completedAt!.toUtc().toIso8601String(),
      if (cancelledAt != null)
        'cancelled_at': cancelledAt!.toUtc().toIso8601String(),
      if (notes != null) 'notes': notes,
      'created_at': createdAt.toUtc().toIso8601String(),
      'updated_at': updatedAt.toUtc().toIso8601String(),
    };
  }
}

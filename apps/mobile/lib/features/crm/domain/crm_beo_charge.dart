class CrmBeoCharge {
  const CrmBeoCharge({
    required this.id,
    required this.beoId,
    required this.venueId,
    required this.description,
    required this.category,
    required this.amountCents,
  });

  factory CrmBeoCharge.fromJson(Map<String, dynamic> json) => CrmBeoCharge(
        id: json['id'] as String,
        beoId: json['beo_id'] as String,
        venueId: json['venue_id'] as String,
        description: json['description'] as String,
        category: json['category'] as String,
        amountCents: json['amount_cents'] as int,
      );

  final String id;
  final String beoId;
  final String venueId;
  final String description;
  final String category;
  final int amountCents;

  bool get isDiscount => category == 'discount';
  int get signedAmountCents => isDiscount ? -amountCents : amountCents;

  static const categories = [
    'food',
    'beverage',
    'room',
    'service',
    'tax',
    'discount',
    'other',
  ];
}

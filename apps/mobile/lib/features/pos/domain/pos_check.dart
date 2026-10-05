class PosCheck {
  const PosCheck({
    required this.id,
    required this.organizationId,
    required this.venueId,
    this.posConnectionId,
    required this.provider,
    required this.externalCheckId,
    this.tableLabel,
    this.serverName,
    this.guestName,
    this.guestCount = 1,
    required this.openedAt,
    this.closedAt,
    this.subtotalCents = 0,
    this.taxCents = 0,
    this.tipCents = 0,
    this.totalCents = 0,
    this.status = 'closed',
    this.menuItems = const [],
    required this.createdAt,
    required this.updatedAt,
  });

  factory PosCheck.fromJson(Map<String, dynamic> json) {
    return PosCheck(
      id: json['id'] as String,
      organizationId: json['organization_id'] as String,
      venueId: json['venue_id'] as String,
      posConnectionId: json['pos_connection_id'] as String?,
      provider: json['provider'] as String,
      externalCheckId: json['external_check_id'] as String,
      tableLabel: json['table_label'] as String?,
      serverName: json['server_name'] as String?,
      guestName: json['guest_name'] as String?,
      guestCount: (json['guest_count'] as num?)?.toInt() ?? 1,
      openedAt: DateTime.parse(json['opened_at'] as String),
      closedAt: json['closed_at'] != null
          ? DateTime.parse(json['closed_at'] as String)
          : null,
      subtotalCents: (json['subtotal_cents'] as num?)?.toInt() ?? 0,
      taxCents: (json['tax_cents'] as num?)?.toInt() ?? 0,
      tipCents: (json['tip_cents'] as num?)?.toInt() ?? 0,
      totalCents: (json['total_cents'] as num?)?.toInt() ?? 0,
      status: json['status'] as String? ?? 'closed',
      menuItems: (json['menu_items'] as List<dynamic>?) ?? const [],
      createdAt: DateTime.parse(json['created_at'] as String),
      updatedAt: DateTime.parse(json['updated_at'] as String),
    );
  }

  final String id;
  final String organizationId;
  final String venueId;
  final String? posConnectionId;
  final String provider;
  final String externalCheckId;
  final String? tableLabel;
  final String? serverName;
  final String? guestName;
  final int guestCount;
  final DateTime openedAt;
  final DateTime? closedAt;
  final int subtotalCents;
  final int taxCents;
  final int tipCents;
  final int totalCents;
  final String status;
  final List<dynamic> menuItems;
  final DateTime createdAt;
  final DateTime updatedAt;

  double get totalDollars => totalCents / 100.0;
  double get tipDollars => tipCents / 100.0;
}

/// See the note in features/organizations/domain/organization.dart about why this is a
/// hand-written model rather than `freezed` for now.
class CrmLead {
  const CrmLead({
    required this.id,
    required this.venueId,
    this.guestId,
    required this.fullName,
    this.email,
    this.phone,
    this.company,
    this.source,
    required this.status,
    this.tags = const [],
    this.assignedTo,
    this.marketingOptIn,
    this.lastActivityAt,
    this.estimatedValueCents,
    required this.createdAt,
    required this.updatedAt,
  });

  factory CrmLead.fromJson(Map<String, dynamic> json) => CrmLead(
        id: json['id'] as String,
        venueId: json['venue_id'] as String,
        guestId: json['guest_id'] as String?,
        fullName: json['full_name'] as String,
        email: json['email'] as String?,
        phone: json['phone'] as String?,
        company: json['company'] as String?,
        source: json['source'] as String?,
        status: json['status'] as String,
        tags: (json['tags'] as List<dynamic>?)?.map((e) => e.toString()).toList() ?? const [],
        assignedTo: json['assigned_to'] as String?,
        marketingOptIn: json['marketing_opt_in'] as bool?,
        lastActivityAt: json['last_activity_at'] != null
            ? DateTime.parse(json['last_activity_at'] as String)
            : null,
        estimatedValueCents: json['estimated_value_cents'] as int?,
        createdAt: DateTime.parse(json['created_at'] as String),
        updatedAt: DateTime.parse(json['updated_at'] as String),
      );

  final String id;
  final String venueId;
  final String? guestId;
  final String fullName;
  final String? email;
  final String? phone;
  final String? company;
  final String? source;
  final String status;
  final List<String> tags;
  final String? assignedTo;
  final bool? marketingOptIn;
  final DateTime? lastActivityAt;
  final int? estimatedValueCents;
  final DateTime createdAt;
  final DateTime updatedAt;

  static const statuses = [
    'new', 'contacted', 'qualified', 'proposal_sent', 'negotiating',
    'won', 'lost', 'unqualified', 'on_hold',
  ];

  @override
  bool operator ==(Object other) => other is CrmLead && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

class CrmNote {
  const CrmNote({
    required this.id,
    required this.leadId,
    this.authorId,
    required this.text,
    required this.createdAt,
  });

  factory CrmNote.fromJson(Map<String, dynamic> json) => CrmNote(
        id: json['id'] as String,
        leadId: json['lead_id'] as String,
        authorId: json['author_id'] as String?,
        text: json['text'] as String,
        createdAt: DateTime.parse(json['created_at'] as String),
      );

  final String id;
  final String leadId;
  final String? authorId;
  final String text;
  final DateTime createdAt;
}

class CrmActivityLogEntry {
  const CrmActivityLogEntry({
    required this.id,
    this.leadId,
    this.actorId,
    required this.kind,
    this.detail,
    required this.createdAt,
  });

  factory CrmActivityLogEntry.fromJson(Map<String, dynamic> json) => CrmActivityLogEntry(
        id: json['id'] as String,
        leadId: json['lead_id'] as String?,
        actorId: json['actor_id'] as String?,
        kind: json['kind'] as String,
        detail: json['detail'] as String?,
        createdAt: DateTime.parse(json['created_at'] as String),
      );

  final String id;
  final String? leadId;
  final String? actorId;
  final String kind;
  final String? detail;
  final DateTime createdAt;
}

class CrmForecastRow {
  const CrmForecastRow({
    required this.status,
    required this.leadCount,
    required this.rawValueCents,
    required this.weightedValueCents,
  });

  factory CrmForecastRow.fromJson(Map<String, dynamic> json) => CrmForecastRow(
        status: json['status'] as String,
        leadCount: (json['lead_count'] as num).toInt(),
        rawValueCents: (json['raw_value_cents'] as num).toInt(),
        weightedValueCents: (json['weighted_value_cents'] as num).toInt(),
      );

  final String status;
  final int leadCount;
  final int rawValueCents;
  final int weightedValueCents;
}

class CrmStaleLead {
  const CrmStaleLead({
    required this.id,
    required this.fullName,
    required this.status,
    this.lastActivityAt,
    required this.daysSinceActivity,
  });

  factory CrmStaleLead.fromJson(Map<String, dynamic> json) => CrmStaleLead(
        id: json['id'] as String,
        fullName: json['full_name'] as String,
        status: json['status'] as String,
        lastActivityAt: json['last_activity_at'] != null
            ? DateTime.parse(json['last_activity_at'] as String)
            : null,
        daysSinceActivity: (json['days_since_activity'] as num).toInt(),
      );

  final String id;
  final String fullName;
  final String status;
  final DateTime? lastActivityAt;
  final int daysSinceActivity;
}

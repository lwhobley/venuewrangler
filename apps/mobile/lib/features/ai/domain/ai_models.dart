/// Result shapes for the four task types the `ai-assistant` Edge Function supports (see
/// supabase/functions/ai-assistant/prompts.ts for the exact JSON contract each one returns).
/// Every field the model could omit is nullable here too — these are hand-written, not
/// freezed, for the same reason as the other Phase 1/2 domain models (see
/// features/organizations/domain/organization.dart): no server-side defaulting to fight.
class StaffImportRow {
  const StaffImportRow({
    required this.fullName,
    this.email,
    this.phone,
    this.roleHint,
  });

  final String fullName;
  final String? email;
  final String? phone;
  final String? roleHint;

  factory StaffImportRow.fromJson(Map<String, dynamic> json) => StaffImportRow(
        fullName: json['full_name'] as String,
        email: json['email'] as String?,
        phone: json['phone'] as String?,
        roleHint: json['role_hint'] as String?,
      );
}

class StaffImportResult {
  const StaffImportResult(this.staff);

  final List<StaffImportRow> staff;

  factory StaffImportResult.fromJson(Map<String, dynamic> json) =>
      StaffImportResult(
        (json['staff'] as List<dynamic>? ?? const [])
            .map((row) => StaffImportRow.fromJson(row as Map<String, dynamic>))
            .toList(growable: false),
      );
}

class InventoryLineItem {
  const InventoryLineItem({
    required this.name,
    this.quantity,
    this.unit,
    this.unitCostUsd,
  });

  final String name;
  final num? quantity;
  final String? unit;
  final num? unitCostUsd;

  factory InventoryLineItem.fromJson(Map<String, dynamic> json) =>
      InventoryLineItem(
        name: json['name'] as String,
        quantity: json['quantity'] as num?,
        unit: json['unit'] as String?,
        unitCostUsd: json['unit_cost_usd'] as num?,
      );
}

class InventoryParseResult {
  const InventoryParseResult(this.items);

  final List<InventoryLineItem> items;

  factory InventoryParseResult.fromJson(Map<String, dynamic> json) =>
      InventoryParseResult(
        (json['items'] as List<dynamic>? ?? const [])
            .map(
              (row) => InventoryLineItem.fromJson(row as Map<String, dynamic>),
            )
            .toList(growable: false),
      );
}

class ShiftSuggestion {
  const ShiftSuggestion({
    required this.staffId,
    this.shiftId,
    this.startTime,
    this.endTime,
    required this.reason,
  });

  final String staffId;
  final String? shiftId;
  final String? startTime;
  final String? endTime;
  final String reason;

  factory ShiftSuggestion.fromJson(Map<String, dynamic> json) =>
      ShiftSuggestion(
        staffId: json['staff_id'] as String,
        shiftId: json['shift_id'] as String?,
        startTime: json['start_time'] as String?,
        endTime: json['end_time'] as String?,
        reason: json['reason'] as String,
      );
}

class SchedulingSuggestionResult {
  const SchedulingSuggestionResult(this.suggestions);

  final List<ShiftSuggestion> suggestions;

  factory SchedulingSuggestionResult.fromJson(Map<String, dynamic> json) =>
      SchedulingSuggestionResult(
        (json['suggestions'] as List<dynamic>? ?? const [])
            .map((row) => ShiftSuggestion.fromJson(row as Map<String, dynamic>))
            .toList(growable: false),
      );
}

class WranglerAskResult {
  const WranglerAskResult({required this.answer, required this.needsMoreInfo});

  final String answer;
  final bool needsMoreInfo;

  factory WranglerAskResult.fromJson(Map<String, dynamic> json) =>
      WranglerAskResult(
        answer: json['answer'] as String,
        needsMoreInfo: json['needs_more_info'] as bool? ?? false,
      );
}

class ShiftInsightItem {
  const ShiftInsightItem({
    required this.kind,
    required this.title,
    required this.body,
  });

  final String kind;
  final String title;
  final String body;

  factory ShiftInsightItem.fromJson(Map<String, dynamic> json) =>
      ShiftInsightItem(
        kind: json['kind'] as String? ?? 'shift_summary',
        title: json['title'] as String? ?? 'Shift Insight',
        body: json['body'] as String? ?? '',
      );
}

class ShiftInsightsResult {
  const ShiftInsightsResult(this.insights);

  final List<ShiftInsightItem> insights;

  factory ShiftInsightsResult.fromJson(Map<String, dynamic> json) =>
      ShiftInsightsResult(
        (json['insights'] as List<dynamic>? ?? const [])
            .map(
              (row) => ShiftInsightItem.fromJson(row as Map<String, dynamic>),
            )
            .toList(growable: false),
      );
}

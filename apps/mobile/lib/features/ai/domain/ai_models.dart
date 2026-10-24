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
    this.sizeAmount,
    this.sizeUnit,
    this.category,
    this.subcategory,
  });

  final String name;
  final num? quantity;
  final String? unit;
  final num? unitCostUsd;
  final num? sizeAmount;
  final String? sizeUnit, category, subcategory;

  factory InventoryLineItem.fromJson(Map<String, dynamic> json) =>
      InventoryLineItem(
        name: json['name'] as String,
        quantity: json['quantity'] as num?,
        unit: json['unit'] as String?,
        unitCostUsd: json['unit_cost_usd'] as num?,
        sizeAmount: json['size_amount'] as num?,
        sizeUnit: json['size_unit'] as String?,
        category: json['category'] as String?,
        subcategory: json['subcategory'] as String?,
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
    this.staffName,
    this.shiftId,
    this.roleLabel,
    this.startTime,
    this.endTime,
    required this.reason,
  });

  /// The roster key the app sent with the request (see `schedule_list_screen.dart`), or
  /// whatever the model put there — callers resolve it against the roster, never trust it.
  final String staffId;
  final String? staffName;
  final String? shiftId;
  final String? roleLabel;
  final String? startTime;
  final String? endTime;
  final String reason;

  factory ShiftSuggestion.fromJson(Map<String, dynamic> json) =>
      ShiftSuggestion(
        staffId: json['staff_id']?.toString() ?? '',
        staffName: json['staff_name'] as String?,
        shiftId: json['shift_id'] as String?,
        roleLabel: json['role_label'] as String?,
        startTime: json['start_time'] as String?,
        endTime: json['end_time'] as String?,
        reason: json['reason'] as String? ?? '',
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

// --- Shift handover summary (`handover_summary`) -------------------------------------------
//
// Model output is untrusted: every field is optional, wrong types are dropped rather than
// thrown on, and sizes are capped so one runaway response cannot flood the screen.

String? _enquiryText(Object? value, {int max = 300}) {
  if (value is! String) return null;
  final text = value.trim();
  if (text.isEmpty) return null;
  return text.length > max ? text.substring(0, max).trimRight() : text;
}

List<String> _enquiryTextList(
  Object? value, {
  int maxItems = 20,
  int maxLength = 200,
}) {
  if (value is! List) return const [];
  final out = <String>[];
  for (final entry in value) {
    final text = _enquiryText(entry, max: maxLength);
    if (text != null) out.add(text);
    if (out.length >= maxItems) break;
  }
  return out;
}

num? _enquiryNumber(Object? value) {
  if (value is num) return value.isFinite ? value : null;
  if (value is String) {
    final parsed = num.tryParse(value.replaceAll(RegExp(r'[,$\s]'), ''));
    return parsed != null && parsed.isFinite ? parsed : null;
  }
  return null;
}

class HandoverSection {
  const HandoverSection({required this.title, required this.items});

  final String title;
  final List<String> items;

  static HandoverSection? tryParse(Object? json) {
    if (json is! Map) return null;
    final title = _enquiryText(json['title'], max: 80);
    final items = _enquiryTextList(json['items'], maxLength: 300);
    if (title == null || items.isEmpty) return null;
    return HandoverSection(title: title, items: items);
  }
}

class HandoverSummaryResult {
  const HandoverSummaryResult({required this.summary, required this.sections});

  final String summary;
  final List<HandoverSection> sections;

  factory HandoverSummaryResult.fromJson(Map<String, dynamic> json) {
    final sections = <HandoverSection>[];
    final raw = json['sections'];
    if (raw is List) {
      for (final entry in raw) {
        final section = HandoverSection.tryParse(entry);
        if (section != null) sections.add(section);
        if (sections.length >= 12) break;
      }
    }
    return HandoverSummaryResult(
      summary: _enquiryText(json['summary'], max: 600) ?? '',
      sections: sections,
    );
  }

  bool get isEmpty => summary.isEmpty && sections.isEmpty;

  /// The plain-text note the manager edits, copies or posts.
  String toText() {
    final buffer = StringBuffer();
    if (summary.isNotEmpty) buffer.writeln(summary);
    for (final section in sections) {
      if (buffer.isNotEmpty) buffer.writeln();
      buffer.writeln(section.title);
      for (final item in section.items) {
        buffer.writeln('- $item');
      }
    }
    return buffer.toString().trimRight();
  }
}

// --- Event enquiry (`event_enquiry_parse`) --------------------------------------------------

/// What the model pulled out of a pasted client enquiry. Every field is nullable: nothing here
/// is a fact until the manager confirms it in the preview form. Dates are venue wall dates
/// (UTC-flagged midnight, like the rest of the app's wall times) and times are minutes since
/// midnight on the venue's clock — never an instant, never with an offset.
class EventEnquiryResult {
  const EventEnquiryResult({
    this.contactName,
    this.contactEmail,
    this.contactPhone,
    this.company,
    this.eventName,
    this.eventType,
    this.eventDate,
    this.startMinutes,
    this.endMinutes,
    this.guestCount,
    this.budgetUsd,
    this.requestedItems = const [],
    this.notes,
    this.uncertain = const {},
    this.missing = const [],
  });

  final String? contactName;
  final String? contactEmail;
  final String? contactPhone;
  final String? company;
  final String? eventName;
  final String? eventType;
  final DateTime? eventDate;
  final int? startMinutes;
  final int? endMinutes;
  final int? guestCount;
  final num? budgetUsd;
  final List<String> requestedItems;
  final String? notes;

  /// Field keys (`contact_name`, `event_date`, ...) the model was unsure about, plus any value
  /// this parser had to reject.
  final Set<String> uncertain;

  /// Things the manager still has to ask the client.
  final List<String> missing;

  static final _email = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$');

  factory EventEnquiryResult.fromJson(Map<String, dynamic> json) {
    final uncertain = <String>{
      for (final key in _enquiryTextList(json['uncertain'], maxLength: 40))
        key.toLowerCase(),
    };

    String? email = _enquiryText(json['contact_email'], max: 120);
    if (email != null && !_email.hasMatch(email)) {
      email = null;
      uncertain.add('contact_email');
    }

    DateTime? date;
    final dateText = _enquiryText(json['event_date'], max: 10);
    if (dateText != null) {
      final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(dateText);
      if (match != null) {
        final y = int.parse(match.group(1)!);
        final m = int.parse(match.group(2)!);
        final d = int.parse(match.group(3)!);
        final candidate = DateTime.utc(y, m, d);
        if (y >= 2000 &&
            y <= 2100 &&
            candidate.month == m &&
            candidate.day == d) {
          date = candidate;
        }
      }
      if (date == null) uncertain.add('event_date');
    }

    int? minutes(Object? value, String key) {
      final text = _enquiryText(value, max: 5);
      if (text == null) return null;
      final match = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(text);
      final h = int.tryParse(match?.group(1) ?? '');
      final m = int.tryParse(match?.group(2) ?? '');
      if (h == null || m == null || h > 23 || m > 59) {
        uncertain.add(key);
        return null;
      }
      return h * 60 + m;
    }

    final guests = _enquiryNumber(json['guest_count']);
    final budget = _enquiryNumber(json['budget_usd']);

    return EventEnquiryResult(
      contactName: _enquiryText(json['contact_name'], max: 120),
      contactEmail: email,
      contactPhone: _enquiryText(json['contact_phone'], max: 40),
      company: _enquiryText(json['company'], max: 120),
      eventName: _enquiryText(json['event_name'], max: 120),
      eventType: _enquiryText(json['event_type'], max: 60),
      eventDate: date,
      startMinutes: minutes(json['start_time'], 'start_time'),
      endMinutes: minutes(json['end_time'], 'end_time'),
      guestCount: guests?.round().clamp(1, 10000),
      budgetUsd:
          budget == null || budget < 0 ? null : budget.clamp(0, 10000000),
      requestedItems: _enquiryTextList(json['requested_items']),
      notes: _enquiryText(json['notes'], max: 1000),
      uncertain: uncertain,
      missing: _enquiryTextList(json['missing'], maxItems: 15),
    );
  }
}

// Draft-week and reorder results. Unlike the older parsers above these tolerate missing or
// extra fields and odd types: every row that is not an object is skipped, text is trimmed and
// length-capped, and numbers are clamped, because the callers show them for review and then
// write them (see schedules/domain/schedule_draft.dart and
// inventory/domain/reorder_planner.dart).

String? _draftText(Object? value, {int max = 200}) {
  if (value == null) return null;
  final text = value.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
  if (text.isEmpty) return null;
  return text.length > max ? text.substring(0, max) : text;
}

Iterable<Map<String, dynamic>> _draftRows(Object? value) sync* {
  if (value is! List) return;
  for (final row in value) {
    if (row is Map) yield Map<String, dynamic>.from(row);
  }
}

/// One proposed shift from `schedule_draft`. [staffId] is a roster key (`staff_3`) or empty for
/// an open shift; callers resolve it against the roster and drop keys that do not match.
class ScheduleDraftShift {
  const ScheduleDraftShift({
    required this.staffId,
    this.roleLabel,
    this.startTime,
    this.endTime,
    this.reason = '',
  });

  final String staffId;
  final String? roleLabel;
  final String? startTime;
  final String? endTime;
  final String reason;

  factory ScheduleDraftShift.fromJson(Map<String, dynamic> json) =>
      ScheduleDraftShift(
        staffId: _draftText(json['staff_id'], max: 40) ?? '',
        roleLabel: _draftText(json['role_label'], max: 60),
        startTime: _draftText(json['start_time'], max: 40),
        endTime: _draftText(json['end_time'], max: 40),
        reason: _draftText(json['reason'], max: 240) ?? '',
      );
}

class ScheduleDraftResult {
  const ScheduleDraftResult(this.shifts);

  /// Rows beyond this many are ignored: a week never needs more, and a runaway answer must not
  /// flood the review list.
  static const maxShifts = 120;

  final List<ScheduleDraftShift> shifts;

  factory ScheduleDraftResult.fromJson(Map<String, dynamic> json) =>
      ScheduleDraftResult(
        _draftRows(json['shifts'])
            .map(ScheduleDraftShift.fromJson)
            .take(maxShifts)
            .toList(growable: false),
      );
}

/// One draft order line from `inventory_reorder`. [suggestedQuantity] is null when the model's
/// number was missing, negative or not finite; it is clamped to [maxQuantity].
class ReorderSuggestion {
  const ReorderSuggestion({
    required this.itemKey,
    this.suggestedQuantity,
    this.reason = '',
  });

  static const maxQuantity = 100000;

  final String itemKey;
  final num? suggestedQuantity;
  final String reason;

  factory ReorderSuggestion.fromJson(Map<String, dynamic> json) {
    final raw = json['suggested_quantity'];
    final number =
        raw is num ? raw : num.tryParse(raw?.toString().trim() ?? '');
    final valid = number != null && number.isFinite && number >= 0;
    return ReorderSuggestion(
      itemKey: _draftText(json['item_key'], max: 40) ?? '',
      suggestedQuantity: valid ? number.clamp(0, maxQuantity) : null,
      reason: _draftText(json['reason'], max: 240) ?? '',
    );
  }
}

class ReorderVarianceFlag {
  const ReorderVarianceFlag({required this.itemKey, required this.note});

  final String itemKey;
  final String note;

  factory ReorderVarianceFlag.fromJson(Map<String, dynamic> json) =>
      ReorderVarianceFlag(
        itemKey: _draftText(json['item_key'], max: 40) ?? '',
        note: _draftText(json['note'], max: 240) ?? '',
      );
}

class InventoryReorderResult {
  const InventoryReorderResult({
    required this.orders,
    this.varianceFlags = const [],
  });

  static const maxRows = 300;

  final List<ReorderSuggestion> orders;
  final List<ReorderVarianceFlag> varianceFlags;

  factory InventoryReorderResult.fromJson(Map<String, dynamic> json) =>
      InventoryReorderResult(
        orders: _draftRows(json['orders'])
            .map(ReorderSuggestion.fromJson)
            .take(maxRows)
            .toList(growable: false),
        varianceFlags: _draftRows(json['variance_flags'])
            .map(ReorderVarianceFlag.fromJson)
            .take(maxRows)
            .toList(growable: false),
      );
}

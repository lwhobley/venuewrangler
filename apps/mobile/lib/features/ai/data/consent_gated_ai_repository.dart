import '../domain/ai_models.dart';
import 'ai_repository.dart';

/// Wraps an [AiRepository] so no request leaves the device until [ensureConsent] completes
/// (it throws when the person declines). Enforced here, rather than in each screen, because
/// five features call AI and any new caller must get the disclosure for free.
class ConsentGatedAiRepository implements AiRepository {
  ConsentGatedAiRepository(this._inner, this._ensureConsent);

  final AiRepository _inner;
  final Future<void> Function() _ensureConsent;

  /// Concurrent first calls share one prompt instead of stacking dialogs.
  Future<void>? _pending;

  Future<void> _gate() {
    final pending = _pending ??= _ensureConsent().whenComplete(() {
      _pending = null;
    });
    return pending;
  }

  @override
  Future<StaffImportResult> parseStaffImport({
    required String venueId,
    required String pastedText,
  }) async {
    await _gate();
    return _inner.parseStaffImport(venueId: venueId, pastedText: pastedText);
  }

  @override
  Future<InventoryParseResult> parseInventory({
    required String venueId,
    required String pastedText,
  }) async {
    await _gate();
    return _inner.parseInventory(venueId: venueId, pastedText: pastedText);
  }

  @override
  Future<SchedulingSuggestionResult> suggestScheduling({
    required String venueId,
    required String context,
  }) async {
    await _gate();
    return _inner.suggestScheduling(venueId: venueId, context: context);
  }

  @override
  Future<WranglerAskResult> askWrangler({
    required String venueId,
    required String question,
  }) async {
    await _gate();
    return _inner.askWrangler(venueId: venueId, question: question);
  }

  @override
  Future<ShiftInsightsResult> generateShiftInsights({
    required String venueId,
    required String context,
  }) async {
    await _gate();
    return _inner.generateShiftInsights(venueId: venueId, context: context);
  }

  @override
  Future<HandoverSummaryResult> summarizeHandover({
    required String venueId,
    required String facts,
  }) async {
    await _gate();
    return _inner.summarizeHandover(venueId: venueId, facts: facts);
  }

  @override
  Future<EventEnquiryResult> parseEventEnquiry({
    required String venueId,
    required String enquiryText,
  }) async {
    await _gate();
    return _inner.parseEventEnquiry(venueId: venueId, enquiryText: enquiryText);
  }
}

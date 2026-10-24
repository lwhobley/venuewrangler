import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/errors/app_error.dart';
import '../../../core/errors/error_reporter.dart';
import '../../../core/errors/transport_failure.dart';
import '../domain/ai_models.dart';

/// Calls the `ai-assistant` Edge Function (supabase/functions/ai-assistant). The function
/// itself re-derives organization_id from venue_id via the caller's own RLS-respecting
/// client — this repository does not duplicate that check, it just needs a venueId the
/// caller is actually a member of, same as every other Phase 2/3 repository.
///
/// Every AI-assisted action backed by this repository must have a manual, non-AI fallback
/// workflow per features/ai/README.md: the result here is always a suggestion to review, not
/// an applied change.
abstract interface class AiRepository {
  Future<StaffImportResult> parseStaffImport({
    required String venueId,
    required String pastedText,
  });

  Future<InventoryParseResult> parseInventory({
    required String venueId,
    required String pastedText,
  });

  Future<SchedulingSuggestionResult> suggestScheduling({
    required String venueId,
    required String context,
  });

  Future<WranglerAskResult> askWrangler({
    required String venueId,
    required String question,
  });

  Future<ShiftInsightsResult> generateShiftInsights({
    required String venueId,
    required String context,
  });

  /// Manager-only. [facts] is the compact JSON the handover screen gathered deterministically.
  Future<HandoverSummaryResult> summarizeHandover({
    required String venueId,
    required String facts,
  });

  /// Manager-only. [enquiryText] is the pasted client email/message, prefixed with today's date.
  Future<EventEnquiryResult> parseEventEnquiry({
    required String venueId,
    required String enquiryText,
  });
}

class SupabaseAiRepository implements AiRepository {
  const SupabaseAiRepository(this._client);

  final SupabaseClient _client;

  @override
  Future<StaffImportResult> parseStaffImport({
    required String venueId,
    required String pastedText,
  }) async {
    return _invoke(
      task: 'staff_import_parse',
      venueId: venueId,
      input: pastedText,
      parse: StaffImportResult.fromJson,
    );
  }

  @override
  Future<InventoryParseResult> parseInventory({
    required String venueId,
    required String pastedText,
  }) async {
    return _invoke(
      task: 'inventory_parse',
      venueId: venueId,
      input: pastedText,
      parse: InventoryParseResult.fromJson,
    );
  }

  @override
  Future<SchedulingSuggestionResult> suggestScheduling({
    required String venueId,
    required String context,
  }) async {
    return _invoke(
      task: 'scheduling_suggestion',
      venueId: venueId,
      input: context,
      parse: SchedulingSuggestionResult.fromJson,
    );
  }

  @override
  Future<WranglerAskResult> askWrangler({
    required String venueId,
    required String question,
  }) async {
    return _invoke(
      task: 'wrangler_ask',
      venueId: venueId,
      input: question,
      parse: WranglerAskResult.fromJson,
    );
  }

  @override
  Future<ShiftInsightsResult> generateShiftInsights({
    required String venueId,
    required String context,
  }) async {
    return _invoke(
      task: 'shift_insights',
      venueId: venueId,
      input: context,
      parse: ShiftInsightsResult.fromJson,
    );
  }

  @override
  Future<HandoverSummaryResult> summarizeHandover({
    required String venueId,
    required String facts,
  }) async {
    return _invoke(
      task: 'handover_summary',
      venueId: venueId,
      input: facts,
      parse: HandoverSummaryResult.fromJson,
    );
  }

  @override
  Future<EventEnquiryResult> parseEventEnquiry({
    required String venueId,
    required String enquiryText,
  }) async {
    return _invoke(
      task: 'event_enquiry_parse',
      venueId: venueId,
      input: enquiryText,
      parse: EventEnquiryResult.fromJson,
    );
  }

  /// Shared call path for all four task types. Maps the Edge Function's error-code JSON
  /// bodies (see supabase/functions/ai-assistant/index.ts) to the app's [AppError] types so
  /// every screen gets a consistent, user-facing message rather than a raw exception.
  ///
  /// [parse] runs inside the same try, so a malformed response surfaces as an [AppError] instead
  /// of a raw TypeError reaching the screen.
  Future<T> _invoke<T>({
    required String task,
    required String venueId,
    required String input,
    required T Function(Map<String, dynamic> json) parse,
  }) async {
    final correlationId = newCorrelationId();

    try {
      final response = await _client.functions.invoke(
        'ai-assistant',
        headers: {'X-Correlation-Id': correlationId},
        body: {'task': task, 'venue_id': venueId, 'input': input},
      );

      final data = response.data;
      if (data is! Map) {
        throw const UnknownError(
          'The AI assistant returned an unexpected response.',
        );
      }
      final result = data['result'];
      if (result is! Map<String, dynamic>) {
        throw const UnknownError(
          'The AI assistant returned an unexpected response.',
        );
      }
      return parse(result);
    } on FunctionException catch (error) {
      throw _mapFunctionException(error);
    } on AppError {
      rethrow;
    } catch (error) {
      if (isTransportFailure(error)) throw const NetworkError();
      // A parse or type failure on the response is not a network problem.
      throw const UnknownError(
        'The AI assistant returned an unexpected response.',
      );
    }
  }

  AppError _mapFunctionException(FunctionException error) {
    final details = error.details;
    final code = details is Map ? details['error'] as String? : null;

    return switch (code) {
      'venue_not_found_or_not_a_member' => const PermissionDeniedError(
          "You don't have access to AI features for this venue.",
        ),
      'ai_disabled_for_org' => const AiUnavailableError(
          'AI features are turned off for this organization. An owner or admin '
          'can turn them on in Settings.',
        ),
      'subscription_required' => const AiUnavailableError(
          "This organization's subscription is not active, so AI features are "
          'paused. An owner can renew it under Billing.',
        ),
      'monthly_user_budget_exceeded' => const AiUnavailableError(
          'You have used your share of AI requests for this month. Try again '
          'next month, or ask an admin to raise the limit.',
        ),
      'ai_unavailable' => const AiUnavailableError(
          'The AI assistant is temporarily unavailable. Please try again shortly.',
        ),
      'monthly_budget_exceeded' => const AiUnavailableError(
          "This organization's AI budget for the month has been used up. "
          'Try again next month, or ask an admin to raise the limit.',
        ),
      'rate_limited' => const AiUnavailableError(
          'Too many AI requests in a short time. Wait a few minutes and try again.',
        ),
      'ai_provider_not_configured' ||
      'ai_provider_call_failed' ||
      'ai_response_not_valid_json' =>
        const AiUnavailableError(
          'The AI assistant is temporarily unavailable. Please try again shortly.',
        ),
      'manager_permission_required' => const PermissionDeniedError(
          'Only managers can use this AI feature.',
        ),
      'invalid_or_expired_session' =>
        const AuthError('Your session has expired. Please sign in again.'),
      _ => error.status >= 500
          ? const AiUnavailableError(
              'The AI assistant is temporarily unavailable.',
            )
          : const UnknownError(
              'The AI assistant could not process that request.',
            ),
    };
  }
}

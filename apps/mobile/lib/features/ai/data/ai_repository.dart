import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/errors/app_error.dart';
import '../../../core/errors/error_reporter.dart';
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
}

class SupabaseAiRepository implements AiRepository {
  const SupabaseAiRepository(this._client);

  final SupabaseClient _client;

  @override
  Future<StaffImportResult> parseStaffImport({
    required String venueId,
    required String pastedText,
  }) async {
    final result = await _invoke(task: 'staff_import_parse', venueId: venueId, input: pastedText);
    return StaffImportResult.fromJson(result);
  }

  @override
  Future<InventoryParseResult> parseInventory({
    required String venueId,
    required String pastedText,
  }) async {
    final result = await _invoke(task: 'inventory_parse', venueId: venueId, input: pastedText);
    return InventoryParseResult.fromJson(result);
  }

  @override
  Future<SchedulingSuggestionResult> suggestScheduling({
    required String venueId,
    required String context,
  }) async {
    final result =
        await _invoke(task: 'scheduling_suggestion', venueId: venueId, input: context);
    return SchedulingSuggestionResult.fromJson(result);
  }

  @override
  Future<WranglerAskResult> askWrangler({
    required String venueId,
    required String question,
  }) async {
    final result = await _invoke(task: 'wrangler_ask', venueId: venueId, input: question);
    return WranglerAskResult.fromJson(result);
  }

  /// Shared call path for all four task types. Maps the Edge Function's error-code JSON
  /// bodies (see supabase/functions/ai-assistant/index.ts) to the app's [AppError] types so
  /// every screen gets a consistent, user-facing message rather than a raw exception.
  Future<Map<String, dynamic>> _invoke({
    required String task,
    required String venueId,
    required String input,
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
        throw const UnknownError('The AI assistant returned an unexpected response.');
      }
      final result = data['result'];
      if (result is! Map<String, dynamic>) {
        throw const UnknownError('The AI assistant returned an unexpected response.');
      }
      return result;
    } on FunctionException catch (error) {
      throw _mapFunctionException(error);
    } on AppError {
      rethrow;
    } catch (_) {
      throw const NetworkError();
    }
  }

  AppError _mapFunctionException(FunctionException error) {
    final details = error.details;
    final code = details is Map ? details['error'] as String? : null;

    return switch (code) {
      'venue_not_found_or_not_a_member' => const PermissionDeniedError(
          "You don't have access to AI features for this venue.",
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
      'invalid_or_expired_session' => const AuthError('Your session has expired. Please sign in again.'),
      _ => error.status >= 500
          ? const AiUnavailableError('The AI assistant is temporarily unavailable.')
          : const UnknownError('The AI assistant could not process that request.'),
    };
  }
}

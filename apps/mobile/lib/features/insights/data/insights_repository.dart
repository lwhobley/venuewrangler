import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/errors/app_error.dart';
import '../../ai/data/ai_repository.dart';
import '../domain/shift_insight.dart';

abstract interface class InsightsRepository {
  Future<List<ShiftInsight>> getInsights({
    required String venueId,
    String? shiftId,
    int limit = 20,
  });

  Future<ShiftInsight> saveInsight({
    required String venueId,
    String? shiftId,
    required ShiftInsightKind kind,
    required String title,
    required String body,
  });

  Future<List<ShiftInsight>> generateAndSaveShiftInsights({
    required String venueId,
    String? shiftId,
    required String shiftContext,
  });

  Future<void> deleteInsight({required String insightId});
}

class SupabaseInsightsRepository implements InsightsRepository {
  const SupabaseInsightsRepository({
    required SupabaseClient client,
    required AiRepository aiRepository,
  })  : _client = client,
        _aiRepository = aiRepository;

  final SupabaseClient _client;
  final AiRepository _aiRepository;

  @override
  Future<List<ShiftInsight>> getInsights({
    required String venueId,
    String? shiftId,
    int limit = 20,
  }) async {
    try {
      var query = _client
          .from('shift_insights')
          .select()
          .eq('venue_id', venueId);

      if (shiftId != null) {
        query = query.eq('shift_id', shiftId);
      }

      final rows = await query.order('created_at', ascending: false).limit(limit);
      return (rows as List<dynamic>)
          .map((row) => ShiftInsight.fromJson(row as Map<String, dynamic>))
          .toList(growable: false);
    } on PostgrestException catch (e) {
      throw _mapPostgrestException(e);
    } catch (_) {
      throw const NetworkError();
    }
  }

  @override
  Future<ShiftInsight> saveInsight({
    required String venueId,
    String? shiftId,
    required ShiftInsightKind kind,
    required String title,
    required String body,
  }) async {
    try {
      final row = await _client
          .from('shift_insights')
          .insert({
            'venue_id': venueId,
            if (shiftId != null) 'shift_id': shiftId,
            'kind': kind.toDb(),
            'title': title,
            'body': body,
          })
          .select()
          .single();

      return ShiftInsight.fromJson(row);
    } on PostgrestException catch (e) {
      throw _mapPostgrestException(e);
    } catch (_) {
      throw const NetworkError();
    }
  }

  @override
  Future<List<ShiftInsight>> generateAndSaveShiftInsights({
    required String venueId,
    String? shiftId,
    required String shiftContext,
  }) async {
    final aiResult = await _aiRepository.generateShiftInsights(
      venueId: venueId,
      context: shiftContext,
    );

    final saved = <ShiftInsight>[];
    for (final item in aiResult.insights) {
      final insight = await saveInsight(
        venueId: venueId,
        shiftId: shiftId,
        kind: ShiftInsightKind.fromDb(item.kind),
        title: item.title,
        body: item.body,
      );
      saved.add(insight);
    }
    return saved;
  }

  @override
  Future<void> deleteInsight({required String insightId}) async {
    try {
      await _client.from('shift_insights').delete().eq('id', insightId);
    } on PostgrestException catch (e) {
      throw _mapPostgrestException(e);
    } catch (_) {
      throw const NetworkError();
    }
  }

  AppError _mapPostgrestException(PostgrestException e) {
    if (e.code == '42501') {
      return const PermissionDeniedError(
        "You don't have permission to perform this insight action.",
      );
    }
    return UnknownError(e.message);
  }
}

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/supabase_providers.dart';
import '../../ai/application/ai_providers.dart';
import '../data/insights_repository.dart';
import '../domain/shift_insight.dart';

final insightsRepositoryProvider = Provider<InsightsRepository>((ref) {
  final client = ref.watch(supabaseClientProvider);
  final aiRepo = ref.watch(aiRepositoryProvider);
  return SupabaseInsightsRepository(client: client, aiRepository: aiRepo);
});

final shiftInsightsForVenueProvider = FutureProvider.autoDispose
    .family<List<ShiftInsight>, String>((ref, venueId) {
  return ref.watch(insightsRepositoryProvider).getInsights(venueId: venueId);
});

final shiftInsightsForShiftProvider = FutureProvider.autoDispose
    .family<List<ShiftInsight>, ({String venueId, String shiftId})>((ref, params) {
  return ref.watch(insightsRepositoryProvider).getInsights(
        venueId: params.venueId,
        shiftId: params.shiftId,
      );
});

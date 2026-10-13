import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/supabase_providers.dart';
import '../../floor/application/floor_providers.dart';
import '../../floor/domain/floor_plan.dart';
import '../data/floor_studio_repository.dart';
import '../domain/floor_studio.dart';

final floorStudioRepositoryProvider = Provider<FloorStudioRepository>((ref) {
  final client = ref.watch(supabaseClientProvider);
  return SupabaseFloorStudioRepository(client);
});

final floorStudioLayoutsProvider = FutureProvider.autoDispose
    .family<List<FloorStudioLayout>, String>((ref, venueId) {
  return ref.watch(floorStudioRepositoryProvider).getLayouts(venueId: venueId);
});

final beoReservationPartySizeProvider =
    FutureProvider.autoDispose.family<int?, String>((ref, beoId) {
  return ref
      .watch(floorStudioRepositoryProvider)
      .reservationPartySizeForBeo(beoId: beoId);
});

/// Floor plans for a specific venue (a banquet order's venue may not be the active one).
final venueFloorPlansProvider =
    FutureProvider.autoDispose.family<List<FloorPlan>, String>((ref, venueId) {
  return ref.watch(floorRepositoryProvider).getFloorPlans(venueId: venueId);
});

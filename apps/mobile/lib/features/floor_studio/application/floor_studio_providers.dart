import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/supabase_providers.dart';
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

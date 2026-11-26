import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/network/supabase_providers.dart';
import '../../venues/application/venues_providers.dart';
import '../data/floor_repository.dart';
import '../domain/floor_permissions.dart';
import '../domain/floor_plan.dart';
import '../domain/floor_table.dart';

final floorRepositoryProvider = Provider<FloorRepository>((ref) {
  final client = ref.watch(supabaseClientProvider);
  return SupabaseFloorRepository(client);
});

/// Whether the signed-in user may merge or split tables at the active venue (supervisor and
/// above). False while the role is loading or unknown.
final canMergeFloorTablesProvider = Provider.autoDispose<bool>(
  (ref) => canMergeOrSplitTables(ref.watch(myVenueRoleProvider).valueOrNull),
);

final floorPlansProvider =
    FutureProvider.autoDispose<List<FloorPlan>>((ref) async {
  final activeVenue = ref.watch(activeVenueProvider);
  if (activeVenue == null) return [];

  final repo = ref.watch(floorRepositoryProvider);
  return repo.getFloorPlans(venueId: activeVenue.id);
});

final selectedFloorPlanIdProvider =
    StateProvider.autoDispose<String?>((ref) => null);

final floorTablesStreamProvider =
    StreamProvider.autoDispose<List<FloorTable>>((ref) {
  final activeVenue = ref.watch(activeVenueProvider);
  if (activeVenue == null) return Stream.value([]);

  final repo = ref.watch(floorRepositoryProvider);
  return repo.streamFloorTables(venueId: activeVenue.id);
});

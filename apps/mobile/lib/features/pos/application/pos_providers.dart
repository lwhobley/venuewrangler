import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/network/supabase_providers.dart';
import '../../venues/application/venues_providers.dart';
import '../data/pos_repository.dart';
import '../domain/pos_check.dart';
import '../domain/pos_connection.dart';

final posRepositoryProvider = Provider<PosRepository>((ref) {
  final client = ref.watch(supabaseClientProvider);
  return SupabasePosRepository(client);
});

final posConnectionsProvider =
    FutureProvider.autoDispose<List<PosConnection>>((ref) async {
  final activeVenue = ref.watch(activeVenueProvider);
  if (activeVenue == null) return [];

  final repo = ref.watch(posRepositoryProvider);
  return repo.getConnections(venueId: activeVenue.id);
});

final recentPosChecksProvider =
    FutureProvider.autoDispose<List<PosCheck>>((ref) async {
  final activeVenue = ref.watch(activeVenueProvider);
  if (activeVenue == null) return [];

  final repo = ref.watch(posRepositoryProvider);
  return repo.getRecentChecks(venueId: activeVenue.id);
});

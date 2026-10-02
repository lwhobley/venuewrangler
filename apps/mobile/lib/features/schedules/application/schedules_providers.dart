import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/supabase_providers.dart';
import '../data/schedules_repository.dart';
import '../domain/shift.dart';

final schedulesRepositoryProvider = Provider<SchedulesRepository>((ref) {
  final client = ref.watch(supabaseClientProvider);
  return SupabaseSchedulesRepository(client);
});

final shiftsForVenueProvider =
    FutureProvider.autoDispose.family<List<Shift>, String>((ref, venueId) {
  return ref.watch(schedulesRepositoryProvider).fetchShiftsForVenue(venueId);
});

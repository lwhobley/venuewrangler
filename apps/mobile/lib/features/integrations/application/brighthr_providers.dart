import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/supabase_providers.dart';
import '../data/brighthr_repository.dart';
import '../domain/brighthr_models.dart';

final brightHrRepositoryProvider = Provider<BrightHrRepository>((ref) {
  return SupabaseBrightHrRepository(ref.watch(supabaseClientProvider));
});

final brightHrConnectionProvider = FutureProvider.autoDispose
    .family<BrightHrConnection?, String>((ref, venueId) {
  return ref.watch(brightHrRepositoryProvider).fetchConnection(venueId);
});

final brightHrEmployeesProvider = FutureProvider.autoDispose
    .family<List<BrightHrEmployee>, String>((ref, connectionId) {
  return ref.watch(brightHrRepositoryProvider).fetchEmployees(connectionId);
});

final brightHrAbsencesProvider = FutureProvider.autoDispose
    .family<List<BrightHrAbsence>, String>((ref, connectionId) {
  return ref
      .watch(brightHrRepositoryProvider)
      .fetchUpcomingAbsences(connectionId);
});

final brightHrClockingsProvider = FutureProvider.autoDispose
    .family<List<BrightHrClocking>, String>((ref, connectionId) {
  return ref
      .watch(brightHrRepositoryProvider)
      .fetchRecentClockings(connectionId);
});

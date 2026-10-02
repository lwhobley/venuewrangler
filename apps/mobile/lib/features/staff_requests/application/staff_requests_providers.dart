import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/supabase_providers.dart';
import '../data/staff_requests_repository.dart';
import '../domain/staff_request.dart';

final staffRequestsRepositoryProvider = Provider<StaffRequestsRepository>((ref) {
  final client = ref.watch(supabaseClientProvider);
  return SupabaseStaffRequestsRepository(client);
});

final staffRequestsForVenueProvider = FutureProvider.autoDispose
    .family<List<StaffRequest>, String>((ref, venueId) {
  return ref.watch(staffRequestsRepositoryProvider).fetchRequestsForVenue(venueId);
});

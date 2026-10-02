import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/supabase_providers.dart';
import '../data/workforce_repository.dart';
import '../domain/workforce_models.dart';

final workforceRepositoryProvider = Provider<WorkforceRepository>((ref) {
  final client = ref.watch(supabaseClientProvider);
  return SupabaseWorkforceRepository(client);
});

final rosterForVenueProvider =
    FutureProvider.autoDispose.family<List<RosterMember>, String>((ref, venueId) {
  return ref.watch(workforceRepositoryProvider).fetchRosterForVenue(venueId);
});

final invitesForVenueProvider =
    FutureProvider.autoDispose.family<List<Invite>, String>((ref, venueId) {
  return ref.watch(workforceRepositoryProvider).fetchInvitesForVenue(venueId);
});

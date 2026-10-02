import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/supabase_providers.dart';
import '../data/events_repository.dart';
import '../domain/event.dart';

final eventsRepositoryProvider = Provider<EventsRepository>((ref) {
  final client = ref.watch(supabaseClientProvider);
  return SupabaseEventsRepository(client);
});

final eventsForVenueProvider =
    FutureProvider.autoDispose.family<List<VenueEvent>, String>((ref, venueId) {
  return ref.watch(eventsRepositoryProvider).fetchEventsForVenue(venueId);
});

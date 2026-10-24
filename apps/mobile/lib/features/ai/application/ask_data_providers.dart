import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/supabase_providers.dart';
import '../../venues/application/venue_clock.dart';
import '../../venues/application/venues_providers.dart';
import '../data/ask_data_repository.dart';
import 'ai_providers.dart';
import 'ask_data_service.dart';
import 'quick_numbers.dart';

final askDataRepositoryProvider = Provider<AskDataRepository>(
  (ref) => SupabaseAskDataRepository(ref.watch(supabaseClientProvider)),
);

final askDataServiceProvider = Provider<AskDataService>(
  (ref) => AskDataService(
    ai: ref.watch(aiRepositoryProvider),
    data: ref.watch(askDataRepositoryProvider),
  ),
);

/// The non-AI quick figures for the active venue; reloaded by invalidating the provider.
final quickNumbersProvider = FutureProvider.autoDispose<List<QuickNumber>>((
  ref,
) async {
  final venue = ref.watch(activeVenueProvider);
  if (venue == null) return const [];
  final today = ref.read(venueClockProvider).now;
  return QuickNumbers.load(
    data: ref.watch(askDataRepositoryProvider),
    venueId: venue.id,
    today: today,
  );
});

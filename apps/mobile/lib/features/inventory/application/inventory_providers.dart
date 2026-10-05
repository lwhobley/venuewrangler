import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/supabase_providers.dart';
import '../data/inventory_repository.dart';
import '../domain/inventory_item.dart';

final inventoryRepositoryProvider = Provider<InventoryRepository>((ref) {
  final client = ref.watch(supabaseClientProvider);
  return SupabaseInventoryRepository(client);
});

final inventoryForVenueProvider = FutureProvider.autoDispose
    .family<List<InventoryItem>, String>((ref, venueId) {
  return ref.watch(inventoryRepositoryProvider).fetchItemsForVenue(venueId);
});

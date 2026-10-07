import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/supabase_providers.dart';
import '../data/inventory_repository.dart';
import '../domain/inventory_item.dart';
import '../domain/inventory_v2.dart';
import '../../../core/auth/auth_providers.dart';
import '../../venues/application/venues_providers.dart';

final inventoryRepositoryProvider = Provider<InventoryRepository>((ref) {
  final client = ref.watch(supabaseClientProvider);
  return SupabaseInventoryRepository(client);
});

typedef InventoryScope = ({String venueId, String organizationId});
final inventorySnapshotProvider = FutureProvider.autoDispose
    .family<InventorySnapshot, InventoryScope>((ref, scope) {
  ref.watch(currentUserIdProvider);
  return ref
      .watch(inventoryRepositoryProvider)
      .fetchSnapshot(scope.venueId, scope.organizationId);
});
final inventoryCountLinesProvider = FutureProvider.autoDispose
    .family<List<InventoryCountLine>, String>((ref, id) {
  ref.watch(currentUserIdProvider);
  return ref.watch(inventoryRepositoryProvider).fetchCountLines(id);
});
final inventoryItemHistoryProvider = FutureProvider.autoDispose
    .family<List<InventoryHistory>, String>((ref, id) {
  ref.watch(currentUserIdProvider);
  return ref.watch(inventoryRepositoryProvider).fetchItemHistory(id);
});

void refreshInventory(WidgetRef ref, InventoryScope scope) {
  ref.invalidate(inventorySnapshotProvider(scope));
  ref.invalidate(inventoryForVenueProvider(scope.venueId));
}

/// Recheck user/venue when a sheet is submitted after being open for a while.
void assertInventoryScope(WidgetRef ref, InventoryScope scope, String? userId) {
  if (ref.read(activeVenueProvider)?.id != scope.venueId ||
      ref.read(currentUserIdProvider) != userId) {
    throw StateError(
      'Your session or venue changed. Close this screen and try again.',
    );
  }
}

final inventoryForVenueProvider = FutureProvider.autoDispose
    .family<List<InventoryItem>, String>((ref, venueId) {
  return ref.watch(inventoryRepositoryProvider).fetchItemsForVenue(venueId);
});

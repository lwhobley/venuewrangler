# features/inventory

Bar/kitchen inventory, backed by `supabase/migrations/20261002110000_inventory_schema.sql`.

- `domain/inventory_item.dart` — `InventoryItem`.
- `data/inventory_repository.dart` — `InventoryRepository` interface + Supabase
  implementation: `fetchItemsForVenue`, `createItem`, `updateQuantity`, `deleteItem`.
- `application/inventory_providers.dart` — repository + items-for-venue provider.
- `presentation/inventory_list_screen.dart` — routed at `/inventory`: lists items for the
  active venue (every venue member can view; only a manager tier can add/edit/delete, per
  RLS), with a manual "Add item" dialog and a "Parse from paste" action that calls
  `AiRepository.parseInventory` and turns each parsed line into a one-tap add, prefilled.

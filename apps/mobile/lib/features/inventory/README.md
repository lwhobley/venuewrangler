# features/inventory

Restaurant Inventory V2, implemented within the existing `/inventory` route and active-venue architecture.

- `domain/inventory_item.dart` — the existing item model, extended with classification, size, count unit and active status.
- `domain/inventory_v2.dart` — location stock, taxonomy, counts, history, matching and exact decimal valuation.
- `data/inventory_repository.dart` — `InventoryRepository` interface + Supabase
  implementation. Metadata uses scoped tables; stock actions and count submissions use checked, transactional Supabase RPCs. Item removal archives instead of deleting history.
- `application/inventory_providers.dart` — session-aware snapshot, count-line and history providers; active-venue checks before form submission.
- `presentation/` — dashboard/browser/replenishment, item/location setup, inline counts, taxonomy/area management, action forms and human-reviewed AI receiving/count-sheet import.

- `presentation/inventory_reorder_screen.dart` + `domain/reorder_planner.dart` — "Suggest reorder"
  (managers): deterministic below-par list first, optional AI draft (`inventory_reorder`) with
  usage-jump flags, editable quantities, Dart-computed estimated total, copy as text. There is no
  purchase-order table, so nothing is saved or ordered.

Apply `supabase/migrations/20261007200621_restaurant_inventory_v2.sql` before releasing this client. It builds on `20261002175142_inventory_schema.sql`; legacy names, units, quantities, costs and venue ownership survive.

See `docs/inventory-v2.md` for the schema, permission matrix, tests, migration behavior and deployment order.

# Inventory recipes and unit conversions

Inventory managers can open **Recipes & unit conversions** from the Bar Stock screen.

1. Set each package conversion. For example, if the counted stock unit is a bottle containing 750 ml, set `Contains` to `750` and `Measure` to `ml`.
2. Add a recipe whose name matches the POS menu item name, then enter each ingredient quantity in recipe units. Supported measures include ml/L, US fl oz/tsp/tbsp/cup/pint/quart/gallon, g/mg/kg/oz weight/lb, and each.
3. Connect a POS webhook that sends menu item names and quantities. A paid check closed after the recipe was saved depletes matching ingredients; duplicate webhook deliveries do not apply the sale twice. Voiding the whole check restores the amount that was deducted. When a paid check is reinstated after a void, it uses its original recorded quantities.

Unmapped menu items do not change inventory. Saving or editing a recipe does not backfill earlier sales. Matching is by normalized exact name, so adjust the recipe name to match the POS name. Ingredient modifiers, recipe yields, prep loss, and line-item voids are not inferred. Review pack sizes and recipes before relying on forecasts. The ledger records theoretical recipe demand and the amount actually deducted separately when on-hand stock is insufficient.

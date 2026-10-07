# Restaurant Inventory V2

## Architecture inspected before implementation

The active application is Flutter in `apps/mobile`; the Inventory screen remains at `/inventory` in the existing GoRouter manager shell. Active venue selection comes from `features/venues/application/venues_providers.dart`. Inventory state uses Riverpod and the existing `InventoryRepository`/`SupabaseInventoryRepository` classes. No authentication, workspace, membership or navigation replacement was needed.

The original `20261002175142_inventory_schema.sql` defined one venue-scoped `inventory_items` table: name, nullable decimal quantity, unrestricted unit, nullable NUMERIC unit cost, derived organization and editor timestamps. Its RLS allows venue-member reads and manager/organization-admin writes using `app_hidden` membership helpers. Inventory text parsing already used `AiRepository.parseInventory` and the `ai-assistant` Edge Function. These are reused.

The interface reuses `AppTheme`, `OpsColors`, status chips, existing Material input/button styles, light/dark colors and role providers. The implementation sequence was additive schema/backfill, repository/models/providers, dashboard/item/area screens, inline counts, actions, reviewed AI imports, then database and Flutter verification.

## Completed workflows

- Overview: current known inventory value, active item count, below-par/out-of-stock locations, outstanding open-count rows and 30-day count variance. Coverage notes identify unknown quantities and missing prices.
- Browse: name search, Beverage/Food/Non-Food groups, area/sub-area, category/subcategory, stock status and optional inactive records.
- Item setup/detail: classification, optional size, standardized/custom count units, cost per count unit, supplier, notes, archive/reactivate, multi-location quantities, optional per-location par, recent immutable history.
- Organization taxonomy: 16 restaurant categories plus Uncategorized and all requested subcategories, seeded in Postgres for existing and future organizations. Owners/admins can add/rename/archive classifications. Venue managers configure their venue areas/sub-areas.
- Physical counts: optional area/category/subcategory filters, full or partial scope, large inline decimal fields, saved progress, completion confirmation, variance summaries and history. Full counts require every selected location; partial counts update only entered locations. Blank entries do not become zero.
- Receive, same-item transfer within a venue, waste with reasons, adjustment with reason and direct physical-count actions. Quantity changes and corresponding history are transactional. Retained operation IDs make retries safe against double application.
- Replenishment: below-par quantities, searchable/filterable, sorted by area, category or largest shortage. No automated purchasing.
- Import: paste text or upload UTF-8 TXT/CSV, parse with the existing AI service, display name-match confidence/ambiguity, choose or create items, correct metadata and location, explicitly verify then confirm each line. Parsing alone changes no inventory.

## Migration and data

New migration: `supabase/migrations/20261007200621_restaurant_inventory_v2.sql`.

| Structure | Purpose |
| --- | --- |
| `inventory_categories`, `inventory_subcategories` | Organization-scoped, configurable classification |
| Existing `inventory_items` | Extended master item metadata; quantity retained as a compatibility projection |
| `inventory_areas`, `inventory_sub_areas` | Venue-scoped physical locations |
| `inventory_stock` | One item/location/sub-location combination, quantity, par, version and timestamps |
| `inventory_counts`, `inventory_count_items` | Session scope/status and immutable completion snapshots/variance |
| `inventory_history` | Item/location snapshots, quantities, action, reason, notes, actor and time |
| Private `app_hidden.inventory_operations` | Operation identity and payload for retry protection |

Quantities/par/size are `NUMERIC(14,4)`; costs retain `NUMERIC(10,2)`. Database monetary calculations use NUMERIC. Flutter valuation uses fixed-scale BigInt arithmetic, with currency rounded only for display. No case/bottle conversion is inferred.

Legacy records retain their IDs, names, original unit text, costs and ownership. Uncategorized and a General Inventory location are added; the original quantity becomes that location's opening quantity. Recognized units map to selectable units; other text becomes a Custom count unit. Legacy negative quantities and NULL unknown balances survive. Unknown quantity/value is disclosed rather than fabricated. Migration opening history is explicitly labelled as a migration, not a physical count. New items start at zero in the default location.

The default category/area can be renamed; their stable system identity remains active. Stock uniqueness includes NULL sub-areas (`UNIQUE NULLS NOT DISTINCT`, PostgreSQL 15+). Parent/scope guards and composite foreign keys enforce category/subcategory and venue/area relationships. Size/count-unit changes with nonzero stock are rejected to prevent reinterpreting existing balances; create a separate product variant or explicitly correct the stock first.

The legacy master quantity is synchronized from all locations. Legacy quantity corrections are audited as adjustments. No existing table or data is dropped.

## Authorization and integrity

| Action | Authorization |
| --- | --- |
| Read stock/items/counts/history | Existing authorized venue members |
| Read taxonomy | Organization members |
| Create/edit item and venue locations | Venue manager, organization owner/admin |
| Configure organization taxonomy | Organization owner/admin |
| Change stock/par or save/complete/cancel counts | Checked RPC requiring manager or organization owner/admin for that venue |
| Edit/delete stock history directly | No authenticated-client write policy |

All new public tables enable and force RLS. Stock, count sessions, count rows and history are client read-only; security-definer RPCs check the authenticated user and venue role before changing them, with pinned empty search paths and restricted execution grants. Supplied organization IDs are derived/validated server-side. Private helpers/operation records are not client APIs. Legacy inventory-item RLS remains active. Ordinary item removal is an archive to preserve stock and audit history.

Mutations serialize by venue and lock stock rows. Completed counts reject any entered location whose quantity or counting-definition version changed since the session began; the manager must cancel and recount rather than overwrite intervening receipts/transfers or apply entries using an old size/unit. Completion is one transaction: previous quantity/cost snapshots, entered quantities, variance, stock, history, completing actor/time. Completed/cancelled retries cannot apply twice. Transfers reject another item, another venue, the same destination, unknown/inactive destinations or insufficient stock and write linked history on both sides.

## Files changed

- Extended existing inventory model, repository, providers and landing screen under `apps/mobile/lib/features/inventory/`.
- Added `domain/inventory_v2.dart` and presentation files `inventory_widgets.dart`, `inventory_item_screen.dart`, `inventory_admin_screen.dart`, `inventory_count_screen.dart`, `inventory_action_sheet.dart`, `inventory_import_screen.dart`.
- Extended `apps/mobile/lib/features/ai/domain/ai_models.dart` with optional size/classification suggestions and `supabase/functions/ai-assistant/prompts.ts` with the compatible parse schema and review instructions.
- Added three Flutter test files under `apps/mobile/test/features/inventory/`.
- Added `supabase/tests/database/inventory_v2.test.sql`, legacy fixtures under `supabase/tests/fixtures/` and `tool/test_inventory_v2_database.py`.
- Updated the inventory feature README and this guide.

## Verification commands

From `apps/mobile`:

```text
dart analyze --fatal-infos
flutter test --no-pub
flutter build web --release --no-pub -t lib/main_production.dart --dart-define=SUPABASE_URL=https://example.supabase.co --dart-define=SUPABASE_ANON_KEY=public-test-key
```

From the repository root, with a disposable loopback PostgreSQL server already running:

```text
python tool/test_inventory_v2_database.py --psql "C:/Program Files/PostgreSQL/18/bin/psql.exe" --port 55439
```

The runner creates and removes only a randomly named local test database. It replays all migrations using existing CI auth/storage stubs, seeds legacy inventory before V2, verifies eight preservation checks and runs self-contained TAP inventory/RLS assertions. Broad client grants deliberately verify that RLS still protects data. Fixtures are never production migrations. The TAP file is also discovered by existing Supabase CI `pg_prove` tests.

From `supabase/functions`, `deno check --frozen ai-assistant/index.ts` and `deno lint ai-assistant/prompts.ts` validate the changed parser surface.

### Verified locally on October 7, 2026

- Strict Dart analysis: no issues; repository formatting check: 229 files, no changes.
- Full Flutter regression suite: 199 tests passed, including 15 new inventory domain/repository/widget tests.
- Flutter web release compilation: succeeded with public test configuration; this artifact is not configured for production deployment.
- PostgreSQL 18 disposable database: all 61 migrations replayed, eight legacy preservation checks passed, 62 transaction/relationship/RLS assertions passed.
- Changed AI parser: Deno formatting, type check and lint passed. The existing shared-module test command discovered zero tests, so it is not counted as AI test coverage.
- `git diff --check`: passed.

Production Supabase behavior, the complete pre-existing pgTAP suite, real-device use and authenticated live AI parsing remain unverified by these local checks. Existing database CI will run its full test suite when these changes are submitted.

## Operational limits

- Counts and mutations require connectivity. Saved progress is server-side; unsaved entries prompt before leaving.
- Imports accept pasted text or UTF-8 TXT/CSV up to 2 MB. PDF/image OCR and spreadsheet extraction are not implemented. The existing AI service still requires its configured provider and billing entitlement.
- Match confidence is a deterministic name heuristic, not a calibrated product/size probability. Ambiguous same-name products require selection and all lines require human verification.
- Reviewed lines apply individually. A newly created item remains available if its receipt fails; stock/history writes remain atomic and can be retried. Reopening and reimporting an invoice is a new human-authorized operation.
- Latest 100 sessions are listed; item detail shows latest 100 history entries. Database history remains retained. Dashboard variance fetches all history from the last 30 days with pagination.
- Archived items/locations are excluded from active operational metrics/counts. Item detail totals retain stock in archived locations and identify these locations.
- No count schedules, conversions, barcode/SKU requirements, recipes, POS depletion, purchasing, accounting or asset management were added.

## Release steps (separate from implemented scope)

1. Review and apply the additive Supabase migration in the target project before deploying the new Flutter client. Local replay is not evidence of production application.
2. Deploy the updated `ai-assistant` function to receive richer size/category suggestions. The Flutter parser remains compatible with the old response shape.
3. Release the web/mobile app through existing deployment workflows, then smoke-test with an actual manager and staff account in separate venues: create/classify Tito's 1 L Bottle at $24.50, allocate two locations/par levels, count 4.5, receive 12, transfer 4, waste 0.5, inspect history and value. Repeat with chicken and containers.
4. Confirm production RLS/advisor results and migration opening balances before managers start counting. A rollback should retain the added data/history and use the compatibility projection; dropping the new tables after operations would discard audit information.

No production migration, Edge Function deployment or web/mobile release is performed by these local verification commands.

## Production backend release — 2026-10-07

- Applied Inventory V2 to Supabase project `puttwjwmwrzmhpsjykuj`, along with the five previously committed account-deletion, time-zone, venue-roster and subscription-state migrations that were missing in production.
- Verified all 39 legacy items retained their IDs, venue, names, quantities, units and costs using an unchanged pre/post migration fingerprint. Created 39 stock rows in the default General Inventory areas and 39 explicitly identified migration history entries; stock totals match every legacy quantity.
- All nine public inventory tables have enforced RLS. Authenticated clients cannot directly insert, update or delete stock, counts, count lines or history. Anonymous callers cannot execute the five inventory RPCs.
- Deployed all 14 repository Edge Functions, preserving the existing JWT verification settings and configuring the new account-deletion worker with its internal dispatch authentication. Its Edge Function secret and matching Vault configuration were provisioned without exposing their values. A dispatch probe for a nonexistent job returned the expected authenticated `job_not_found` response; no account was deleted for verification.
- The security advisor reports the intentionally guarded authenticated inventory RPCs and private service-only tables. Existing account/authentication and helper search-path warnings remain outside the inventory release; this is not a claim that the entire project's advisor report is clear.
- The web release uses the existing GitHub Actions Cloudflare Pages workflow and its production configuration. Authenticated manager/staff workflows, live AI invoice parsing and native-device use still require separate live verification. No iOS build is included in this release.

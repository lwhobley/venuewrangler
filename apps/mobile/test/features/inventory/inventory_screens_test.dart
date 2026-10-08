import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venuewrangler_mobile/core/auth/auth_providers.dart';
import 'package:venuewrangler_mobile/core/theme/app_theme.dart';
import 'package:venuewrangler_mobile/features/venues/application/venues_providers.dart';
import 'package:venuewrangler_mobile/features/venues/domain/venue.dart';
import 'package:venuewrangler_mobile/features/inventory/application/inventory_providers.dart';
import 'package:venuewrangler_mobile/features/inventory/data/inventory_repository.dart';
import 'package:venuewrangler_mobile/features/inventory/domain/inventory_item.dart';
import 'package:venuewrangler_mobile/features/inventory/domain/inventory_v2.dart';
import 'package:venuewrangler_mobile/features/inventory/presentation/inventory_list_screen.dart';
import 'package:venuewrangler_mobile/features/inventory/presentation/inventory_count_screen.dart';
import 'package:venuewrangler_mobile/features/inventory/presentation/inventory_import_screen.dart';
import 'package:venuewrangler_mobile/features/ai/application/ai_providers.dart';
import 'package:venuewrangler_mobile/features/ai/data/ai_repository.dart';
import 'package:venuewrangler_mobile/features/ai/domain/ai_models.dart';

const scope = (venueId: 'venue', organizationId: 'org');
final count = InventoryCount.fromJson({
  'id': 'count',
  'status': 'in_progress',
  'count_type': 'partial',
  'started_at': '2026-10-07T12:00:00Z',
});
final snapshot = InventorySnapshot(
  items: [
    InventoryItem(
      id: 'vodka',
      venueId: 'venue',
      name: 'Tito’s Vodka',
      unitCostUsd: 24.50,
      updatedAt: DateTime(2026),
      categoryId: 'liquor',
      countUnit: 'Bottle',
    ),
  ],
  categories: [
    InventoryCategory.fromJson(
      {'id': 'liquor', 'name': 'Liquor', 'inventory_group': 'Beverage'},
    ),
  ],
  subcategories: [],
  areas: [
    InventoryArea.fromJson({'id': 'bar', 'name': 'Main Bar'}),
  ],
  subAreas: [],
  stock: [
    InventoryStock.fromJson({
      'id': 'stock',
      'inventory_item_id': 'vodka',
      'area_id': 'bar',
      'quantity': 3.5,
      'par_level': 8,
    }),
  ],
  counts: [count],
  history: [],
  outstandingCountRows: 2,
);

class InventoryTestRepository extends Fake implements InventoryRepository {
  List<Map<String, dynamic>>? saved;
  bool completed = false, cancelled = false;
  @override
  Future<InventorySnapshot> fetchSnapshot(
    String venueId,
    String organizationId,
  ) async =>
      snapshot;
  @override
  Future<List<InventoryItem>> fetchItemsForVenue(String venueId) async =>
      snapshot.items;
  @override
  Future<List<InventoryCountLine>> fetchCountLines(String countId) async => [
        InventoryCountLine.fromJson({
          'id': 'line1',
          'item_name': 'Tito’s Vodka',
          'location_name': 'Main Bar',
          'count_unit': 'Bottle',
          'previous_quantity': 6.5,
          'unit_cost_snapshot': 24.5,
          'counted_quantity': completed ? 4.5 : null,
          'variance_quantity': completed ? -2 : null,
          'variance_value': completed ? -49 : null,
        }),
        InventoryCountLine.fromJson({
          'id': 'line2',
          'item_name': 'Chicken Breast',
          'location_name': 'Kitchen',
          'count_unit': 'Pound',
          'previous_quantity': 14.25,
          'unit_cost_snapshot': 3.2,
        }),
      ];
  @override
  Future<void> saveCount(
    String countId,
    List<Map<String, dynamic>> values, {
    bool complete = false,
    bool cancel = false,
  }) async {
    saved = values;
    completed = complete;
    cancelled = cancel;
  }
}

class InventoryTestAi extends Fake implements AiRepository {
  @override
  Future<InventoryParseResult> parseInventory({
    required String venueId,
    required String pastedText,
  }) async {
    expect(venueId, 'venue');
    return const InventoryParseResult([
      InventoryLineItem(
        name: 'Tito’s Vodka',
        quantity: 12,
        unit: 'Bottle',
        unitCostUsd: 24.5,
        sizeAmount: 1,
        sizeUnit: 'L',
      ),
    ]);
  }
}

Widget app(
  Widget child,
  InventoryTestRepository repo, {
  bool manager = true,
  bool dark = false,
}) =>
    ProviderScope(
      overrides: [
        inventoryRepositoryProvider.overrideWithValue(repo),
        aiRepositoryProvider.overrideWithValue(InventoryTestAi()),
        currentUserIdProvider.overrideWithValue('manager'),
        activeVenueProvider.overrideWith(
          (ref) => Venue(
            id: 'venue',
            organizationId: 'org',
            name: 'Restaurant',
            createdAt: DateTime(2026),
          ),
        ),
        canManageActiveVenueProvider.overrideWith((ref) async => manager),
      ],
      child: MaterialApp(
        theme: dark ? AppTheme.dark() : AppTheme.light(),
        home: child,
      ),
    );

void main() {
  testWidgets('tablet dark theme dashboard and count layout remain usable',
      (tester) async {
    tester.view.physicalSize = const Size(1024, 1366);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repo = InventoryTestRepository();
    await tester.pumpWidget(app(const InventoryListScreen(), repo, dark: true));
    await tester.pumpAndSettle();
    expect(find.text('Inventory value'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(
      app(
        InventoryCountScreen(scope: scope, count: count),
        repo,
        dark: true,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });
  testWidgets(
      'AI parse creates review suggestions and cannot automatically change stock',
      (tester) async {
    final repo = InventoryTestRepository();
    await tester
        .pumpWidget(app(const InventoryImportScreen(scope: scope), repo));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextField).first,
      r'Tito’s Vodka 1 L 12 bottles $24.50',
    );
    await tester.tap(find.text('Parse for review'));
    await tester.pumpAndSettle();
    expect(find.textContaining('100% name confidence'), findsOneWidget);
    expect(find.text('Review'), findsOneWidget);
    expect(repo.saved, isNull);
    // Fake throws for any unimplemented write method: parsing only uses AI and reads.
    expect(tester.takeException(), isNull);
  });
  testWidgets(
      'dashboard shows value, outstanding counts and below-par attention on mobile',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      app(const InventoryListScreen(), InventoryTestRepository()),
    );
    await tester.pumpAndSettle();
    expect(find.text('Inventory Hub'), findsOneWidget);
    expect(find.text('\$85.75'), findsOneWidget);
    expect(find.text('Not counted'), findsOneWidget);
    expect(find.text('1 stock locations are below par'), findsOneWidget);
    expect(find.text('Start count'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('staff dashboard has no write entry points', (tester) async {
    await tester.pumpWidget(
      app(
        const InventoryListScreen(),
        InventoryTestRepository(),
        manager: false,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Start count'), findsNothing);
    expect(find.text('Receive'), findsNothing);
    expect(find.byTooltip('Review invoice or count sheet'), findsNothing);
  });
  testWidgets(
      'count enters decimals inline and partial completion preserves blank rows',
      (tester) async {
    final repo = InventoryTestRepository();
    await tester.pumpWidget(
      app(InventoryCountScreen(scope: scope, count: count), repo),
    );
    await tester.pumpAndSettle();
    expect(find.text('0 / 2 counted'), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, '4.5');
    await tester.pump();
    expect(find.text('1 / 2 counted'), findsOneWidget);
    await tester.tap(find.text('Complete count'));
    await tester.pumpAndSettle();
    expect(
      repo.saved,
      isNull,
    ); // confirmation is required before any inventory mutation
    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();
    expect(repo.saved, [
      {'id': 'line1', 'quantity': '4.5'},
    ]);
    expect(repo.completed, true);
    expect(find.text('Known variance value: -\$49.00'), findsOneWidget);
    expect(find.text('Not counted • stock unchanged'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('invalid count input stays visible without calling repository',
      (tester) async {
    final repo = InventoryTestRepository();
    await tester.pumpWidget(
      app(InventoryCountScreen(scope: scope, count: count), repo),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '-1');
    await tester.tap(find.text('Save progress'));
    await tester.pumpAndSettle();
    expect(repo.saved, isNull);
    expect(
      find.text('Tito’s Vodka: Use zero or a positive number'),
      findsOneWidget,
    );
  });
}

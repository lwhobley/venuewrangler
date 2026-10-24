import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venuewrangler_mobile/core/auth/auth_providers.dart';
import 'package:venuewrangler_mobile/core/errors/app_error.dart';
import 'package:venuewrangler_mobile/features/ai/application/ai_providers.dart';
import 'package:venuewrangler_mobile/features/ai/data/ai_repository.dart';
import 'package:venuewrangler_mobile/features/ai/domain/ai_models.dart';
import 'package:venuewrangler_mobile/features/inventory/application/inventory_providers.dart';
import 'package:venuewrangler_mobile/features/inventory/domain/inventory_item.dart';
import 'package:venuewrangler_mobile/features/inventory/domain/inventory_v2.dart';
import 'package:venuewrangler_mobile/features/inventory/domain/reorder_planner.dart';
import 'package:venuewrangler_mobile/features/inventory/presentation/inventory_list_screen.dart';
import 'package:venuewrangler_mobile/features/inventory/presentation/inventory_reorder_screen.dart';
import 'package:venuewrangler_mobile/features/venues/application/venues_providers.dart';
import 'package:venuewrangler_mobile/features/venues/domain/venue.dart';

const _scope = (venueId: 'venue', organizationId: 'org');
final _now = DateTime.now();

String _daysAgo(int days) =>
    _now.toUtc().subtract(Duration(days: days)).toIso8601String();

InventoryItem _item(
  String id,
  String name, {
  num? cost,
  String? supplier,
  bool active = true,
  String unit = 'Bottle',
  String? notes,
}) =>
    InventoryItem(
      id: id,
      venueId: 'venue',
      name: name,
      unitCostUsd: cost,
      supplier: supplier,
      notes: notes,
      active: active,
      countUnit: unit,
      updatedAt: DateTime(2026),
    );

InventoryStock _stock(String item, num? quantity, num? par, {String? id}) =>
    InventoryStock.fromJson({
      'id': id ?? 'st-$item',
      'inventory_item_id': item,
      'area_id': 'bar',
      'quantity': quantity,
      'par_level': par,
    });

InventoryHistory _history(
  String item,
  String action,
  num change,
  int daysAgo,
) =>
    InventoryHistory.fromJson({
      'id': 'h-$item-$action-$daysAgo-$change',
      'inventory_item_id': item,
      'item_name': item,
      'location_name': 'Main Bar',
      'count_unit': 'Bottle',
      'action_type': action,
      'quantity_change': change.toString(),
      'created_at': _daysAgo(daysAgo),
    });

InventorySnapshot _snapshot({List<InventoryHistory>? history}) =>
    InventorySnapshot(
      items: [
        _item(
          'vodka',
          'Tito’s Vodka',
          cost: 24.5,
          supplier: 'Acme Spirits',
          notes: 'ask Dana about the secret price',
        ),
        _item('gin', 'Gin', unit: 'Case'),
        _item('lime', 'Limes', unit: 'Each', cost: 0.5),
        _item('bitters', 'Bitters'),
        _item('old', 'Retired rum', active: false),
      ],
      categories: const [],
      subcategories: const [],
      areas: [
        InventoryArea.fromJson({'id': 'bar', 'name': 'Main Bar'}),
      ],
      subAreas: const [],
      stock: [
        _stock('vodka', 3.5, 8),
        _stock('gin', 1, 4),
        _stock('lime', 20, 10),
        _stock('bitters', 0, null),
        _stock('old', 0, 5),
      ],
      counts: const [],
      history: history ??
          [
            _history('vodka', 'COUNT', -6, 5),
            _history('vodka', 'COUNT', -3, 20),
            _history('vodka', 'RECEIVE', 12, 3),
            _history('vodka', 'TRANSFER_OUT', -9, 2),
          ],
    );

void main() {
  group('gathering', () {
    final items = reorderItemsFromSnapshot(_snapshot(), now: _now);

    test('active items get short keys, ordered by shortfall', () {
      expect(items.map((i) => i.item.id), ['vodka', 'gin', 'bitters', 'lime']);
      expect(items.map((i) => i.key), ['item_1', 'item_2', 'item_3', 'item_4']);
      final vodka = items.first;
      expect(inventoryQuantity(vodka.onHand), '3.5');
      expect(inventoryQuantity(vodka.par!), '8');
      expect(inventoryQuantity(vodka.shortfall), '4.5');
      expect(items[2].hasPar, isFalse);
      expect(itemsWithoutPar(items), 1);
    });

    test('usage counts decreases only, split into two windows', () {
      final vodka = items.first;
      expect(inventoryQuantity(vodka.usedRecent), '6');
      expect(inventoryQuantity(vodka.usedPrior), '3');
      // Receipts are separate, and a transfer is neither use nor receipt.
      expect(inventoryQuantity(vodka.receivedRecent), '12');
    });

    test('a jump in use is flagged deterministically', () {
      final vodka = items.first;
      expect(vodka.usageRatio, closeTo(2.29, 0.01));
      expect(vodka.varianceNote, contains('2.3x'));
      expect(items[1].varianceNote, isNull);
    });

    test('the below-par fallback needs no AI and covers the shortfall', () {
      final lines = belowParLines(items);
      expect(lines.map((l) => l.item.item.id), ['vodka', 'gin']);
      expect(lines.first.quantity, '4.5');
      expect(lines.first.reason, contains('3.5 on hand'));
      expect(lines.first.flag, isNotNull);
      expect(lines.first.source, ReorderSource.belowPar);
    });

    test('the request carries short keys and figures, not ids or notes', () {
      final input = buildReorderInput(items, today: DateTime(2026, 10, 24));
      final json = jsonDecode(input.text) as Map<String, dynamic>;
      final sent = (json['items'] as List).cast<Map<String, dynamic>>();
      // Limes are comfortably stocked and unused, so they are left out.
      expect(sent.map((r) => r['key']), ['item_1', 'item_2', 'item_3']);
      expect(sent.first['supplier'], 'Acme Spirits');
      expect(sent.first['unit_cost_usd'], 24.5);
      expect(sent.first['shortfall_to_par'], 4.5);
      expect(sent.first['used_recent'], 6);
      expect(input.sentKeys, {'item_1', 'item_2', 'item_3'});
      expect(input.text, isNot(contains('vodka')));
      expect(input.text, isNot(contains('st-')));
      expect(input.text, isNot(contains('secret price')));
      expect(input.text.length, lessThan(reorderMaxInputChars));
    });

    test('a very large catalogue is cut to fit and says how many were left',
        () {
      final many = InventorySnapshot(
        items: [
          for (var i = 0; i < 400; i++) _item('i$i', 'Item number $i ' * 3),
        ],
        categories: const [],
        subcategories: const [],
        areas: [
          InventoryArea.fromJson({'id': 'bar', 'name': 'Main Bar'}),
        ],
        subAreas: const [],
        stock: [for (var i = 0; i < 400; i++) _stock('i$i', 0, 5)],
        counts: const [],
        history: const [],
      );
      final input = buildReorderInput(
        reorderItemsFromSnapshot(many, now: _now),
        today: _now,
      );
      expect(input.text.length, lessThanOrEqualTo(reorderMaxInputChars));
      expect(input.omitted, greaterThan(0));
      expect(input.tooLarge, isFalse);
    });
  });

  group('reading the answer', () {
    final items = reorderItemsFromSnapshot(_snapshot(), now: _now);
    final keys = {'item_1', 'item_2', 'item_3'};

    test('unknown, repeated and non-positive rows are dropped', () {
      final draft = buildReorderDraft(
        InventoryReorderResult.fromJson({
          'orders': [
            {'item_key': 'item_1', 'suggested_quantity': 5, 'reason': 'Low'},
            {'item_key': 'item_1', 'suggested_quantity': 9},
            {'item_key': 'item_77', 'suggested_quantity': 1},
            {'item_key': 'item_4', 'suggested_quantity': 4},
            {'item_key': 'item_2', 'suggested_quantity': -2},
            {'item_key': 'item_3', 'suggested_quantity': 'lots'},
            {'item_key': 'item_2', 'suggested_quantity': '3'},
            'noise',
          ],
        }),
        items,
        sentKeys: keys,
      );
      // item_4 was never sent, so it is as unknown as item_77.
      expect(draft.lines.map((l) => l.item.key), ['item_1', 'item_2']);
      expect(draft.lines.first.quantity, '5');
      expect(draft.lines.last.quantity, '3');
      expect(draft.dropped, 5);
    });

    test('quantities are clamped and tolerate odd types', () {
      final result = InventoryReorderResult.fromJson({
        'orders': [
          {'item_key': 'item_1', 'suggested_quantity': 1e12},
          {'item_key': 'item_2', 'suggested_quantity': double.infinity},
          {'item_key': 'item_3'},
        ],
        'variance_flags': 'not a list',
      });
      expect(
        result.orders.first.suggestedQuantity,
        ReorderSuggestion.maxQuantity,
      );
      expect(result.orders[1].suggestedQuantity, isNull);
      expect(result.orders.last.suggestedQuantity, isNull);
      expect(result.varianceFlags, isEmpty);
      expect(InventoryReorderResult.fromJson(const {}).orders, isEmpty);
    });

    test('variance flags merge the assistant with the deterministic check', () {
      final draft = buildReorderDraft(
        InventoryReorderResult.fromJson({
          'orders': [
            {'item_key': 'item_2', 'suggested_quantity': 3},
          ],
          'variance_flags': [
            {'item_key': 'item_2', 'note': 'Count looks off'},
            {'item_key': 'item_99', 'note': 'ghost'},
          ],
        }),
        items,
        sentKeys: keys,
      );
      final byName = {for (final f in draft.flags) f.item.item.id: f};
      expect(byName['gin']!.note, 'Count looks off');
      expect(byName['gin']!.fromAi, isTrue);
      expect(byName['vodka']!.fromAi, isFalse);
      expect(draft.flags, hasLength(2));
    });

    test('totals come from unit costs, never from the answer', () {
      final draft = buildReorderDraft(
        InventoryReorderResult.fromJson({
          'estimated_total_usd': 1,
          'orders': [
            {
              'item_key': 'item_1',
              'suggested_quantity': 5,
              'unit_cost_usd': 0.01,
            },
            {'item_key': 'item_2', 'suggested_quantity': 3},
          ],
        }),
        items,
        sentKeys: keys,
      );
      final total = reorderTotal(draft.lines);
      expect(inventoryMoney(total.total), '\$122.50');
      expect(total.unpriced, 1);
      // An edit that is not a number is excluded rather than guessed.
      final edited = draft.lines.first.withQuantity('abc');
      expect(edited.parsedQuantity, isNull);
      expect(reorderTotal([edited]).unpriced, 1);
      expect(draft.lines.first.withQuantity('2.5').cost, isNotNull);
      expect(draft.lines.first.withQuantity('-1').parsedQuantity, isNull);
    });

    test('the text copy groups by supplier and states the total', () {
      final lines = [
        ReorderLine(
          item: items[0],
          quantity: '5',
          reason: '',
          source: ReorderSource.ai,
        ),
        ReorderLine(
          item: items[1],
          quantity: '3',
          reason: '',
          source: ReorderSource.ai,
        ),
        ReorderLine(
          item: items[2],
          quantity: '0',
          reason: '',
          source: ReorderSource.ai,
        ),
      ];
      final text = reorderAsText(
        lines,
        venueName: 'Venue',
        today: DateTime(2026, 10, 24),
      );
      expect(text, contains('Reorder list - Venue - 2026-10-24'));
      expect(
        text,
        contains('Acme Spirits\n- Tito’s Vodka: 5 Bottle (\$122.50)'),
      );
      expect(text, contains('No supplier set\n- Gin: 3 Case'));
      expect(text, isNot(contains('Bitters')));
      expect(text, contains('Estimated total: \$122.50'));
      expect(text, contains('1 line has no unit cost'));
    });
  });

  group('reorder screen', () {
    testWidgets('opens on the below-par list without calling the assistant',
        (tester) async {
      final ai = _Ai(const InventoryReorderResult(orders: []));
      await _pump(tester, ai);
      expect(find.text('Order list'), findsOneWidget);
      expect(find.text('Tito’s Vodka'), findsOneWidget);
      expect(find.text('Gin'), findsOneWidget);
      expect(find.text('Limes'), findsNothing);
      expect(find.text('Estimated total \$110.25'), findsOneWidget);
      expect(find.textContaining('1 item has no par level'), findsOneWidget);
      expect(ai.lastInput, isNull);
    });

    testWidgets('AI draft replaces the list; edits update the computed total',
        (tester) async {
      final ai = _Ai(
        InventoryReorderResult.fromJson({
          'orders': [
            {
              'item_key': 'item_1',
              'suggested_quantity': 5,
              'reason': 'Heavy use lately',
            },
            {'item_key': 'item_2', 'suggested_quantity': 3, 'reason': 'Out'},
            {'item_key': 'item_9', 'suggested_quantity': 3},
          ],
          'variance_flags': [
            {'item_key': 'item_2', 'note': 'Use jumped 4x'},
          ],
        }),
      );
      await _pump(tester, ai);
      await tester.tap(find.text('Suggest with AI'));
      await tester.pumpAndSettle();

      expect(ai.lastInput, contains('item_1'));
      expect(ai.lastInput, isNot(contains('"vodka"')));
      expect(find.textContaining('AI draft.'), findsOneWidget);
      expect(find.text('Heavy use lately'), findsOneWidget);
      expect(find.text('Estimated total \$122.50'), findsOneWidget);
      expect(find.textContaining('1 line has no unit cost'), findsOneWidget);
      expect(find.textContaining('Gin: Use jumped 4x (AI)'), findsOneWidget);
      expect(
        find.textContaining('1 suggested line was left out'),
        findsOneWidget,
      );

      await tester.enterText(find.byType(TextFormField).first, '6');
      await tester.pumpAndSettle();
      expect(find.text('Estimated total \$147.00'), findsOneWidget);

      await tester.tap(find.byTooltip('Remove from list').first);
      await tester.pumpAndSettle();
      expect(find.text('Tito’s Vodka'), findsNothing);
      expect(find.text('Estimated total \$0.00'), findsOneWidget);

      await tester.tap(find.text('Back to below-par list'));
      await tester.pumpAndSettle();
      expect(find.text('Tito’s Vodka'), findsOneWidget);
    });

    testWidgets('AI disabled: the reason shows and the below-par list stays',
        (tester) async {
      final ai = _Ai(
        const InventoryReorderResult(orders: []),
        error: const AiUnavailableError(
          'AI features are turned off for this organization.',
        ),
      );
      await _pump(tester, ai);
      await tester.tap(find.text('Suggest with AI'));
      await tester.pumpAndSettle();
      expect(
        find.text('AI features are turned off for this organization.'),
        findsOneWidget,
      );
      expect(find.text('Tito’s Vodka'), findsOneWidget);
      expect(find.text('Copy as text'), findsOneWidget);
    });

    testWidgets('Copy as text puts the order on the clipboard', (tester) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null),
      );
      await _pump(tester, _Ai(const InventoryReorderResult(orders: [])));
      await tester.ensureVisible(find.text('Copy as text'));
      await tester.tap(find.text('Copy as text'));
      await tester.pumpAndSettle();
      expect(copied, contains('Tito’s Vodka: 4.5 Bottle'));
      expect(find.text('Reorder list copied.'), findsOneWidget);
    });

    testWidgets('nothing below par shows an empty state', (tester) async {
      await _pump(
        tester,
        _Ai(const InventoryReorderResult(orders: [])),
        snapshot: InventorySnapshot(
          items: [_item('lime', 'Limes')],
          categories: const [],
          subcategories: const [],
          areas: [
            InventoryArea.fromJson({'id': 'bar', 'name': 'Main Bar'}),
          ],
          subAreas: const [],
          stock: [_stock('lime', 20, 10)],
          counts: const [],
          history: const [],
        ),
      );
      expect(
        find.text('Nothing is below par. Nothing to order.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Suggest with AI'));
      await tester.pumpAndSettle();
      expect(find.textContaining('nothing to ask about'), findsOneWidget);
    });
  });

  group('entry point', () {
    testWidgets('managers see Suggest reorder on the inventory screen',
        (tester) async {
      await _pumpList(tester, manager: true);
      expect(find.byTooltip('Suggest reorder'), findsOneWidget);
    });

    testWidgets('staff do not', (tester) async {
      await _pumpList(tester, manager: false);
      expect(find.byTooltip('Suggest reorder'), findsNothing);
    });
  });
}

class _Ai implements AiRepository {
  _Ai(this.answer, {this.error});

  final InventoryReorderResult answer;
  final AppError? error;
  String? lastInput;

  @override
  Future<InventoryReorderResult> suggestReorder({
    required String venueId,
    required String context,
  }) async {
    lastInput = context;
    if (error != null) throw error!;
    return answer;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

Future<void> _pump(
  WidgetTester tester,
  _Ai ai, {
  InventorySnapshot? snapshot,
}) async {
  tester.view.physicalSize = const Size(900, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final data = snapshot ?? _snapshot();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        inventorySnapshotProvider.overrideWith((ref, scope) async => data),
        aiRepositoryProvider.overrideWithValue(ai),
      ],
      child: const MaterialApp(
        home: InventoryReorderScreen(scope: _scope, venueName: 'Venue'),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _pumpList(WidgetTester tester, {required bool manager}) async {
  tester.view.physicalSize = const Size(900, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final venue = Venue(
    id: 'venue',
    organizationId: 'org',
    name: 'Venue',
    timezone: 'America/Chicago',
    createdAt: DateTime(2026),
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        activeVenueProvider.overrideWith((ref) => venue),
        canManageActiveVenueProvider.overrideWith((ref) async => manager),
        currentUserIdProvider.overrideWithValue('me'),
        inventorySnapshotProvider
            .overrideWith((ref, scope) async => _snapshot()),
      ],
      child: const MaterialApp(home: InventoryListScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

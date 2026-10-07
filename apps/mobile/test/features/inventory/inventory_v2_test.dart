import 'package:flutter_test/flutter_test.dart';
import 'package:venuewrangler_mobile/features/ai/domain/ai_models.dart';
import 'package:venuewrangler_mobile/features/inventory/domain/inventory_item.dart';
import 'package:venuewrangler_mobile/features/inventory/domain/inventory_v2.dart';

InventoryStock stock(
  Object? quantity, {
  Object? par,
  String item = 'vodka',
  String area = 'bar',
}) =>
    InventoryStock.fromJson({
      'id': '$item-$area',
      'inventory_item_id': item,
      'area_id': area,
      'quantity': quantity,
      'par_level': par,
    });
InventoryItem item(
  String id,
  String name, {
  num? cost = 24.50,
  bool active = true,
}) =>
    InventoryItem(
      id: id,
      venueId: 'venue',
      name: name,
      unitCostUsd: cost,
      updatedAt: DateTime(2026),
      active: active,
      countUnit: 'Bottle',
    );

void main() {
  test(
      'inventory parsing stays compatible with old responses and preserves size suggestions',
      () {
    final old = InventoryLineItem.fromJson({
      'name': 'Chicken',
      'quantity': 14.25,
      'unit': 'lb',
      'unit_cost_usd': 3.20,
    });
    expect(old.quantity, 14.25);
    expect(old.sizeAmount, isNull);
    final current = InventoryLineItem.fromJson({
      'name': 'Vodka',
      'quantity': 6.5,
      'unit': 'Bottle',
      'size_amount': 1,
      'size_unit': 'L',
      'category': 'Liquor',
      'subcategory': 'Vodka',
    });
    expect(current.sizeAmount, 1);
    expect(current.sizeUnit, 'L');
    expect(current.category, 'Liquor');
    expect(current.subcategory, 'Vodka');
  });
  test('decimal quantities and dollar valuation remain exact', () {
    expect(inventoryQuantity(inventoryDecimal('5.7500')), '5.75');
    expect(inventoryMoney(inventoryValue('25.5', '24.50')), '\$624.75');
    expect(inventoryMoney(inventoryValue('-2', '24.50')), '-\$49.00');
    expect(inventoryMoney(inventoryValue('0.1', '0.10')), '\$0.01');
    expect(inventoryMoney(inventoryValue('14.25', '3.20')), '\$45.60');
    expect(inventoryMoney(inventoryValue('240', '0.03')), '\$7.20');
    expect(inventoryMoney(inventoryValue('0.5', '0.01')), '\$0.01');
    expect(() => inventoryDecimal('1.00001'), throwsFormatException);
    expect(() => inventoryDecimal('NaN'), throwsFormatException);
  });
  test('par/status handles unknown, zero, negative legacy stock and no par',
      () {
    expect(stock(null, par: 8).status, InventoryStockStatus.unknown);
    expect(stock(0, par: 8).status, InventoryStockStatus.out);
    expect(stock(-2.5, par: 8).status, InventoryStockStatus.out);
    expect(stock(3.5, par: 8).status, InventoryStockStatus.low);
    expect(inventoryQuantity(stock(3.5, par: 8).shortage), '4.5');
    expect(stock(8, par: 8).status, InventoryStockStatus.available);
    expect(stock(3.5).status, InventoryStockStatus.available);
    expect(stock(3.5).shortage, BigInt.zero);
  });
  test(
      'same item sums across areas; inactive locations are excluded from dashboard value',
      () {
    final s = InventorySnapshot(
      items: [
        item('vodka', 'Tito’s Vodka'),
        item('unknown', 'No cost', cost: null),
      ],
      categories: [],
      subcategories: [],
      areas: [
        InventoryArea.fromJson({'id': 'bar', 'name': 'Main Bar'}),
        InventoryArea.fromJson({'id': 'room', 'name': 'Liquor Room'}),
        InventoryArea.fromJson(
          {'id': 'old', 'name': 'Closed', 'is_active': false},
        ),
      ],
      subAreas: [],
      stock: [
        stock(4.5),
        stock(18, item: 'vodka', area: 'room'),
        stock(3, item: 'vodka', area: 'old'),
        stock(100, item: 'unknown'),
      ],
      counts: [],
      history: [],
    );
    expect(inventoryQuantity(s.totalFor('vodka')), '25.5');
    expect(inventoryMoney(s.value), '\$551.25');
    expect(s.activePositions.length, 3);
  });
  test('count snapshot keeps missing cost and prior baseline unknown', () {
    final row = InventoryCountLine.fromJson({
      'id': 'row',
      'item_name': 'Rice',
      'location_name': 'Kitchen',
      'count_unit': 'Bag',
      'previous_quantity': null,
      'counted_quantity': 3.5,
      'unit_cost_snapshot': null,
      'variance_quantity': null,
      'variance_value': null,
    });
    expect(row.previous, isNull);
    expect(row.counted, '3.5');
    expect(row.varianceValue, isNull);
    expect(
      InventoryCount.fromJson({
        'id': 'c',
        'status': 'cancelled',
        'count_type': 'partial',
        'started_at': '2026-10-07T12:00:00Z',
      }).open,
      false,
    );
  });
  test('matching flags ambiguous sizes and never matches inactive inventory',
      () {
    final i = item('one', 'Titos Vodka');
    expect(matchInventoryItem('Titos Vodka', [i]).confidence, 100);
    expect(
      matchInventoryItem('Titos Vodka', [i, item('two', 'Titos Vodka')]).item,
      isNull,
    );
    expect(
      matchInventoryItem(
        'Titos Vodka',
        [item('inactive', 'Titos Vodka', active: false)],
      ).item,
      isNull,
    );
    expect(matchInventoryItem('Titos Vodka 1L', [i]).confidence, 60);
    expect(matchInventoryItem('Vodka unrelated', [i]).item, isNull);
  });
}

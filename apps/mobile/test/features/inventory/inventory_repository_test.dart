import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:venuewrangler_mobile/features/inventory/data/inventory_repository.dart';

void main() {
  test(
      'stock mutations send decimal strings and operation IDs through checked RPCs',
      () async {
    final requests = <http.Request>[];
    final client = SupabaseClient(
      'https://inventory.test',
      'public-test-key',
      httpClient: MockClient((r) async {
        requests.add(r);
        return http.Response(
          jsonEncode('stock-id'),
          200,
          request: r,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    addTearDown(client.dispose);
    final repo = SupabaseInventoryRepository(client);
    await repo.applyAction(
      'source',
      'TRANSFER',
      '4.5',
      operationId: 'retry-id',
      destinationId: 'destination',
      reason: 'Restock bar',
    );
    final r = requests.single;
    expect(r.url.path, '/rest/v1/rpc/inventory_apply_action');
    expect(jsonDecode(r.body), containsPair('p_quantity', '4.5'));
    expect(jsonDecode(r.body), containsPair('p_operation_id', 'retry-id'));
    expect(jsonDecode(r.body), containsPair('p_destination', 'destination'));
  });
  test('count save uses one transaction and keeps blank rows null', () async {
    late http.Request request;
    final client = SupabaseClient(
      'https://inventory.test',
      'public-test-key',
      httpClient: MockClient((r) async {
        request = r;
        return http.Response('', 204, request: r);
      }),
    );
    addTearDown(client.dispose);
    await SupabaseInventoryRepository(client).saveCount(
      'count',
      [
        {'id': 'a', 'quantity': '5.75'},
        {'id': 'b', 'quantity': null},
      ],
      complete: true,
    );
    expect(request.url.path, '/rest/v1/rpc/inventory_save_count');
    final body = jsonDecode(request.body) as Map;
    expect(body['p_complete'], true);
    expect((body['p_values'] as List)[1]['quantity'], isNull);
  });
  test(
      'item update is explicitly constrained to its venue and soft deletion preserves history',
      () async {
    final requests = <http.Request>[];
    final client = SupabaseClient(
      'https://inventory.test',
      'public-test-key',
      httpClient: MockClient((r) async {
        requests.add(r);
        return http.Response(
          jsonEncode({'id': 'item'}),
          200,
          request: r,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    addTearDown(client.dispose);
    final repo = SupabaseInventoryRepository(client);
    await repo.saveItem('venue', {'name': 'Vodka'}, id: 'item');
    expect(requests[0].url.queryParameters['venue_id'], 'eq.venue');
    await repo.deleteItem('item');
    expect(requests[1].method, 'PATCH');
    expect(jsonDecode(requests[1].body), {'is_active': false});
  });
}

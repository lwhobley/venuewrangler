import 'package:flutter_test/flutter_test.dart';
import 'package:venuewrangler_mobile/features/guests_reservations/data/guests_reservations_repository.dart';

void main() {
  /// A fake `.range()` source over [total] rows numbered from 0.
  ({Future<List<int>> Function(int, int) fetch, List<(int, int)> calls}) fake(
    int total,
  ) {
    final calls = <(int, int)>[];
    Future<List<int>> fetch(int from, int to) async {
      calls.add((from, to));
      final end = to + 1 > total ? total : to + 1;
      return [for (var i = from; i < end; i++) i];
    }

    return (fetch: fetch, calls: calls);
  }

  test('fetches every page until a short page and keeps all rows', () async {
    final source = fake(7);
    final rows = await fetchAllPages(source.fetch, pageSize: 3);

    expect(rows, [0, 1, 2, 3, 4, 5, 6]);
    expect(source.calls, [(0, 2), (3, 5), (6, 8)]);
  });

  test('requests one more page after a full page so the end is detected',
      () async {
    final source = fake(6);
    final rows = await fetchAllPages(source.fetch, pageSize: 3);

    expect(rows, [0, 1, 2, 3, 4, 5]);
    expect(source.calls, [(0, 2), (3, 5), (6, 8)]);
  });

  test('a single short page is one request', () async {
    final source = fake(2);
    final rows = await fetchAllPages(source.fetch, pageSize: 500);

    expect(rows, [0, 1]);
    expect(source.calls, [(0, 499)]);
  });

  test('an empty result is one request and an empty list', () async {
    final source = fake(0);
    final rows = await fetchAllPages(source.fetch, pageSize: 500);

    expect(rows, isEmpty);
    expect(source.calls, [(0, 499)]);
  });

  test('a failing page propagates instead of returning partial data', () async {
    var calls = 0;
    await expectLater(
      fetchAllPages<int>((from, to) async {
        calls++;
        if (calls == 2) throw StateError('network');
        return List<int>.filled(500, 1);
      }),
      throwsStateError,
    );
  });

  test('default window covers 30 days back and 365 days ahead', () {
    final now = DateTime.utc(2026, 10, 12, 9);
    final window = defaultReservationWindow(now);

    expect(window.from, DateTime.utc(2026, 9, 12, 9));
    expect(window.to, DateTime.utc(2027, 10, 12, 9));
  });
}

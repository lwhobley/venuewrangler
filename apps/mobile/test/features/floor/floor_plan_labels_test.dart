import 'package:flutter_test/flutter_test.dart';
import 'package:venuewrangler_mobile/features/floor/domain/floor_plan.dart';

Map<String, dynamic> _row(Object? labels) => {
      'id': 'plan-1',
      'organization_id': 'org-1',
      'venue_id': 'venue-1',
      'name': 'Main floor',
      'created_at': '2026-11-26T00:00:00Z',
      'updated_at': '2026-11-26T00:00:00Z',
      if (labels != null) 'labels': labels,
    };

void main() {
  test('parses labels and skips malformed ones', () {
    final plan = FloorPlan.fromJson(
      _row([
        {'text': ' Stage ', 'x': 10, 'y': 20, 'width': 300, 'height': 100},
        {'text': '', 'x': 0, 'y': 0, 'width': 10, 'height': 10},
        {'text': 'Bar', 'x': 0, 'y': 0, 'width': 0, 'height': 10},
        {'text': 'DJ', 'x': 'a', 'y': 0, 'width': 10, 'height': 10},
        'not a map',
      ]),
    );

    expect(plan.labels, hasLength(1));
    final stage = plan.labels.single;
    expect(stage.text, 'Stage');
    expect([stage.x, stage.y, stage.width, stage.height], [10, 20, 300, 100]);
    expect(plan.toJson()['labels'], [
      {'text': 'Stage', 'x': 10.0, 'y': 20.0, 'width': 300.0, 'height': 100.0},
    ]);
  });

  test('a plan without labels has none', () {
    expect(FloorPlan.fromJson(_row(null)).labels, isEmpty);
  });
}

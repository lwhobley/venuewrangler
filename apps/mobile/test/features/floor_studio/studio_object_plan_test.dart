import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venuewrangler_mobile/features/floor_studio/domain/floor_studio.dart';
import 'package:venuewrangler_mobile/features/floor_studio/presentation/studio_object_plan.dart';

const _stage = StudioObject(
  id: 'stage',
  kind: StudioObjectKind.stage,
  description: 'Stage',
  x: 30,
  y: 20,
  widthFeet: 16,
  depthFeet: 12,
);

void main() {
  Future<({List<StudioObject> moves, List<String?> selections})> pumpPlan(
    WidgetTester tester, {
    List<StudioObject> objects = const [_stage],
  }) async {
    final moves = <StudioObject>[];
    final selections = <String?>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 540,
            child: StatefulBuilder(
              builder: (context, setState) => StudioObjectPlan(
                widthFeet: 60,
                depthFeet: 40,
                tables: const [StudioTable(10, 10)],
                tableDiameterFeet: 6,
                objects: objects,
                selectedId: null,
                onSelect: selections.add,
                onMove: moves.add,
              ),
            ),
          ),
        ),
      ),
    );
    return (moves: moves, selections: selections);
  }

  testWidgets('tapping an object selects it and tapping floor clears it',
      (tester) async {
    final log = await pumpPlan(tester);
    final canvas = find.byKey(const ValueKey('studio-object-plan-canvas'));
    await tester.tap(canvas);
    await tester.pump(const Duration(milliseconds: 400));
    expect(log.selections, ['stage']);

    // Top-left corner of the room, well away from the stage.
    final topLeft = tester.getTopLeft(canvas) + const Offset(4, 4);
    await tester.tapAt(topLeft);
    await tester.pump(const Duration(milliseconds: 400));
    expect(log.selections.last, isNull);
  });

  testWidgets('dragging an object reports a snapped, clamped move',
      (tester) async {
    final log = await pumpPlan(tester);
    final canvas = find.byKey(const ValueKey('studio-object-plan-canvas'));
    await tester.drag(canvas, const Offset(54, 0));
    await tester.pumpAndSettle();
    expect(log.moves, isNotEmpty);
    expect(log.moves.last.x, closeTo(36, 1e-9));
    expect(log.moves.last.y, closeTo(20, 1e-9));
  });
}

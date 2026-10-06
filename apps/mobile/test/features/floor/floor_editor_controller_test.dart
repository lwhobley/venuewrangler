import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venuewrangler_mobile/features/floor/application/floor_editor_controller.dart';
import 'package:venuewrangler_mobile/features/floor/data/floor_repository.dart';
import 'package:venuewrangler_mobile/features/floor/domain/editor_table.dart';
import 'package:venuewrangler_mobile/features/floor/domain/floor_table.dart';

FloorTable _live(String id, String label, {double x = 0, double y = 0}) {
  final now = DateTime(2026);
  return FloorTable(
    id: id,
    organizationId: 'org',
    venueId: 'venue',
    floorPlanId: 'plan',
    label: label,
    x: x,
    y: y,
    lastActivityAt: now,
    createdAt: now,
    updatedAt: now,
  );
}

class _RecordingRepo implements FloorRepository {
  List<EditorTable> created = [];
  List<EditorTable> updated = [];
  List<String> removed = [];

  @override
  Future<void> saveLayout({
    required String venueId,
    required String floorPlanId,
    required List<EditorTable> created,
    required List<EditorTable> updated,
    required List<String> removedIds,
  }) async {
    this.created = created;
    this.updated = updated;
    removed = removedIds;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

FloorEditorController _controller() {
  FlutterSecureStorage.setMockInitialValues({});
  final c = FloorEditorController();
  c.load(
    live: [_live('a', 'T1'), _live('b', 'T2', x: 200)],
    planWidth: 1000,
    planHeight: 800,
  );
  return c;
}

void main() {
  test('moving snaps to the grid and stays inside the plan', () {
    final c = _controller();
    c.moveTo('a', 47, 33);
    expect(c.state.tables.first.x, 40);
    expect(c.state.tables.first.y, 40);

    c.moveTo('a', -500, 5000);
    final t = c.state.tables.first;
    expect(t.x, 0);
    expect(t.y + t.height, 800);
  });

  test('snap off keeps raw coordinates', () {
    final c = _controller()..toggleSnap();
    c.moveTo('a', 47, 33);
    expect(c.state.tables.first.x, 47);
  });

  test('resize keeps the centre fixed, enforces a minimum and square shapes',
      () {
    final c = _controller();
    c.moveTo('a', 100, 100);
    final before = c.state.tables.first;
    final cx = before.x + before.width / 2;
    c.resizeTo('a', 160, 120);
    final t = c.state.tables.first;
    expect(t.x + t.width / 2, cx);
    expect(t.width, 160);

    c.resizeTo('a', 5, 5);
    expect(c.state.tables.first.width, kMinTableSize);

    c.updateProps('a', shape: 'round');
    c.resizeTo('a', 100, 60);
    expect(c.state.tables.first.width, c.state.tables.first.height);
  });

  test('rotation snaps to 15 degrees', () {
    final c = _controller();
    c.rotateTo('a', 38);
    expect(c.state.tables.first.rotation, 45);
  });

  test('undo reverts a whole gesture', () {
    final c = _controller();
    c.beginChange();
    c.moveTo('a', 100, 100);
    c.moveTo('a', 120, 140);
    c.undo();
    expect(c.state.tables.first.x, 0);
    expect(c.state.hasChanges, isFalse);
  });

  test('added tables are new, selected and flagged as changes', () {
    final c = _controller();
    final t = c.addTable(
      label: 'T3',
      shape: 'booth',
      capacity: 6,
      cx: 500,
      cy: 400,
    );
    expect(t.isNew, isTrue);
    expect(c.state.selectedId, t.id);
    expect(c.state.hasChanges, isTrue);
    expect(t.width, 140);
  });

  test('tables in use cannot be deleted', () {
    final c = _controller();
    final now = DateTime(2026);
    c.load(
      live: [
        FloorTable(
          id: 'x',
          organizationId: 'o',
          venueId: 'v',
          floorPlanId: 'p',
          label: 'T9',
          status: 'seated',
          lastActivityAt: now,
          createdAt: now,
          updatedAt: now,
        ),
      ],
      planWidth: 1000,
      planHeight: 800,
    );
    expect(c.deleteTable('x'), isNotNull);
    expect(c.state.tables, hasLength(1));
  });

  test('overlapping and duplicate-label tables are detected', () {
    final c = _controller();
    c.moveTo('b', 20, 0);
    expect(c.state.overlappingIds, {'a', 'b'});

    c.updateProps('b', label: 't1');
    expect(c.blockingIssues(), isNotEmpty);
  });

  test('publish sends only created, changed and removed tables', () async {
    final c = _controller();
    final repo = _RecordingRepo();
    c.moveTo('a', 100, 100);
    c.deleteTable('b');
    c.addTable(label: 'T3', shape: 'round', capacity: 2, cx: 600, cy: 300);

    await c.publish(repo: repo, venueId: 'venue', planId: 'plan');

    expect(repo.updated.map((t) => t.id), ['a']);
    expect(repo.removed, ['b']);
    expect(repo.created.single.label, 'T3');
    expect(
      repo.updated.single.toLayoutColumns().containsKey('status'),
      isFalse,
    );
  });

  test('drafts round-trip and drop tables deleted on the server', () async {
    final c = _controller();
    c.moveTo('a', 300, 300);
    c.addTable(label: 'T3', shape: 'rect', capacity: 4, cx: 600, cy: 300);
    await c.saveDraft('plan');
    expect(await c.hasDraft('plan'), isTrue);

    final fresh = FloorEditorController()
      ..load(live: [_live('a', 'T1')], planWidth: 1000, planHeight: 800);
    await fresh.restoreDraft('plan');
    expect(fresh.state.tables.map((t) => t.label), ['T1', 'T3']);
    expect(fresh.state.tables.first.x, 300);

    await fresh.discardDraft('plan');
    expect(await fresh.hasDraft('plan'), isFalse);
  });
}

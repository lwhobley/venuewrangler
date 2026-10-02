import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venuewrangler_mobile/features/insights/application/insights_providers.dart';
import 'package:venuewrangler_mobile/features/insights/data/insights_repository.dart';
import 'package:venuewrangler_mobile/features/insights/domain/shift_insight.dart';
import 'package:venuewrangler_mobile/features/insights/presentation/shift_insights_screen.dart';
import 'package:venuewrangler_mobile/features/venues/application/venues_providers.dart';
import 'package:venuewrangler_mobile/features/venues/domain/venue.dart';

class _FakeInsightsRepository implements InsightsRepository {
  _FakeInsightsRepository(this.insights);

  List<ShiftInsight> insights;
  String? lastGeneratedContext;
  String? lastDeletedId;

  @override
  Future<List<ShiftInsight>> getInsights({
    required String venueId,
    String? shiftId,
    int limit = 20,
  }) async =>
      insights;

  @override
  Future<ShiftInsight> saveInsight({
    required String venueId,
    String? shiftId,
    required ShiftInsightKind kind,
    required String title,
    required String body,
  }) async {
    final insight = ShiftInsight(
      id: 'insight-${insights.length + 1}',
      organizationId: 'o1',
      venueId: venueId,
      shiftId: shiftId,
      kind: kind,
      title: title,
      body: body,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );
    insights.add(insight);
    return insight;
  }

  @override
  Future<List<ShiftInsight>> generateAndSaveShiftInsights({
    required String venueId,
    String? shiftId,
    required String shiftContext,
  }) async {
    lastGeneratedContext = shiftContext;
    final created = ShiftInsight(
      id: 'gen-1',
      organizationId: 'o1',
      venueId: venueId,
      shiftId: shiftId,
      kind: ShiftInsightKind.rushPrep,
      title: 'Rush Prep Warning',
      body: 'Generated from context: $shiftContext',
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );
    insights.add(created);
    return [created];
  }

  @override
  Future<void> deleteInsight({required String insightId}) async {
    lastDeletedId = insightId;
    insights.removeWhere((i) => i.id == insightId);
  }
}

final _testVenue = Venue(
  id: 'v1',
  organizationId: 'o1',
  name: 'Downtown Lounge',
  createdAt: DateTime(2026),
);

ShiftInsight _makeInsight({
  required String id,
  required String title,
  required String body,
  ShiftInsightKind kind = ShiftInsightKind.shiftSummary,
}) =>
    ShiftInsight(
      id: id,
      organizationId: 'o1',
      venueId: 'v1',
      kind: kind,
      title: title,
      body: body,
      createdAt: DateTime(2026, 10, 2, 18, 30),
      updatedAt: DateTime(2026, 10, 2, 18, 30),
    );

void main() {
  testWidgets('shows empty state when no shift insights', (tester) async {
    final fakeRepo = _FakeInsightsRepository([]);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeVenueProvider.overrideWith((ref) => _testVenue),
          insightsRepositoryProvider.overrideWithValue(fakeRepo),
        ],
        child: const MaterialApp(home: ShiftInsightsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No shift insights yet.'), findsOneWidget);
    expect(find.text('Generate AI Insights'), findsOneWidget);
  });

  testWidgets('renders list of shift insights with kind and title', (tester) async {
    final fakeRepo = _FakeInsightsRepository([
      _makeInsight(
        id: 'i1',
        title: 'Friday Peak Rush',
        body: 'Expect heavy bar orders between 7 and 9 PM.',
        kind: ShiftInsightKind.rushPrep,
      ),
      _makeInsight(
        id: 'i2',
        title: 'Bar Station Understaffed',
        body: 'Recommend adding a second bartender.',
        kind: ShiftInsightKind.coverageWarning,
      ),
    ]);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeVenueProvider.overrideWith((ref) => _testVenue),
          insightsRepositoryProvider.overrideWithValue(fakeRepo),
        ],
        child: const MaterialApp(home: ShiftInsightsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Friday Peak Rush'), findsOneWidget);
    expect(find.text('Rush Prep'), findsOneWidget);
    expect(find.text('Expect heavy bar orders between 7 and 9 PM.'), findsOneWidget);

    expect(find.text('Bar Station Understaffed'), findsOneWidget);
    expect(find.text('Coverage Warning'), findsOneWidget);
  });

  testWidgets('opens generate dialog and triggers insight generation', (tester) async {
    final fakeRepo = _FakeInsightsRepository([]);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeVenueProvider.overrideWith((ref) => _testVenue),
          insightsRepositoryProvider.overrideWithValue(fakeRepo),
        ],
        child: const MaterialApp(home: ShiftInsightsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Generate AI Insights'));
    await tester.pumpAndSettle();

    expect(find.text('Generate Shift Insights'), findsOneWidget);

    await tester.enterText(
      find.byType(TextField),
      'Friday 6pm rush, 200 covers expected',
    );
    await tester.pump();

    await tester.tap(find.text('Generate'));
    await tester.pumpAndSettle();

    expect(fakeRepo.lastGeneratedContext, 'Friday 6pm rush, 200 covers expected');
    expect(find.text('Rush Prep Warning'), findsOneWidget);
  });

  testWidgets('deletes insight with confirmation dialog', (tester) async {
    final fakeRepo = _FakeInsightsRepository([
      _makeInsight(
        id: 'del-1',
        title: 'Temporary Note',
        body: 'To be removed.',
      ),
    ]);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeVenueProvider.overrideWith((ref) => _testVenue),
          insightsRepositoryProvider.overrideWithValue(fakeRepo),
        ],
        child: const MaterialApp(home: ShiftInsightsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Temporary Note'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();

    expect(find.text('Delete Insight?'), findsOneWidget);

    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(fakeRepo.lastDeletedId, 'del-1');
    expect(find.text('Temporary Note'), findsNothing);
  });
}

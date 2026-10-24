import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venuewrangler_mobile/core/auth/auth_providers.dart';
import 'package:venuewrangler_mobile/core/errors/app_error.dart';
import 'package:venuewrangler_mobile/features/ai/application/ai_providers.dart';
import 'package:venuewrangler_mobile/features/ai/application/ask_data_providers.dart';
import 'package:venuewrangler_mobile/features/ai/domain/ai_models.dart';
import 'package:venuewrangler_mobile/features/ai/presentation/ask_data_screen.dart';
import 'package:venuewrangler_mobile/features/venues/application/venues_providers.dart';
import 'package:venuewrangler_mobile/features/venues/domain/venue.dart';

import 'ask_data_service_test.dart' show FakeAi, FakeData;

void main() {
  final venue = Venue(
    id: 'v1',
    organizationId: 'o1',
    name: 'Fulton & Pine',
    timezone: 'America/Chicago',
    createdAt: DateTime(2026),
  );

  late FakeAi ai;
  late FakeData data;

  setUp(() {
    ai = FakeAi();
    data = FakeData();
  });

  Future<void> pump(WidgetTester tester, {bool manager = true}) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeVenueProvider.overrideWith((ref) => venue),
          currentUserIdProvider.overrideWithValue('manager-1'),
          canManageActiveVenueProvider.overrideWith((ref) async => manager),
          aiRepositoryProvider.overrideWithValue(ai),
          askDataRepositoryProvider.overrideWithValue(data),
        ],
        child: const MaterialApp(home: AskDataScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> ask(WidgetTester tester, String question) async {
    await tester.enterText(find.byType(TextField), question);
    await tester.tap(find.text('Ask'));
    await tester.pumpAndSettle();
  }

  Map<String, Object?> plannedCall(String metric, Map<String, Object?> p) => {
        'metric': metric,
        'params': p,
      };

  testWidgets('shows the question field, example chips and quick numbers', (
    tester,
  ) async {
    data.results['reservation_summary'] = <Map<String, Object?>>[
      {
        'bucket': 'total',
        'reservation_count': 14,
        'covers': 52,
        'served_covers': 30,
        'total_buckets': 1,
      },
    ];
    data.results['labour_hours'] = <Map<String, Object?>>[
      {
        'bucket': 'total',
        'worked_hours': 123.5,
        'punch_count': 20,
        'open_punch_count': 2,
        'total_buckets': 1,
      },
    ];
    data.results['incident_summary'] = <Map<String, Object?>>[
      {'bucket': 'low', 'incident_count': 3, 'unresolved_count': 1},
      {'bucket': 'high', 'incident_count': 2, 'unresolved_count': 2},
    ];
    await pump(tester);

    expect(find.text('Your question'), findsOneWidget);
    expect(find.text('How many covers did we do last Friday?'), findsOneWidget);
    expect(find.text("What's our no-show rate this month?"), findsOneWidget);
    expect(find.text('Quick numbers'), findsOneWidget);
    expect(find.text('Covers today'), findsOneWidget);
    expect(find.text('52'), findsOneWidget);
    expect(find.text('123.5 h'), findsOneWidget);
    expect(find.text('Unresolved incidents'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    // Quick numbers use no AI.
    expect(ai.planCalls, 0);
    expect(data.ran.map((r) => r.call.metric.name), [
      'reservation_summary',
      'labour_hours',
      'incident_summary',
    ]);
  });

  testWidgets('an example chip fills the question field', (tester) async {
    await pump(tester);

    await tester.tap(find.text('Who worked the most hours last week?'));
    await tester.pump();

    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'Who worked the most hours last week?',
    );
    expect(ai.planCalls, 0);
  });

  testWidgets('shows the answer with the evidence: metric, dates, rows', (
    tester,
  ) async {
    ai.plan = DataQuestionPlan(
      rawCalls: [
        plannedCall('reservation_summary', {
          'from': '2026-10-17',
          'to': '2026-10-17',
          'group_by': 'status',
        }),
      ],
    );
    ai.answer = const DataQuestionAnswer(
      answer: 'On 2026-10-17 you had 11 covers.',
      caveats: 'No-shows are included in covers.',
    );
    data.results['reservation_summary'] = <Map<String, Object?>>[
      {'bucket': 'seated', 'covers': 11, 'reservation_count': 3},
    ];
    await pump(tester);

    await ask(tester, 'How many covers did we do last Friday?');

    expect(find.text('On 2026-10-17 you had 11 covers.'), findsOneWidget);
    expect(find.text('No-shows are included in covers.'), findsOneWidget);
    expect(find.text('How I got this'), findsOneWidget);
    expect(find.text('Reservations'), findsOneWidget);
    expect(
      find.textContaining('From 2026-10-17 to 2026-10-17'),
      findsOneWidget,
    );
    expect(find.textContaining('Group by: status'), findsOneWidget);
    expect(find.text('seated'), findsOneWidget);
    expect(find.text('11'), findsWidgets);
    expect(find.textContaining('Only part of your question'), findsNothing);
    // The typed question stays put.
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'How many covers did we do last Friday?',
    );
  });

  testWidgets('unanswerable plans say so and run nothing', (tester) async {
    ai.plan = const DataQuestionPlan(
      unanswerableReason: 'We do not hold pay data.',
    );
    await pump(tester);
    final ranBefore = data.ran.length;

    await ask(tester, 'What does Sam earn?');

    expect(
      find.text("I can't answer that from the data I can see."),
      findsOneWidget,
    );
    expect(data.ran.length, ranBefore);
    expect(ai.answerCalls, 0);
    expect(find.text('How I got this'), findsNothing);
  });

  testWidgets('a partially answered question is flagged', (tester) async {
    ai.plan = DataQuestionPlan(
      rawCalls: [
        plannedCall('task_summary', {'day': '2026-10-20'}),
        plannedCall('delete_everything', <String, Object?>{}),
      ],
    );
    ai.answer = const DataQuestionAnswer(answer: 'Two tasks were due.');
    data.results['task_summary'] = <Map<String, Object?>>[
      {'tasks_due': 2},
    ];
    await pump(tester);

    await ask(tester, 'Tasks and something else');

    expect(find.text('Two tasks were due.'), findsOneWidget);
    expect(
      find.textContaining('Only part of your question could be answered'),
      findsOneWidget,
    );
    expect(find.textContaining('Not run: delete_everything'), findsOneWidget);
  });

  testWidgets('AI errors keep the typed question and show the message', (
    tester,
  ) async {
    ai.planError = const AiUnavailableError(
      'AI features are turned off for this organization. An owner or admin '
      'can turn them on in Settings.',
    );
    await pump(tester);

    await ask(tester, 'How many covers last Friday?');

    expect(find.textContaining('AI features are turned off'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'How many covers last Friday?',
    );
    // The button is usable again for a retry.
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Ask'))
          .onPressed,
      isNotNull,
    );
    // Quick numbers still work.
    expect(find.text('Quick numbers'), findsOneWidget);
  });

  testWidgets('declining the AI notice shows the existing message', (
    tester,
  ) async {
    ai.planError = const AiUnavailableError(
      'AI features need your OK to send text to our AI provider. You can '
      'agree the next time you try, or do this by hand.',
    );
    await pump(tester);

    await ask(tester, 'How many covers last Friday?');

    expect(find.textContaining('need your OK'), findsOneWidget);
  });

  testWidgets(
      'a failing report is shown in the evidence and the answer is partial', (
    tester,
  ) async {
    ai.plan = DataQuestionPlan(
      rawCalls: [
        plannedCall('task_summary', {'day': '2026-10-20'}),
        plannedCall('low_stock', <String, Object?>{}),
      ],
    );
    ai.answer = const DataQuestionAnswer(answer: 'Two tasks were due.');
    data.results['low_stock'] = const NetworkError();
    await pump(tester);

    await ask(tester, 'Tasks and stock');

    expect(find.textContaining('Only part of your question'), findsOneWidget);
    expect(find.textContaining('No result:'), findsOneWidget);
  });

  testWidgets('non-managers are told only managers can ask', (tester) async {
    await pump(tester, manager: false);

    expect(
      find.text('Only managers of this venue can ask about its data.'),
      findsOneWidget,
    );
    expect(find.byType(TextField), findsNothing);
    expect(data.ran, isEmpty);
  });

  testWidgets('a capped table says how many rows there were', (tester) async {
    ai.plan = DataQuestionPlan(
      rawCalls: [
        plannedCall('labour_hours', {
          'from': '2026-10-12',
          'to': '2026-10-18',
          'limit': 1,
        }),
      ],
    );
    ai.answer = const DataQuestionAnswer(answer: 'Tess worked most.');
    data.results['labour_hours'] = <Map<String, Object?>>[
      {
        'bucket': 'Tess Tester',
        'worked_hours': 42.5,
        'punch_count': 5,
        'open_punch_count': 0,
        'total_buckets': 7,
      },
    ];
    await pump(tester);

    await ask(tester, 'Who worked the most hours last week?');

    expect(find.text('Tess Tester'), findsOneWidget);
    expect(find.text('Showing 1 of 7 rows.'), findsOneWidget);
    expect(find.text('Total buckets'), findsNothing);
  });
}

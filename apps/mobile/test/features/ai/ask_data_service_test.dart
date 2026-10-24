import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:venuewrangler_mobile/core/errors/app_error.dart';
import 'package:venuewrangler_mobile/features/ai/application/ask_data_service.dart';
import 'package:venuewrangler_mobile/features/ai/data/ai_repository.dart';
import 'package:venuewrangler_mobile/features/ai/data/ask_data_repository.dart';
import 'package:venuewrangler_mobile/features/ai/domain/ai_models.dart';
import 'package:venuewrangler_mobile/features/ai/domain/data_catalogue.dart';

class FakeAi implements AiRepository {
  FakeAi({this.plan = const DataQuestionPlan(), this.answer});

  DataQuestionPlan plan;
  DataQuestionAnswer? answer;
  Object? planError;
  Object? answerError;
  String? planInput;
  String? answerInput;
  int planCalls = 0;
  int answerCalls = 0;

  @override
  Future<DataQuestionPlan> planDataQuestion({
    required String venueId,
    required String input,
  }) async {
    planCalls++;
    planInput = input;
    if (planError != null) throw planError!;
    return plan;
  }

  @override
  Future<DataQuestionAnswer> answerDataQuestion({
    required String venueId,
    required String input,
  }) async {
    answerCalls++;
    answerInput = input;
    if (answerError != null) throw answerError!;
    return answer!;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class FakeData implements AskDataRepository {
  final ran = <({String venueId, ValidatedDataCall call})>[];
  final Map<String, Object> results = {};

  @override
  Future<MetricResult> run({
    required String venueId,
    required ValidatedDataCall call,
  }) async {
    ran.add((venueId: venueId, call: call));
    final result = results[call.metric.name];
    if (result is Exception || result is AppError) throw result!;
    return MetricResult(
      (result as List<Map<String, Object?>>?) ??
          [
            {'bucket': 'total', 'covers': 11, 'total_buckets': 1},
          ],
    );
  }
}

void main() {
  final today = DateTime.utc(2026, 10, 24);
  const question = 'How many covers did we do last Friday?';

  DataQuestionPlan planOf(List<Map<String, Object?>> calls) =>
      DataQuestionPlan(rawCalls: calls);

  test('plans, validates, runs as the caller, then answers from the rows',
      () async {
    final ai = FakeAi(
      plan: planOf([
        {
          'metric': 'reservation_summary',
          'params': {'day': '2026-10-23', 'venue_id': 'someone-else'},
        },
      ]),
      answer: const DataQuestionAnswer(
        answer: 'You seated 11 covers on 2026-10-23.',
        caveats: 'Seated or completed only.',
      ),
    );
    final data = FakeData();
    final service = AskDataService(ai: ai, data: data);

    final outcome = await service.ask(
      venueId: 'venue-1',
      question: question,
      today: today,
    );

    outcome as AskDataAnswered;
    expect(outcome.answer, contains('11 covers'));
    expect(outcome.caveats, isNotNull);
    expect(outcome.isPartial, isFalse);
    // The query ran for the caller's own venue, never the planner's.
    expect(data.ran.single.venueId, 'venue-1');
    expect(data.ran.single.call.rpcParams('venue-1')['p_venue_id'], 'venue-1');

    // Plan input: the question, today and the catalogue only.
    final planInput = jsonDecode(ai.planInput!) as Map<String, dynamic>;
    expect(planInput.keys, {'question', 'today', 'catalogue'});
    expect(planInput['today'], '2026-10-24');
    expect(planInput['question'], question);

    // Answer input: the question and the validated calls with their rows.
    final answerInput = jsonDecode(ai.answerInput!) as Map<String, dynamic>;
    expect(answerInput.keys, {'question', 'results'});
    final result = (answerInput['results'] as List).single as Map;
    expect(result['metric'], 'reservation_summary');
    expect(result['params'], {
      'from': '2026-10-23',
      'to': '2026-10-23',
      'group_by': 'total',
    });
    expect(((result['rows'] as List).single as Map)['covers'], 11);
    expect(ai.answerInput, isNot(contains('someone-else')));
  });

  test('an empty plan is unanswerable and never runs anything', () async {
    final ai = FakeAi(
      plan: const DataQuestionPlan(unanswerableReason: 'No pay data here.'),
    );
    final data = FakeData();

    final outcome = await AskDataService(ai: ai, data: data)
        .ask(venueId: 'v', question: 'What do we pay Sam?', today: today);

    outcome as AskDataUnanswerable;
    expect(outcome.reason, 'No pay data here.');
    expect(data.ran, isEmpty);
    expect(ai.answerCalls, 0);
  });

  test('a plan with only invalid calls is unanswerable', () async {
    final ai = FakeAi(
      plan: planOf([
        {'metric': 'guest_emails', 'params': <String, Object?>{}},
        {
          'metric': 'labour_hours',
          'params': {'from': 'yesterday', 'to': 'today'},
        },
      ]),
    );
    final data = FakeData();

    final outcome = await AskDataService(ai: ai, data: data)
        .ask(venueId: 'v', question: question, today: today);

    outcome as AskDataUnanswerable;
    expect(outcome.dropped, hasLength(2));
    expect(data.ran, isEmpty);
    expect(ai.answerCalls, 0);
  });

  test('dropped steps make the answer partial', () async {
    final ai = FakeAi(
      plan: planOf([
        {
          'metric': 'task_summary',
          'params': {'day': '2026-10-20'},
        },
        {'metric': 'drop_everything', 'params': <String, Object?>{}},
      ]),
      answer: const DataQuestionAnswer(answer: 'Two tasks were due.'),
    );
    final data = FakeData()
      ..results['task_summary'] = <Map<String, Object?>>[
        {'tasks_due': 2},
      ];

    final outcome = await AskDataService(ai: ai, data: data)
        .ask(venueId: 'v', question: question, today: today);

    outcome as AskDataAnswered;
    expect(outcome.isPartial, isTrue);
    expect(outcome.dropped.single.label, 'drop_everything');
  });

  test('one failing call is reported to the AI and the person', () async {
    final ai = FakeAi(
      plan: planOf([
        {
          'metric': 'task_summary',
          'params': {'day': '2026-10-20'},
        },
        {'metric': 'low_stock', 'params': <String, Object?>{}},
      ]),
      answer: const DataQuestionAnswer(answer: 'Two tasks were due.'),
    );
    final data = FakeData()..results['low_stock'] = const NetworkError();

    final outcome = await AskDataService(ai: ai, data: data)
        .ask(venueId: 'v', question: question, today: today);

    outcome as AskDataAnswered;
    expect(outcome.isPartial, isTrue);
    expect(outcome.executed.last.error, isNotNull);
    final sent = jsonDecode(ai.answerInput!) as Map<String, dynamic>;
    expect(((sent['results'] as List).last as Map)['error'], isNotNull);
  });

  test('when every call fails the real error is thrown, not an AI answer',
      () async {
    final ai = FakeAi(
      plan: planOf([
        {'metric': 'low_stock', 'params': <String, Object?>{}},
      ]),
    );
    final data = FakeData()..results['low_stock'] = const NetworkError();

    await expectLater(
      AskDataService(ai: ai, data: data)
          .ask(venueId: 'v', question: question, today: today),
      throwsA(isA<NetworkError>()),
    );
    expect(ai.answerCalls, 0);
  });

  test('a permission failure stops everything and surfaces', () async {
    final ai = FakeAi(
      plan: planOf([
        {'metric': 'low_stock', 'params': <String, Object?>{}},
        {
          'metric': 'task_summary',
          'params': {'day': '2026-10-20'},
        },
      ]),
    );
    final data = FakeData()
      ..results['low_stock'] = const PermissionDeniedError('no');

    await expectLater(
      AskDataService(ai: ai, data: data)
          .ask(venueId: 'v', question: question, today: today),
      throwsA(isA<PermissionDeniedError>()),
    );
    expect(data.ran, hasLength(1));
  });

  test('AI errors (disabled, declined, budget) propagate untouched', () async {
    final ai = FakeAi()
      ..planError = const AiUnavailableError('AI features are turned off.');
    final data = FakeData();

    await expectLater(
      AskDataService(ai: ai, data: data)
          .ask(venueId: 'v', question: question, today: today),
      throwsA(
        isA<AiUnavailableError>().having(
          (e) => e.message,
          'message',
          'AI features are turned off.',
        ),
      ),
    );
    expect(data.ran, isEmpty);
  });

  test('at most three calls run for a plan of five', () async {
    final ai = FakeAi(
      plan: planOf([
        for (var i = 0; i < 5; i++)
          {
            'metric': 'task_summary',
            'params': {'day': '2026-10-2$i'},
          },
      ]),
      answer: const DataQuestionAnswer(answer: 'ok'),
    );
    final data = FakeData();

    final outcome = await AskDataService(ai: ai, data: data)
        .ask(venueId: 'v', question: question, today: today);

    expect(data.ran, hasLength(3));
    expect((outcome as AskDataAnswered).dropped, hasLength(2));
  });

  test('a very long answer input is trimmed under the limit', () {
    final call = DataCatalogue.validatePlan(
      DataQuestionPlan(
        rawCalls: [
          {
            'metric': 'labour_hours',
            'params': {'day': '2026-10-20'},
          },
        ],
      ),
      today: today,
    ).calls.single;
    final rows = [
      for (var i = 0; i < 50; i++)
        {'bucket': 'Person number $i' * 4, 'worked_hours': 8.5 + i},
    ];

    final text = AskDataService.buildAnswerInput(
      question,
      [ExecutedDataCall(call: call, result: MetricResult(rows))],
      maxChars: 1500,
    );

    expect(text.length, lessThanOrEqualTo(1500));
    final decoded = jsonDecode(text) as Map<String, dynamic>;
    final first = (decoded['results'] as List).single as Map;
    expect(first['rows_omitted'], greaterThan(0));
  });
}

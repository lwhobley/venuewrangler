import 'dart:convert';

import '../../../core/errors/app_error.dart';
import '../data/ai_repository.dart';
import '../data/ask_data_repository.dart';
import '../domain/data_catalogue.dart';

/// One catalogue call that ran (or failed), with what it returned.
class ExecutedDataCall {
  const ExecutedDataCall({
    required this.call,
    this.result,
    this.error,
    this.failure,
  });

  final ValidatedDataCall call;
  final MetricResult? result;

  /// Why it produced no rows (shown to the person and told to the AI).
  final String? error;
  final AppError? failure;
}

sealed class AskDataOutcome {
  const AskDataOutcome();
}

class AskDataAnswered extends AskDataOutcome {
  const AskDataAnswered({
    required this.answer,
    this.caveats,
    required this.executed,
    this.dropped = const [],
  });

  final String answer;
  final String? caveats;
  final List<ExecutedDataCall> executed;

  /// Steps of the plan that were not run (not in the catalogue, invalid parameters, too many).
  final List<DroppedDataCall> dropped;

  /// Part of the question could not be looked up.
  bool get isPartial =>
      dropped.isNotEmpty || executed.any((e) => e.error != null);
}

class AskDataUnanswerable extends AskDataOutcome {
  const AskDataUnanswerable({this.reason, this.dropped = const []});

  final String? reason;
  final List<DroppedDataCall> dropped;
}

/// Orchestrates "Ask about your data": the AI picks catalogue metrics (call 1), this class
/// validates the plan and runs the surviving calls as the signed-in user, and the AI words the
/// answer from the aggregate rows only (call 2). The AI never sees raw records and never writes
/// queries; see features/ai/README.md.
class AskDataService {
  const AskDataService({required this.ai, required this.data});

  final AiRepository ai;
  final AskDataRepository data;

  /// The AI call's input limit is 20,000 characters; stay well inside it.
  static const maxAnswerInputChars = 16000;

  Future<AskDataOutcome> ask({
    required String venueId,
    required String question,
    required DateTime today,
  }) async {
    final planInput = jsonEncode({
      'question': question,
      'today': formatDataDate(today),
      'catalogue': DataCatalogue.toCatalogueJson(),
    });
    final plan = await ai.planDataQuestion(venueId: venueId, input: planInput);
    final validated = DataCatalogue.validatePlan(plan, today: today);
    if (validated.calls.isEmpty) {
      return AskDataUnanswerable(
        reason: validated.unanswerableReason,
        dropped: validated.dropped,
      );
    }

    final executed = await runCalls(venueId: venueId, calls: validated.calls);
    final failed = executed.where((e) => e.error != null).toList();
    if (failed.length == executed.length) {
      // Nothing to answer from: surface the real problem (permission, network) instead of
      // letting the AI talk about missing data.
      throw failed.first.failure ??
          const UnknownError('Could not look that up right now.');
    }

    final answer = await ai.answerDataQuestion(
      venueId: venueId,
      input: buildAnswerInput(question, executed),
    );
    return AskDataAnswered(
      answer: answer.answer,
      caveats: answer.caveats,
      executed: executed,
      dropped: validated.dropped,
    );
  }

  /// Runs [calls] one after another as the signed-in user. A permission failure stops
  /// everything; other failures are kept per call so the rest can still answer.
  Future<List<ExecutedDataCall>> runCalls({
    required String venueId,
    required List<ValidatedDataCall> calls,
  }) async {
    final executed = <ExecutedDataCall>[];
    for (final call in calls) {
      try {
        final result = await data.run(venueId: venueId, call: call);
        executed.add(ExecutedDataCall(call: call, result: result));
      } on PermissionDeniedError {
        rethrow;
      } on AppError catch (e) {
        executed.add(
          ExecutedDataCall(call: call, error: e.message, failure: e),
        );
      }
    }
    return executed;
  }

  /// The input of `data_question_answer`: the question and, per call, the metric, the
  /// parameters actually used and the aggregate rows (or the reason there are none). Rows are
  /// trimmed evenly if the whole would be too long.
  static String buildAnswerInput(
    String question,
    List<ExecutedDataCall> executed, {
    int maxChars = maxAnswerInputChars,
  }) {
    var keep = kMaxDataRows;
    while (true) {
      final results = [
        for (final e in executed)
          {
            'metric': e.call.metric.name,
            'params': e.call.describeParams(),
            if (e.error != null)
              'error': e.error
            else ...{
              'rows': e.result!.rows.take(keep).toList(),
              if (e.result!.rows.length > keep)
                'rows_omitted': e.result!.rows.length - keep,
            },
          },
      ];
      final text = jsonEncode({'question': question, 'results': results});
      if (text.length <= maxChars || keep <= 1) return text;
      keep = keep ~/ 2;
    }
  }
}

import '../../../core/errors/app_error.dart';
import '../data/ask_data_repository.dart';
import '../domain/ai_models.dart';
import '../domain/data_catalogue.dart';

/// One figure of the non-AI "Quick numbers" list, or why it could not be loaded.
class QuickNumber {
  const QuickNumber({required this.label, this.value, this.detail, this.error});

  final String label;
  final String? value;
  final String? detail;
  final String? error;
}

/// A few default catalogue metrics run directly (no AI, nothing leaves the app's own Supabase
/// session), so the screen is useful when AI is off, declined or unavailable. They go through the
/// same validation and the same manager-only functions as AI-picked calls.
class QuickNumbers {
  const QuickNumbers._();

  /// Venue-local [today] in, three figures out: tonight's covers, this week's hours and
  /// unresolved incidents over the last 93 days.
  static Future<List<QuickNumber>> load({
    required AskDataRepository data,
    required String venueId,
    required DateTime today,
  }) async {
    final day = DateTime.utc(today.year, today.month, today.day);
    final monday = day.subtract(Duration(days: day.weekday - DateTime.monday));
    final since = day.subtract(const Duration(days: kMaxDataRangeDays - 1));
    return [
      await _one(
        data,
        venueId,
        today: day,
        label: 'Covers today',
        call: {
          'metric': 'reservation_summary',
          'params': {'day': formatDataDate(day), 'group_by': 'total'},
        },
        build: (rows) {
          final row = rows.first;
          return (
            value: '${_num(row['covers']).round()}',
            detail: '${_num(row['reservation_count']).round()} reservations, '
                '${_num(row['served_covers']).round()} covers seated or done',
          );
        },
      ),
      await _one(
        data,
        venueId,
        today: day,
        label: 'Hours this week',
        call: {
          'metric': 'labour_hours',
          'params': {
            'from': formatDataDate(monday),
            'to': formatDataDate(day),
            'group_by': 'total',
          },
        },
        build: (rows) {
          final row = rows.first;
          final open = _num(row['open_punch_count']).round();
          return (
            value: '${_num(row['worked_hours'])} h',
            detail: 'Monday to today, closed punches only'
                '${open > 0 ? ', $open still clocked in' : ''}',
          );
        },
      ),
      await _one(
        data,
        venueId,
        today: day,
        label: 'Unresolved incidents',
        call: {
          'metric': 'incident_summary',
          'params': {
            'from': formatDataDate(since),
            'to': formatDataDate(day),
            'group_by': 'status',
          },
        },
        build: (rows) {
          final open = rows.fold<num>(
            0,
            (sum, row) => sum + _num(row['unresolved_count']),
          );
          return (
            value: '${open.round()}',
            detail: 'Reported in the last $kMaxDataRangeDays days, '
                'open or investigating',
          );
        },
      ),
    ];
  }

  static Future<QuickNumber> _one(
    AskDataRepository data,
    String venueId, {
    required DateTime today,
    required String label,
    required Map<String, Object?> call,
    required ({String value, String detail}) Function(
      List<Map<String, Object?>> rows,
    ) build,
  }) async {
    final plan = DataCatalogue.validatePlan(
      DataQuestionPlan(rawCalls: [call]),
      today: today,
    );
    if (plan.calls.isEmpty) {
      return QuickNumber(label: label, error: 'Not available');
    }
    try {
      final result = await data.run(venueId: venueId, call: plan.calls.first);
      if (result.rows.isEmpty) {
        return QuickNumber(label: label, value: '0');
      }
      final built = build(result.rows);
      return QuickNumber(
        label: label,
        value: built.value,
        detail: built.detail,
      );
    } on AppError catch (e) {
      return QuickNumber(label: label, error: e.message);
    }
  }

  static num _num(Object? value) => switch (value) {
        final num n => n,
        final String s => num.tryParse(s) ?? 0,
        _ => 0,
      };
}

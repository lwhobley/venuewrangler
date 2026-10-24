/// The fixed catalogue behind "Ask about your data". The AI never writes queries: it can only
/// pick metrics from this list, and every pick is validated here before anything runs. Each
/// metric is one read-only Postgres function `public.ask_data_<name>` (see
/// supabase/migrations/20261024120002_ask_data_metrics.sql); keep the two in step. The functions
/// authorise the caller and cap ranges and rows themselves, so a plan that slipped past this
/// validation still could not read anything a manager of the venue may not see.
library;

import 'ai_models.dart';

/// Most calls one question may use.
const kMaxDataCalls = 3;

/// Widest date range (inclusive days) a metric accepts; the SQL functions enforce the same.
const kMaxDataRangeDays = 93;

/// Most rows one metric returns; the SQL functions enforce the same.
const kMaxDataRows = 50;

enum DataParamKind { enumeration, limit }

/// A parameter of a metric beyond the date range, with the only values it may take.
class DataParam {
  const DataParam.enumeration(
    this.name,
    this.values, {
    this.defaultValue,
    required this.description,
  })  : kind = DataParamKind.enumeration,
        defaultLimit = null;

  const DataParam.limit({this.defaultLimit, required this.description})
      : name = 'limit',
        kind = DataParamKind.limit,
        values = const [],
        defaultValue = null;

  /// The key in the plan and the suffix of the SQL parameter (`p_<name>`).
  final String name;
  final DataParamKind kind;
  final List<String> values;
  final String? defaultValue;
  final int? defaultLimit;
  final String description;
}

class DataMetric {
  const DataMetric({
    required this.name,
    required this.title,
    required this.description,
    this.hasDateRange = true,
    this.params = const [],
  });

  /// What the AI calls it; the SQL function is `ask_data_<name>`.
  final String name;

  /// What the manager sees in "How I got this".
  final String title;
  final String description;

  /// Takes venue-local dates `from` and `to` (inclusive), or a single `day`.
  final bool hasDateRange;
  final List<DataParam> params;

  String get rpcName => 'ask_data_$name';

  /// The part of the catalogue the AI sees: names, descriptions and parameter schemas. Never data.
  Map<String, Object?> toCatalogueJson() => {
        'name': name,
        'description': description,
        'params': {
          if (hasDateRange) ...{
            'from':
                'date YYYY-MM-DD (venue-local, inclusive), required unless day is given',
            'to':
                'date YYYY-MM-DD (venue-local, inclusive), required unless day is given',
            'day': 'date YYYY-MM-DD, shorthand for from = to = that day',
          },
          for (final p in params)
            p.name: switch (p.kind) {
              DataParamKind.enumeration => {
                  'type': 'enum',
                  'values': p.values,
                  if (p.defaultValue != null) 'default': p.defaultValue,
                  'description': p.description,
                },
              DataParamKind.limit => {
                  'type': 'integer',
                  'min': 1,
                  'max': kMaxDataRows,
                  'description': p.description,
                },
            },
        },
      };
}

/// A catalogue call that passed validation: only whitelisted, type-checked, clamped values.
class ValidatedDataCall {
  const ValidatedDataCall({
    required this.metric,
    this.from,
    this.to,
    this.values = const {},
    this.notes = const [],
  });

  final DataMetric metric;

  /// Venue-local calendar dates (UTC-flagged year/month/day, no time of day).
  final DateTime? from;
  final DateTime? to;

  /// Enum and limit values by parameter name.
  final Map<String, Object> values;

  /// Adjustments made while validating (a range shortened, a limit lowered), shown to the user.
  final List<String> notes;

  /// Arguments for `public.ask_data_<metric>`. The venue always comes from the caller.
  Map<String, Object> rpcParams(String venueId) => {
        'p_venue_id': venueId,
        if (from != null) 'p_from': formatDataDate(from!),
        if (to != null) 'p_to': formatDataDate(to!),
        for (final entry in values.entries) 'p_${entry.key}': entry.value,
      };

  /// The parameters as shown to the person and sent to the AI with the results.
  Map<String, Object> describeParams() => {
        if (from != null) 'from': formatDataDate(from!),
        if (to != null) 'to': formatDataDate(to!),
        ...values,
      };
}

/// A call from the plan that was not run, with a short reason for the person.
class DroppedDataCall {
  const DroppedDataCall({required this.label, required this.reason});

  final String label;
  final String reason;
}

class ValidatedDataPlan {
  const ValidatedDataPlan({
    this.calls = const [],
    this.dropped = const [],
    this.unanswerableReason,
  });

  final List<ValidatedDataCall> calls;
  final List<DroppedDataCall> dropped;
  final String? unanswerableReason;
}

String formatDataDate(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-'
    '${date.month.toString().padLeft(2, '0')}-'
    '${date.day.toString().padLeft(2, '0')}';

final _isoDate = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$');

/// Parses a strict `YYYY-MM-DD` that is a real calendar date, else null.
DateTime? parseDataDate(Object? raw) {
  if (raw is! String) return null;
  final match = _isoDate.firstMatch(raw.trim());
  if (match == null) return null;
  final y = int.parse(match.group(1)!);
  final m = int.parse(match.group(2)!);
  final d = int.parse(match.group(3)!);
  final date = DateTime.utc(y, m, d);
  if (date.year != y || date.month != m || date.day != d) return null;
  return date;
}

/// Text from the model shown back to the person: single line, bounded, no control characters.
String _tidy(Object? raw, [int max = 40]) {
  final text = '$raw'.replaceAll(RegExp(r'[\x00-\x1F\x7F]+'), ' ').trim();
  return text.length <= max ? text : '${text.substring(0, max)}...';
}

class DataCatalogue {
  const DataCatalogue._();

  static const _limit = DataParam.limit(
    description: 'most rows to return',
  );

  /// Catalogue v1. Eleven read-only metrics; all manager-only and scoped to the active venue.
  static const metrics = <DataMetric>[
    DataMetric(
      name: 'reservation_summary',
      title: 'Reservations',
      description:
          'Reservation counts and covers (party-size totals), covers actually served '
          '(seated or completed), no-shows, cancellations and the no-show and cancel rates, '
          'by reservation date. Use group_by total for one overall figure, day for a daily '
          'breakdown, status for counts per status.',
      params: [
        DataParam.enumeration(
          'group_by',
          ['total', 'day', 'status'],
          defaultValue: 'total',
          description: 'how to group the rows',
        ),
        _limit,
      ],
    ),
    DataMetric(
      name: 'private_event_summary',
      title: 'Private events',
      description:
          'Private events (BEOs) by event date: number of events, guests and '
          'itemised charges in cents (net of discounts), grouped by status or month. '
          'Cancelled events are left out of month groups unless status is cancelled.',
      params: [
        DataParam.enumeration(
          'group_by',
          ['status', 'month'],
          defaultValue: 'status',
          description: 'how to group the rows',
        ),
        DataParam.enumeration(
          'status',
          ['draft', 'sent', 'reviewed', 'confirmed', 'amended', 'cancelled'],
          description: 'only events with this status (optional)',
        ),
        _limit,
      ],
    ),
    DataMetric(
      name: 'labour_hours',
      title: 'Hours worked',
      description:
          'Hours worked from closed time-clock punches (unpaid breaks removed), per '
          'person, per day or in total, with punch counts and punches still open. No pay '
          'rates or wages. Use group_by person with a small limit for "who worked the most".',
      params: [
        DataParam.enumeration(
          'group_by',
          ['person', 'day', 'total'],
          defaultValue: 'person',
          description: 'how to group the rows',
        ),
        _limit,
      ],
    ),
    DataMetric(
      name: 'labour_overtime',
      title: 'Overtime',
      description:
          'People with more than 40 worked hours in a Monday-Sunday week, with '
          'worked and overtime hours per person per week. Whole weeks overlapping the dates '
          'are judged.',
      params: [_limit],
    ),
    DataMetric(
      name: 'missed_clock_outs',
      title: 'Missed clock-outs',
      description:
          'Punches that began in the range and are still open more than 16 hours '
          'later, per person with the day and hours open.',
      params: [_limit],
    ),
    DataMetric(
      name: 'shift_hours',
      title: 'Scheduled shifts',
      description:
          'Scheduled (not cancelled) shift hours and shift counts per person, per '
          'day or in total, including open shifts nobody is assigned to.',
      params: [
        DataParam.enumeration(
          'group_by',
          ['person', 'day', 'total'],
          defaultValue: 'person',
          description: 'how to group the rows',
        ),
        _limit,
      ],
    ),
    DataMetric(
      name: 'incident_summary',
      title: 'Incidents',
      description:
          'Number of incidents reported in the range, and how many are unresolved, '
          'grouped by severity, status or day. Counts only, never the details.',
      params: [
        DataParam.enumeration(
          'group_by',
          ['severity', 'status', 'day'],
          defaultValue: 'severity',
          description: 'how to group the rows',
        ),
        _limit,
      ],
    ),
    DataMetric(
      name: 'low_stock',
      title: 'Low stock',
      description:
          'Active inventory items whose counted stock is below their par level, '
          'with quantity, par and shortfall. Current state; takes no dates.',
      hasDateRange: false,
      params: [
        DataParam.limit(defaultLimit: 25, description: 'most items to list'),
      ],
    ),
    DataMetric(
      name: 'inventory_variance',
      title: 'Count variance',
      description:
          'Results of completed inventory counts in the range: counts done, items '
          'counted, items with a variance, net variance value and shortfall value.',
      params: [
        DataParam.enumeration(
          'group_by',
          ['total', 'day'],
          defaultValue: 'total',
          description: 'how to group the rows',
        ),
        _limit,
      ],
    ),
    DataMetric(
      name: 'task_summary',
      title: 'Tasks',
      description:
          'Tasks due in the range: how many were due, completed, overdue or still '
          'open, plus tasks completed in the range. Counts only.',
    ),
    DataMetric(
      name: 'pos_sales_summary',
      title: 'POS sales',
      description:
          'Closed POS checks in the range: number of checks, covers, subtotal, tax, '
          'tips and total in cents, overall or by day. Empty when no POS is connected.',
      params: [
        DataParam.enumeration(
          'group_by',
          ['total', 'day'],
          defaultValue: 'total',
          description: 'how to group the rows',
        ),
        _limit,
      ],
    ),
  ];

  static DataMetric? byName(Object? name) {
    if (name is! String) return null;
    final wanted = name.trim();
    for (final m in metrics) {
      if (m.name == wanted) return m;
    }
    return null;
  }

  /// The catalogue as the AI sees it.
  static List<Map<String, Object?>> toCatalogueJson() =>
      [for (final m in metrics) m.toCatalogueJson()];

  /// Turns the model's untrusted plan into calls that may run. Anything not in the catalogue
  /// is dropped; parameters are whitelisted, type-checked and clamped; dates must be real
  /// calendar dates from 2000 to [today] + 366 days; ranges over 93 days are
  /// shortened to the 93 days ending at `to`; at most [kMaxDataCalls] calls survive.
  static ValidatedDataPlan validatePlan(
    DataQuestionPlan plan, {
    required DateTime today,
  }) {
    final calls = <ValidatedDataCall>[];
    final dropped = <DroppedDataCall>[];
    final day = DateTime.utc(today.year, today.month, today.day);

    for (final raw in plan.rawCalls) {
      if (raw is! Map) {
        dropped.add(
          const DroppedDataCall(
            label: 'A step',
            reason: 'it was not a valid request',
          ),
        );
        continue;
      }
      final metric = byName(raw['metric']);
      if (metric == null) {
        dropped.add(
          DroppedDataCall(
            label:
                _tidy(raw['metric']).isEmpty ? 'A step' : _tidy(raw['metric']),
            reason: 'that is not one of the reports I can run',
          ),
        );
        continue;
      }
      if (calls.length >= kMaxDataCalls) {
        dropped.add(
          DroppedDataCall(
            label: metric.title,
            reason: 'a question can use at most $kMaxDataCalls reports',
          ),
        );
        continue;
      }
      final paramsRaw = raw['params'];
      final params = paramsRaw is Map ? paramsRaw : const <Object?, Object?>{};
      final result = _validateCall(metric, params, day);
      switch (result) {
        case _Ok(:final call):
          calls.add(call);
        case _Rejected(:final reason):
          dropped.add(DroppedDataCall(label: metric.title, reason: reason));
      }
    }
    return ValidatedDataPlan(
      calls: List.unmodifiable(calls),
      dropped: List.unmodifiable(dropped),
      unanswerableReason: plan.unanswerableReason == null
          ? null
          : _tidy(plan.unanswerableReason, 200),
    );
  }

  static Object _validateRange(
    Map<Object?, Object?> params,
    DateTime today,
    List<String> notes,
  ) {
    final DateTime? parsedFrom;
    final DateTime? parsedTo;
    if (params['from'] != null || params['to'] != null) {
      parsedFrom = parseDataDate(params['from']);
      parsedTo = parseDataDate(params['to']);
      if (parsedFrom == null || parsedTo == null) {
        return const _BadRange('its dates were missing or not valid');
      }
    } else if (params['day'] != null) {
      parsedFrom = parsedTo = parseDataDate(params['day']);
      if (parsedFrom == null) return const _BadRange('its date was not valid');
    } else {
      return const _BadRange('it needed a date or date range');
    }
    var from = parsedFrom;
    final to = parsedTo!;
    final earliest = DateTime.utc(2000);
    final latest = today.add(const Duration(days: 366));
    if (from.isBefore(earliest) ||
        to.isBefore(earliest) ||
        from.isAfter(latest) ||
        to.isAfter(latest)) {
      return const _BadRange('its dates were out of range');
    }
    if (to.isBefore(from)) {
      return const _BadRange('its date range ended before it started');
    }
    if (to.difference(from).inDays + 1 > kMaxDataRangeDays) {
      from = to.subtract(const Duration(days: kMaxDataRangeDays - 1));
      notes.add(
        'The range was longer than $kMaxDataRangeDays days, so only the '
        '$kMaxDataRangeDays days ending ${formatDataDate(to)} were used.',
      );
    }
    return _GoodRange((from, to));
  }

  static _CallResult _validateCall(
    DataMetric metric,
    Map<Object?, Object?> params,
    DateTime today,
  ) {
    final notes = <String>[];
    DateTime? from;
    DateTime? to;

    if (metric.hasDateRange) {
      final range = _validateRange(params, today, notes);
      if (range is _BadRange) return _Rejected(range.reason);
      (from, to) = (range as _GoodRange).dates;
    }

    final values = <String, Object>{};
    for (final p in metric.params) {
      final raw = params[p.name];
      switch (p.kind) {
        case DataParamKind.enumeration:
          if (raw == null) {
            if (p.defaultValue != null) values[p.name] = p.defaultValue!;
            continue;
          }
          final value = raw is String ? raw.trim().toLowerCase() : null;
          if (value == null || !p.values.contains(value)) {
            return _Rejected('${p.name} "${_tidy(raw, 24)}" is not supported');
          }
          values[p.name] = value;
        case DataParamKind.limit:
          if (raw == null) {
            if (p.defaultLimit != null) values[p.name] = p.defaultLimit!;
            continue;
          }
          final number = switch (raw) {
            final int i => i,
            final double d when d == d.roundToDouble() && d.isFinite =>
              d.toInt(),
            _ => null,
          };
          if (number == null) {
            return const _Rejected('its row limit was not a whole number');
          }
          final clamped = number.clamp(1, kMaxDataRows);
          if (clamped != number) {
            notes.add('The row limit was adjusted to $clamped.');
          }
          values[p.name] = clamped;
      }
    }

    return _Ok(
      ValidatedDataCall(
        metric: metric,
        from: from,
        to: to,
        values: Map.unmodifiable(values),
        notes: List.unmodifiable(notes),
      ),
    );
  }
}

sealed class _CallResult {
  const _CallResult();
}

class _Ok extends _CallResult {
  const _Ok(this.call);

  final ValidatedDataCall call;
}

class _Rejected extends _CallResult {
  const _Rejected(this.reason);

  final String reason;
}

class _GoodRange {
  const _GoodRange(this.dates);

  final (DateTime, DateTime) dates;
}

class _BadRange {
  const _BadRange(this.reason);

  final String reason;
}

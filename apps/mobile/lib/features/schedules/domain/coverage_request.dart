import '../../ai/domain/ai_models.dart';
import '../../workforce/domain/workforce_models.dart';

/// The roster sent with a "Suggest coverage" request. Each person gets a short key
/// (`staff_1`, `staff_2`, …) instead of their internal user id: the model copies the key back
/// into `staff_id`, and [resolve] turns a suggestion into a real roster member — by key, then
/// by exact name — so the "Add shift" dialog can name the suggested person (launch review U8).
class CoverageRoster {
  CoverageRoster(Iterable<RosterMember> members)
      : _byKey = {
          for (final (i, m) in members.indexed) 'staff_${i + 1}': m,
        };

  final Map<String, RosterMember> _byKey;

  static String _name(RosterMember m) =>
      (m.displayName ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();

  /// One line per named person: `- staff_id: staff_1 | name: Victor Yang`.
  String describe() => [
        for (final e in _byKey.entries)
          if (_name(e.value).isNotEmpty)
            '- staff_id: ${e.key} | name: ${_name(e.value)}',
      ].join('\n');

  RosterMember? resolve(ShiftSuggestion suggestion) {
    final byKey = _byKey[suggestion.staffId.trim()];
    if (byKey != null) return byKey;
    for (final candidate in [suggestion.staffName, suggestion.staffId]) {
      final wanted = (candidate ?? '').trim().toLowerCase();
      if (wanted.isEmpty) continue;
      for (final m in _byKey.values) {
        if (m.userId == candidate || _name(m).toLowerCase() == wanted) return m;
      }
    }
    return null;
  }
}

const _weekdays = [
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
];

/// The text sent to the assistant: the manager's own description, then today's venue date (so
/// "Sunday" resolves to the right year) and the roster keys to answer with.
String coverageRequestInput({
  required String request,
  required CoverageRoster roster,
  required DateTime todayWall,
  required String timezoneId,
}) {
  String two(int n) => n.toString().padLeft(2, '0');
  final date =
      '${todayWall.year}-${two(todayWall.month)}-${two(todayWall.day)}';
  final team = roster.describe();
  return [
    request.trim(),
    '',
    '---',
    'Today is ${_weekdays[todayWall.weekday - 1]} $date at the venue '
        '(time zone $timezoneId). Give times as venue-local ISO 8601 without an offset.',
    if (team.isNotEmpty) ...[
      'Roster (answer with the staff_id key exactly as listed):',
      team,
    ],
  ].join('\n');
}

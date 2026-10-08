import 'package:flutter_test/flutter_test.dart';
import 'package:venuewrangler_mobile/features/organizations/domain/workspace_timezones.dart';

/// A DateTime whose timeZoneName is what we want, without depending on the machine's zone.
class _NamedZoneTime implements DateTime {
  _NamedZoneTime(this.timeZoneName);

  @override
  final String timeZoneName;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('every offered zone is distinct', () {
    final ids = kWorkspaceTimezones.map((z) => z.id).toList();
    expect(ids.toSet(), hasLength(ids.length));
  });

  test('every guess can actually be selected in the picker', () {
    final offered = kWorkspaceTimezones.map((z) => z.id).toSet();
    for (final name in [
      'EST', 'EDT', 'CDT', 'MDT', 'PST', 'PDT', 'AKST', 'AKDT', //
      'HST', 'GMT', 'BST', 'CET', 'CEST', 'AEST', 'AEDT',
      'Central Daylight Time', 'Pacific Standard Time',
    ]) {
      final guess = guessWorkspaceTimezone(_NamedZoneTime(name) as DateTime);
      expect(guess, isNotNull, reason: name);
      expect(offered, contains(guess), reason: name);
    }
  });

  test('a US abbreviation maps to the matching US zone', () {
    expect(
      guessWorkspaceTimezone(_NamedZoneTime('CDT') as DateTime),
      'America/Chicago',
    );
    expect(
      guessWorkspaceTimezone(_NamedZoneTime('PST') as DateTime),
      'America/Los_Angeles',
    );
  });

  test('look-alike long names are not mistaken for US zones', () {
    expect(
      guessWorkspaceTimezone(
        _NamedZoneTime('Australian Eastern Daylight Time') as DateTime,
      ),
      isNull,
    );
    expect(
      guessWorkspaceTimezone(
        _NamedZoneTime('Central European Standard Time') as DateTime,
      ),
      isNull,
    );
  });

  test('an unrecognised zone yields no guess, so the person must choose', () {
    expect(guessWorkspaceTimezone(_NamedZoneTime('+0530') as DateTime), isNull);
    expect(guessWorkspaceTimezone(_NamedZoneTime('CST') as DateTime), isNull);
    expect(guessWorkspaceTimezone(_NamedZoneTime('MST') as DateTime), isNull);
  });
}

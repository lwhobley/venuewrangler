import 'package:flutter_test/flutter_test.dart';
import 'package:venuewrangler_mobile/features/workforce/domain/workforce_models.dart';

void main() {
  test('parses a public.venue_roster row', () {
    final member = RosterMember.fromJson(const {
      'user_id': 'u1',
      'role': 'venue_manager',
      'display_name': 'Mia Manager',
    });

    expect(member.userId, 'u1');
    expect(member.role, 'venue_manager');
    expect(member.displayName, 'Mia Manager');
  });

  test('a member without a profile name has a null display name', () {
    final member = RosterMember.fromJson(const {
      'user_id': 'u2',
      'role': 'staff',
      'display_name': null,
    });

    expect(member.displayName, isNull);
  });
}

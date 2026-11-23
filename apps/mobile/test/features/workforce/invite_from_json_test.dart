import 'package:flutter_test/flutter_test.dart';
import 'package:venuewrangler_mobile/features/workforce/domain/workforce_models.dart';

void main() {
  group('Invite.tryFromJson', () {
    final base = <String, dynamic>{
      'id': 'invite-1',
      'venue_id': 'venue-1',
      'email': 'staff@example.com',
      'role': 'staff',
      'status': 'pending',
      'created_at': '2026-01-01T00:00:00.000Z',
    };

    test('parses known roles', () {
      final invite = Invite.tryFromJson(base);
      expect(invite, isNotNull);
      expect(invite!.role, WorkforceRole.staff);
      expect(invite.status, InviteStatus.pending);
    });

    test('returns null for unknown roles instead of throwing', () {
      expect(Invite.tryFromJson({...base, 'role': 'legacy_bartender'}), isNull);
      expect(WorkforceRole.tryFromDb('legacy_bartender'), isNull);
    });

    test('returns null for unknown status', () {
      expect(Invite.tryFromJson({...base, 'status': 'mystery'}), isNull);
    });
  });
}

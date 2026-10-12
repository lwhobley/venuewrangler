import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:venuewrangler_mobile/core/errors/unapplied_update.dart';

void main() {
  test('an update refused by policy on an existing row is a 42501 denial',
      () async {
    await expectLater(
      throwForUnappliedUpdate(
        rowExists: () async => true,
        denialMessage: 'Shift update was not applied',
      ),
      throwsA(
        isA<PostgrestException>().having((e) => e.code, 'code', '42501').having(
              (e) => e.message,
              'message',
              'Shift update was not applied',
            ),
      ),
    );
  });

  test('an update on a row that no longer exists is reported as not found',
      () async {
    await expectLater(
      throwForUnappliedUpdate(
        rowExists: () async => false,
        denialMessage: 'Swap acceptance was not applied',
      ),
      throwsA(
        isA<PostgrestException>()
            .having((e) => e.code, 'code', 'PGRST116')
            .having((e) => e.code, 'code', isNot('42501')),
      ),
    );
  });

  test('the re-check runs exactly once', () async {
    var checks = 0;
    await expectLater(
      throwForUnappliedUpdate(
        rowExists: () async {
          checks++;
          return true;
        },
        denialMessage: 'denied',
      ),
      throwsA(isA<PostgrestException>()),
    );
    expect(checks, 1);
  });
}

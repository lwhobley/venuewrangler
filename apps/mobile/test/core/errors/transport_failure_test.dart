import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:venuewrangler_mobile/core/errors/transport_failure.dart';

void main() {
  group('isMissingRpc', () {
    test('recognizes PostgREST schema-cache miss and undefined_function', () {
      expect(
        isMissingRpc(
          const PostgrestException(message: 'missing', code: 'PGRST202'),
        ),
        isTrue,
      );
      expect(
        isMissingRpc(
          const PostgrestException(message: 'missing', code: '42883'),
        ),
        isTrue,
      );
    });

    test('does not treat auth or RLS errors as missing RPC', () {
      expect(
        isMissingRpc(
          const PostgrestException(message: 'denied', code: '42501'),
        ),
        isFalse,
      );
      expect(isMissingRpc(Exception('offline')), isFalse);
    });
  });
}

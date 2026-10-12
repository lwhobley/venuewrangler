import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:venuewrangler_mobile/core/errors/transport_failure.dart';

class BrowserTransportFailure extends ClientException {
  BrowserTransportFailure() : super('Failed to fetch');
}

void main() {
  test('HTTP failures are retryable regardless of concrete class name', () {
    expect(isTransportFailure(ClientException('Failed to fetch')), isTrue);
    expect(isTransportFailure(BrowserTransportFailure()), isTrue);
    expect(isTransportFailure(TimeoutException('No response')), isTrue);
  });

  test('authorization and validation rejections must not be queued', () {
    for (final code in ['42501', '23505', '22023']) {
      expect(
        isTransportFailure(PostgrestException(message: 'Rejected', code: code)),
        isFalse,
      );
    }
    expect(isTransportFailure(StateError('Session changed')), isFalse);
  });
}

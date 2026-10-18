import 'package:flutter_test/flutter_test.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:venuewrangler_mobile/core/errors/sentry_scrubber.dart';

const _jwt =
    'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk';

void main() {
  group('scrubSensitiveText', () {
    test('redacts JWTs, including a bare header segment', () {
      expect(scrubSensitiveText('token=$_jwt&x=1'), 'token=[jwt]&x=1');
      expect(
        scrubSensitiveText('partial eyJhbGciOiJIUzI1NiJ9 leaked'),
        'partial [jwt] leaked',
      );
    });

    test('redacts bearer tokens', () {
      expect(
        scrubSensitiveText('Authorization: Bearer abc.def-123_x'),
        'Authorization: Bearer [token]',
      );
    });

    test('redacts email addresses, plain and URL-encoded', () {
      expect(
        scrubSensitiveText('invite for jane.doe+vip@example.co.uk failed'),
        'invite for [email] failed',
      );
      expect(
        scrubSensitiveText('GET /rest/v1/profiles?email=eq.jane%40example.com'),
        'GET /rest/v1/profiles?email=[email]',
      );
    });

    test('keeps the column but drops the value from Key (col)=(value)', () {
      expect(
        scrubSensitiveText(
          'duplicate key value violates unique constraint "u_email". '
          'Key (email)=(jane@example.com) already exists.',
        ),
        'duplicate key value violates unique constraint "u_email". '
        'Key (email)=([redacted]) already exists.',
      );
      expect(
        scrubSensitiveText('Key (venue_id, phone)=(v1, (555) 010-0000) exists'),
        'Key (venue_id, phone)=([redacted]) exists',
      );
    });

    test('redacts the full row echoed by a NOT NULL violation', () {
      expect(
        scrubSensitiveText(
          'DETAIL: Failing row contains (1, Jane Doe, 555-0100, null).',
        ),
        'DETAIL: Failing row contains ([redacted]).',
      );
    });

    test('leaves ordinary text alone', () {
      const text = 'Could not load tasks for venue 42 (timeout after 15s)';
      expect(scrubSensitiveText(text), text);
    });
  });

  group('scrubBreadcrumb', () {
    test('scrubs the message and nested string data', () {
      final crumb = Breadcrumb(
        message: 'sign in failed for jane@example.com',
        data: {
          'url': 'https://x.supabase.co/auth?access_token=$_jwt',
          'nested': {
            'list': ['Key (email)=(a@b.com) already exists'],
          },
          'count': 3,
        },
      );

      final result = scrubBreadcrumb(crumb, Hint());

      expect(result!.message, 'sign in failed for [email]');
      expect(
        result.data!['url'],
        'https://x.supabase.co/auth?access_token=[jwt]',
      );
      expect(
        ((result.data!['nested'] as Map)['list'] as List).single,
        'Key (email)=([redacted]) already exists',
      );
      expect(result.data!['count'], 3);
    });

    test('passes a null breadcrumb through', () {
      expect(scrubBreadcrumb(null, Hint()), isNull);
    });
  });

  group('scrubSentryEvent', () {
    test('scrubs exception values, message, breadcrumbs, extra and tags', () {
      final event = SentryEvent(
        message: SentryMessage(
          'Failed for jane@example.com',
          template: 'Failed for %s',
          params: ['jane@example.com'],
        ),
        exceptions: [
          SentryException(
            type: 'PostgrestException',
            value: 'Key (email)=(jane@example.com) already exists.',
          ),
        ],
        breadcrumbs: [Breadcrumb(message: 'token $_jwt')],
        // ignore: deprecated_member_use
        extra: {'jwt': _jwt},
        tags: {'who': 'jane@example.com'},
      );

      final result = scrubSentryEvent(event, Hint())!;

      expect(result.message!.formatted, 'Failed for [email]');
      expect(result.message!.params, ['[email]']);
      expect(
        result.exceptions!.single.value,
        'Key (email)=([redacted]) already exists.',
      );
      expect(result.breadcrumbs!.single.message, 'token [jwt]');
      // ignore: deprecated_member_use
      expect(result.extra!['jwt'], '[jwt]');
      expect(result.tags!['who'], '[email]');
    });

    test('drops credential headers case-insensitively and token params', () {
      final event = SentryEvent(
        request: SentryRequest(
          url: 'https://x.supabase.co/path?token=abc&keep=1',
          headers: {
            'authorization': 'Bearer $_jwt',
            'ApiKey': 'k',
            'Accept': 'application/json',
          },
        ),
      );

      final request = scrubSentryEvent(event, Hint())!.request!;

      expect(request.headers, {'Accept': 'application/json'});
      expect(request.url, 'https://x.supabase.co/path?keep=1');
    });

    test('an event with nothing sensitive is returned unchanged', () {
      final event = SentryEvent(
        exceptions: [SentryException(type: 'StateError', value: 'Bad state')],
      );

      expect(scrubSentryEvent(event, Hint()), same(event));
      expect(event.exceptions!.single.value, 'Bad state');
    });
  });
}

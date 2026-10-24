import 'package:flutter_test/flutter_test.dart';
import 'package:venuewrangler_mobile/features/ai/domain/ai_models.dart';

void main() {
  group('HandoverSummaryResult', () {
    test('parses a normal response and renders text', () {
      final r = HandoverSummaryResult.fromJson({
        'summary': 'Busy night, one incident.',
        'sections': [
          {
            'title': 'Incidents',
            'items': ['High: fight at the bar (open)'],
          },
          {
            'title': 'Open to-dos',
            'items': ['Order limes', 'Fix tap'],
          },
        ],
      });
      expect(r.sections, hasLength(2));
      expect(
        r.toText(),
        'Busy night, one incident.\n\nIncidents\n- High: fight at the bar '
        '(open)\n\nOpen to-dos\n- Order limes\n- Fix tap',
      );
    });

    test('tolerates missing, wrong-typed and extra fields', () {
      final r = HandoverSummaryResult.fromJson({
        'summary': 42,
        'sections': [
          'oops',
          {'title': 'No items'},
          {
            'title': 'Mixed',
            'items': ['ok', 7, null, '  '],
            'extra': true,
          },
          {
            'items': ['no title'],
          },
        ],
        'unexpected': {'a': 1},
      });
      expect(r.summary, '');
      expect(r.sections, hasLength(1));
      expect(r.sections.single.items, ['ok']);
      expect(HandoverSummaryResult.fromJson({}).isEmpty, isTrue);
      expect(HandoverSummaryResult.fromJson({'sections': 'x'}).isEmpty, isTrue);
    });

    test('caps sections, items and lengths', () {
      final r = HandoverSummaryResult.fromJson({
        'summary': 'x' * 5000,
        'sections': [
          for (var i = 0; i < 40; i++)
            {
              'title': 'T$i',
              'items': [for (var j = 0; j < 50; j++) 'y' * 1000],
            },
        ],
      });
      expect(r.summary.length, lessThanOrEqualTo(600));
      expect(r.sections, hasLength(12));
      expect(r.sections.first.items, hasLength(20));
      expect(r.sections.first.items.first.length, lessThanOrEqualTo(300));
    });
  });

  group('EventEnquiryResult', () {
    test('parses a full extraction', () {
      final r = EventEnquiryResult.fromJson({
        'contact_name': ' Caroline Whitmore ',
        'contact_email': 'caroline@example.com',
        'contact_phone': null,
        'event_name': 'Whitmore party',
        'event_date': '2026-12-11',
        'start_time': '18:00',
        'end_time': '23:00',
        'guest_count': 45,
        'budget_usd': '3,000',
        'requested_items': ['Buffet', 'Open bar till 11'],
        'uncertain': ['event_name', 'Guest_Count'],
        'missing': ['Dietary needs'],
      });
      expect(r.contactName, 'Caroline Whitmore');
      expect(r.contactPhone, isNull);
      expect(r.eventDate, DateTime.utc(2026, 12, 11));
      expect(r.startMinutes, 18 * 60);
      expect(r.endMinutes, 23 * 60);
      expect(r.guestCount, 45);
      expect(r.budgetUsd, 3000);
      expect(r.requestedItems, ['Buffet', 'Open bar till 11']);
      expect(r.uncertain, {'event_name', 'guest_count'});
      expect(r.missing, ['Dietary needs']);
    });

    test('tolerates an empty object and wrong types', () {
      final empty = EventEnquiryResult.fromJson({});
      expect(empty.contactName, isNull);
      expect(empty.requestedItems, isEmpty);
      expect(empty.uncertain, isEmpty);

      final r = EventEnquiryResult.fromJson({
        'contact_name': 5,
        'guest_count': 'lots',
        'requested_items': 'buffet',
        'missing': {'a': 1},
        'uncertain': 'x',
        'surprise': [1, 2],
      });
      expect(r.contactName, isNull);
      expect(r.guestCount, isNull);
      expect(r.requestedItems, isEmpty);
      expect(r.missing, isEmpty);
    });

    test('rejects malformed values and flags them uncertain', () {
      final r = EventEnquiryResult.fromJson({
        'contact_email': 'not an email',
        'event_date': '2026-02-31',
        'start_time': '25:00',
        'end_time': '7pm',
      });
      expect(r.contactEmail, isNull);
      expect(r.eventDate, isNull);
      expect(r.startMinutes, isNull);
      expect(r.endMinutes, isNull);
      expect(
        r.uncertain,
        {'contact_email', 'event_date', 'start_time', 'end_time'},
      );
    });

    test('clamps guests and budget', () {
      expect(
        EventEnquiryResult.fromJson({'guest_count': 0}).guestCount,
        1,
      );
      expect(
        EventEnquiryResult.fromJson({'guest_count': 9999999}).guestCount,
        10000,
      );
      expect(
        EventEnquiryResult.fromJson({'guest_count': 45.6}).guestCount,
        46,
      );
      expect(EventEnquiryResult.fromJson({'budget_usd': -5}).budgetUsd, isNull);
      expect(
        EventEnquiryResult.fromJson({'budget_usd': 1e12}).budgetUsd,
        10000000,
      );
      expect(
        EventEnquiryResult.fromJson({'budget_usd': double.nan}).budgetUsd,
        isNull,
      );
    });
  });
}

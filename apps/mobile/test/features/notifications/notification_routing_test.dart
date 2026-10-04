import 'package:flutter_test/flutter_test.dart';
import 'package:venuewrangler_mobile/features/notifications/application/notification_routing.dart';

void main() {
  test('maps known notification kinds to their destination route', () {
    expect(routeForNotificationKind('shift_assigned'), '/schedules');
    expect(routeForNotificationKind('shift_swap'), '/schedules');
    expect(routeForNotificationKind('late_clock_in'), '/time-clock');
    expect(routeForNotificationKind('staff_request'), '/staff-requests');
  });

  test('returns null for announcement and unknown kinds', () {
    expect(routeForNotificationKind('announcement'), isNull);
    expect(routeForNotificationKind('something_new'), isNull);
    expect(routeForNotificationKind(''), isNull);
  });
}

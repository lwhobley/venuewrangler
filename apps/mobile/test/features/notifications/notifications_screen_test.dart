import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:venuewrangler_mobile/features/notifications/application/notifications_providers.dart';
import 'package:venuewrangler_mobile/features/notifications/data/notifications_repository.dart';
import 'package:venuewrangler_mobile/features/notifications/domain/notification_event.dart';
import 'package:venuewrangler_mobile/features/notifications/presentation/notifications_screen.dart';
import 'package:venuewrangler_mobile/features/venues/application/venues_providers.dart';
import 'package:venuewrangler_mobile/features/venues/domain/venue.dart';

class _FakeNotificationsRepository implements NotificationsRepository {
  _FakeNotificationsRepository({List<NotificationEvent>? initial})
      : notifications = initial ?? [];

  List<NotificationEvent> notifications;
  bool markAsReadCalled = false;
  bool markAllAsReadCalled = false;
  String? lastReadId;

  @override
  Future<String> registerPushToken({
    required String venueId,
    required String token,
    required String platform,
  }) async =>
      'token-uuid';

  @override
  Future<List<NotificationEvent>> getNotifications({
    required String venueId,
    int limit = 50,
  }) async =>
      notifications;

  @override
  Future<void> markAsRead({required String notificationId}) async {
    markAsReadCalled = true;
    lastReadId = notificationId;
    final idx = notifications.indexWhere((n) => n.id == notificationId);
    if (idx != -1) {
      final old = notifications[idx];
      notifications[idx] = NotificationEvent(
        id: old.id,
        organizationId: old.organizationId,
        venueId: old.venueId,
        targetUserId: old.targetUserId,
        audience: old.audience,
        kind: old.kind,
        title: old.title,
        body: old.body,
        data: old.data,
        readAt: DateTime.now(),
        createdAt: old.createdAt,
      );
    }
  }

  @override
  Future<void> markAllAsRead({required String venueId}) async {
    markAllAsReadCalled = true;
    notifications = notifications
        .map(
          (n) => NotificationEvent(
            id: n.id,
            organizationId: n.organizationId,
            venueId: n.venueId,
            targetUserId: n.targetUserId,
            audience: n.audience,
            kind: n.kind,
            title: n.title,
            body: n.body,
            data: n.data,
            readAt: DateTime.now(),
            createdAt: n.createdAt,
          ),
        )
        .toList();
  }
}

void main() {
  final testVenue = Venue(
    id: 'venue-1',
    organizationId: 'org-1',
    name: 'Venue 1',
    createdAt: DateTime.now(),
  );

  testWidgets('renders empty notification state when list is empty',
      (tester) async {
    final fakeRepo = _FakeNotificationsRepository(initial: []);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeVenueProvider.overrideWith((ref) => testVenue),
          notificationsRepositoryProvider.overrideWithValue(fakeRepo),
        ],
        child: const MaterialApp(home: NotificationsScreen()),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('Notifications'), findsOneWidget);
    expect(find.text('No notifications yet'), findsOneWidget);
  });

  testWidgets('renders notifications feed and marks item as read on tap',
      (tester) async {
    final fakeRepo = _FakeNotificationsRepository(
      initial: [
        NotificationEvent(
          id: 'n-1',
          organizationId: 'org-1',
          venueId: 'venue-1',
          audience: 'user',
          kind: 'shift_assigned',
          title: 'Shift Scheduled',
          body: 'You are scheduled for Friday night.',
          createdAt: DateTime.now().subtract(const Duration(minutes: 5)),
        ),
      ],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeVenueProvider.overrideWith((ref) => testVenue),
          notificationsRepositoryProvider.overrideWithValue(fakeRepo),
        ],
        child: const MaterialApp(home: NotificationsScreen()),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('Shift Scheduled'), findsOneWidget);
    expect(find.text('You are scheduled for Friday night.'), findsOneWidget);

    // Tap notification to mark read
    await tester.tap(find.text('Shift Scheduled'));
    await tester.pumpAndSettle();

    expect(fakeRepo.markAsReadCalled, isTrue);
    expect(fakeRepo.lastReadId, 'n-1');
  });

  testWidgets(
      'tapping a notification with a mapped kind navigates to its route',
      (tester) async {
    final fakeRepo = _FakeNotificationsRepository(
      initial: [
        NotificationEvent(
          id: 'n-1',
          organizationId: 'org-1',
          venueId: 'venue-1',
          audience: 'user',
          kind: 'staff_request',
          title: 'New staff request',
          body: 'A time-off request needs review.',
          readAt: DateTime.now().subtract(const Duration(days: 1)),
          createdAt: DateTime.now().subtract(const Duration(days: 1)),
        ),
      ],
    );

    final router = GoRouter(
      initialLocation: '/notifications',
      routes: [
        GoRoute(
          path: '/notifications',
          builder: (context, state) => const NotificationsScreen(),
        ),
        GoRoute(
          path: '/staff-requests',
          builder: (context, state) => const Text('Staff Requests Page'),
        ),
      ],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeVenueProvider.overrideWith((ref) => testVenue),
          notificationsRepositoryProvider.overrideWithValue(fakeRepo),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('New staff request'));
    await tester.pumpAndSettle();

    expect(find.text('Staff Requests Page'), findsOneWidget);
    // Already read in the fixture above — tapping it must not call markAsRead again.
    expect(fakeRepo.markAsReadCalled, isFalse);
  });

  testWidgets('mark all as read button triggers markAllAsRead', (tester) async {
    final fakeRepo = _FakeNotificationsRepository(
      initial: [
        NotificationEvent(
          id: 'n-1',
          organizationId: 'org-1',
          venueId: 'venue-1',
          audience: 'user',
          kind: 'shift_assigned',
          title: 'Shift 1',
          body: 'Details 1',
          createdAt: DateTime.now(),
        ),
      ],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeVenueProvider.overrideWith((ref) => testVenue),
          notificationsRepositoryProvider.overrideWithValue(fakeRepo),
        ],
        child: const MaterialApp(home: NotificationsScreen()),
      ),
    );

    await tester.pumpAndSettle();

    final markAllButton = find.byTooltip('Mark all as read');
    expect(markAllButton, findsOneWidget);

    await tester.tap(markAllButton);
    await tester.pumpAndSettle();

    expect(fakeRepo.markAllAsReadCalled, isTrue);
  });
}

/// Maps a notification's `kind` to the app route it should open, for both an in-app tap on
/// `NotificationsScreen` and a push notification tap (foreground, background, or cold-launch —
/// see `PushNotificationsPlugin.swift`'s header comment). Returns null for kinds with no more
/// specific destination than the notifications list itself (e.g. `announcement`, or any kind
/// not yet known here).
String? routeForNotificationKind(String kind) {
  switch (kind) {
    case 'shift_assigned':
    case 'shift_swap':
      return '/schedules';
    case 'late_clock_in':
      return '/time-clock';
    case 'staff_request':
      return '/staff-requests';
    default:
      return null;
  }
}

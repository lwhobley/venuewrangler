import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/venue_clock.dart';

/// A warning strip shown above any screen that reads or writes venue times when the venue's time
/// zone is not one the app can convert (see [VenueClock.isSupported]). Renders nothing otherwise.
class UnsupportedTimezoneBanner extends ConsumerWidget {
  const UnsupportedTimezoneBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final clock = ref.watch(venueClockProvider);
    if (clock.isSupported) return const SizedBox.shrink();
    return MaterialBanner(
      key: const ValueKey('unsupported-timezone-banner'),
      backgroundColor: Theme.of(context).colorScheme.errorContainer,
      leading: const Icon(Icons.public_off_outlined),
      content: Text(
        "This venue's time zone (${clock.timezoneId}) isn't supported by the "
        'app yet. Times shown may be wrong and new times cannot be saved.',
      ),
      actions: const [SizedBox.shrink()],
    );
  }
}

/// Picks a date then a time in the venue's wall clock. [initial] and the result are wall times
/// (UTC-flagged `DateTime`s whose fields are the venue's clock), and the selectable range is
/// measured on the venue's calendar, not the device's.
Future<DateTime?> pickVenueDateTime(
  BuildContext context, {
  required DateTime initial,
  required DateTime nowWall,
  int daysBack = 1,
  int daysForward = 365,
}) async {
  DateTime day(DateTime t) => DateTime(t.year, t.month, t.day);
  final first = day(nowWall.subtract(Duration(days: daysBack)));
  final last = day(nowWall.add(Duration(days: daysForward)));
  var initialDay = day(initial);
  if (initialDay.isBefore(first)) initialDay = first;
  if (initialDay.isAfter(last)) initialDay = last;

  final date = await showDatePicker(
    context: context,
    initialDate: initialDay,
    firstDate: first,
    lastDate: last,
  );
  if (date == null || !context.mounted) return null;

  final time = await showTimePicker(
    context: context,
    initialTime: TimeOfDay(hour: initial.hour, minute: initial.minute),
  );
  if (time == null) return null;

  return DateTime.utc(date.year, date.month, date.day, time.hour, time.minute);
}

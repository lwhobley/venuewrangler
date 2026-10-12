import 'package:flutter/foundation.dart';

/// Utilities for translating UTC instants into venue wall-clock time and business days.
/// Handles standard Daylight Saving Time (DST) rules for supported IANA timezones.
class VenueTimezone {
  const VenueTimezone._();

  /// Unknown ids already reported, so each one is logged once rather than on every format.
  static final Set<String> _unknownZonesLogged = <String>{};

  /// Standard offsets from UTC (in hours) without daylight saving.
  static const Map<String, int> _standardOffsetsHours = {
    'UTC': 0,
    'America/New_York': -5,
    'America/Chicago': -6,
    'America/Denver': -7,
    'America/Phoenix': -7, // No DST
    'America/Los_Angeles': -8,
    'America/Anchorage': -9,
    'Pacific/Honolulu': -10, // No DST
    'Europe/London': 0,
    'Europe/Paris': 1,
    'Australia/Sydney': 10,
  };

  /// Returns the offset for [timezoneId] at the given UTC [instant] (defaults to now).
  static Duration offsetFor(String timezoneId, [DateTime? instant]) {
    final utc = instant?.toUtc() ?? DateTime.now().toUtc();
    final stdOffset = _standardOffsetFor(timezoneId);
    if (stdOffset == null) {
      // Fallback: if unrecognized timezone, default to UTC
      return Duration.zero;
    }

    final isDst = _isDaylightSaving(timezoneId, utc);
    final hours = stdOffset + (isDst ? 1 : 0);
    return Duration(hours: hours);
  }

  /// Converts a UTC instant to a venue wall-clock [DateTime].
  /// Note: The returned [DateTime] has `isUtc == true` so that local device timezone
  /// transitions do not tamper with the venue's hour/minute values.
  static DateTime toVenueTime(DateTime instant, String timezoneId) {
    final utc = instant.toUtc();
    final offset = offsetFor(timezoneId, utc);
    final shifted = utc.add(offset);
    return DateTime.utc(
      shifted.year,
      shifted.month,
      shifted.day,
      shifted.hour,
      shifted.minute,
      shifted.second,
      shifted.millisecond,
    );
  }

  /// Converts a venue wall-clock [DateTime] back to a UTC instant.
  ///
  /// The offset in force depends on the instant being looked for, so each candidate is checked
  /// against the offset it was computed with (round trip):
  /// - Daylight candidate valid: the wall time occurs during DST (or, in a fall-back overlap,
  ///   both candidates are valid and the earlier, daylight, instant is chosen).
  /// - Otherwise the wall time is in a spring-forward gap, which resolves with the standard
  ///   offset (the way a clock jumping forward would read it).
  static DateTime toUtc(DateTime venueTime, String timezoneId) {
    final wall = DateTime.utc(
      venueTime.year,
      venueTime.month,
      venueTime.day,
      venueTime.hour,
      venueTime.minute,
      venueTime.second,
      venueTime.millisecond,
    );
    final stdHours = _standardOffsetFor(timezoneId);
    if (stdHours == null) return wall; // Unknown zone: UTC fallback.

    final standard = Duration(hours: stdHours);
    final daylight = Duration(hours: stdHours + 1);
    final daylightCandidate = wall.subtract(daylight);
    if (offsetFor(timezoneId, daylightCandidate) == daylight) {
      return daylightCandidate;
    }
    return wall.subtract(standard);
  }

  /// Returns the current wall-clock date and time at the venue.
  static DateTime venueNow(String timezoneId) =>
      toVenueTime(DateTime.now().toUtc(), timezoneId);

  /// Calculates the venue business date (date at midnight) for [instant].
  /// Hours prior to [startHour] (default 6 AM) are attributed to the previous calendar day.
  static DateTime businessDateFor(
    DateTime instant,
    String timezoneId, {
    int startHour = 6,
  }) {
    final vt = toVenueTime(instant, timezoneId);
    final d = DateTime.utc(vt.year, vt.month, vt.day);
    return vt.hour < startHour ? DateTime.utc(d.year, d.month, d.day - 1) : d;
  }

  /// Returns start (inclusive) and end (exclusive) UTC instants for a venue business day.
  static ({DateTime startUtc, DateTime endUtc}) businessDayRange(
    DateTime date,
    String timezoneId, {
    int startHour = 6,
  }) {
    final startVenue = DateTime.utc(date.year, date.month, date.day, startHour);
    final endVenue = startVenue.add(const Duration(hours: 24));
    return (
      startUtc: toUtc(startVenue, timezoneId),
      endUtc: toUtc(endVenue, timezoneId),
    );
  }

  /// Formats the time portion (e.g., "7:00 PM" or "11:30 AM").
  static String formatTime(DateTime instant, String timezoneId) {
    final vt = toVenueTime(instant, timezoneId);
    final h24 = vt.hour;
    final h12 = h24 == 0 ? 12 : (h24 > 12 ? h24 - 12 : h24);
    final ampm = h24 >= 12 ? 'PM' : 'AM';
    final minuteStr = vt.minute.toString().padLeft(2, '0');
    return '$h12:$minuteStr $ampm';
  }

  /// Formats the short date (e.g., "Oct 10, 2026").
  static String formatShortDate(DateTime instant, String timezoneId) {
    final vt = toVenueTime(instant, timezoneId);
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${months[vt.month - 1]} ${vt.day}, ${vt.year}';
  }

  /// Formats day and date (e.g., "Friday, Oct 10").
  static String formatDayAndDate(DateTime instant, String timezoneId) {
    final vt = toVenueTime(instant, timezoneId);
    const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final dayName = weekdays[vt.weekday - 1];
    final monthName = months[vt.month - 1];
    return '$dayName, $monthName ${vt.day}';
  }

  /// Standard offset in hours for [timezoneId], or null for an id outside the table (which is
  /// treated as UTC). Logs each unknown id once so a misconfigured venue is visible in debug
  /// output rather than silently shifted.
  static int? _standardOffsetFor(String timezoneId) {
    final hours = _standardOffsetsHours[timezoneId];
    if (hours == null && _unknownZonesLogged.add(timezoneId)) {
      debugPrint(
        'VenueTimezone: unknown timezone "$timezoneId", falling back to UTC.',
      );
    }
    return hours;
  }

  static bool _isDaylightSaving(String timezoneId, DateTime utc) {
    switch (timezoneId) {
      case 'America/New_York':
      case 'America/Chicago':
      case 'America/Denver':
      case 'America/Los_Angeles':
      case 'America/Anchorage':
        return _isUsDst(timezoneId, utc);
      case 'Europe/London':
      case 'Europe/Paris':
        return _isEuDst(utc);
      case 'Australia/Sydney':
        return _isAustraliaDst(utc);
      case 'America/Phoenix':
      case 'Pacific/Honolulu':
      case 'UTC':
      default:
        return false;
    }
  }

  /// US Daylight Saving Time (since 2007): starts at 02:00 local standard time on the 2nd
  /// Sunday of March and ends at 02:00 local daylight time on the 1st Sunday of November.
  /// The UTC instants depend on each zone's standard offset, so they are computed per zone
  /// (e.g. America/Los_Angeles changes at 10:00 UTC in March, not 07:00 UTC).
  static bool _isUsDst(String timezoneId, DateTime utc) {
    final year = utc.year;
    final stdHours = _standardOffsetsHours[timezoneId] ?? 0;

    // 02:00 standard time = 02:00 - stdHours (UTC).
    final marchSecondSunday = _nthSundayOfMonth(year, 3, 2);
    final dstStart = DateTime.utc(year, 3, marchSecondSunday, 2)
        .subtract(Duration(hours: stdHours));

    // 02:00 daylight time = 02:00 - (stdHours + 1) (UTC).
    final novFirstSunday = _nthSundayOfMonth(year, 11, 1);
    final dstEnd = DateTime.utc(year, 11, novFirstSunday, 2)
        .subtract(Duration(hours: stdHours + 1));

    return !utc.isBefore(dstStart) && utc.isBefore(dstEnd);
  }

  /// EU Summer Time: Last Sunday in March to last Sunday in October (01:00 UTC).
  static bool _isEuDst(DateTime utc) {
    final year = utc.year;
    final marchLastSunday = _lastSundayOfMonth(year, 3);
    final dstStart = DateTime.utc(year, 3, marchLastSunday, 1);

    final octLastSunday = _lastSundayOfMonth(year, 10);
    final dstEnd = DateTime.utc(year, 10, octLastSunday, 1);

    return !utc.isBefore(dstStart) && utc.isBefore(dstEnd);
  }

  /// Australia DST: 1st Sunday in October to 1st Sunday in April (16:00 UTC prior day).
  static bool _isAustraliaDst(DateTime utc) {
    final year = utc.year;
    final octFirstSunday = _nthSundayOfMonth(year, 10, 1);
    final dstStart = DateTime.utc(year, 10, octFirstSunday - 1, 16);

    final aprFirstSunday = _nthSundayOfMonth(year, 4, 1);
    final dstEnd = DateTime.utc(year, 4, aprFirstSunday - 1, 16);

    // Southern hemisphere: DST spans calendar year boundary (Oct through Apr)
    if (utc.month >= 10) {
      return !utc.isBefore(dstStart);
    } else if (utc.month <= 4) {
      return utc.isBefore(dstEnd);
    }
    return false;
  }

  static int _nthSundayOfMonth(int year, int month, int n) {
    var count = 0;
    for (var day = 1; day <= 31; day++) {
      final date = DateTime.utc(year, month, day);
      if (date.month != month) break;
      if (date.weekday == DateTime.sunday) {
        count++;
        if (count == n) return day;
      }
    }
    return 1;
  }

  static int _lastSundayOfMonth(int year, int month) {
    var lastSunday = 1;
    for (var day = 1; day <= 31; day++) {
      final date = DateTime.utc(year, month, day);
      if (date.month != month) break;
      if (date.weekday == DateTime.sunday) {
        lastSunday = day;
      }
    }
    return lastSunday;
  }
}

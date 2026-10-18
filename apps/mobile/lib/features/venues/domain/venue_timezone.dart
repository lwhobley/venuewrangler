import 'package:flutter/foundation.dart';

enum _DstRule { none, us, eu, au, nz }

/// Utilities for translating UTC instants into venue wall-clock time and business days.
/// Handles standard Daylight Saving Time (DST) rules for supported IANA timezones.
class VenueTimezone {
  const VenueTimezone._();

  /// Unknown ids already reported, so each one is logged once rather than on every format.
  static final Set<String> _unknownZonesLogged = <String>{};

  /// Zones the app can convert, with their standard (non-daylight) UTC offset in minutes and the
  /// daylight-saving rule they follow. Hand-maintained because the `timezone` package is not a
  /// dependency; a venue whose zone is not here is reported through [isSupported] (the schedule,
  /// event and reservation screens show a warning and refuse to save times) instead of being
  /// silently treated as UTC.
  static const Map<String, ({int stdMinutes, _DstRule rule})> _zones = {
    'UTC': (stdMinutes: 0, rule: _DstRule.none),
    // United States and Canada (same rules since 2007).
    'America/New_York': (stdMinutes: -300, rule: _DstRule.us),
    'America/Chicago': (stdMinutes: -360, rule: _DstRule.us),
    'America/Denver': (stdMinutes: -420, rule: _DstRule.us),
    'America/Los_Angeles': (stdMinutes: -480, rule: _DstRule.us),
    'America/Anchorage': (stdMinutes: -540, rule: _DstRule.us),
    'America/Toronto': (stdMinutes: -300, rule: _DstRule.us),
    'America/Detroit': (stdMinutes: -300, rule: _DstRule.us),
    'America/Halifax': (stdMinutes: -240, rule: _DstRule.us),
    'America/Winnipeg': (stdMinutes: -360, rule: _DstRule.us),
    'America/Edmonton': (stdMinutes: -420, rule: _DstRule.us),
    'America/Vancouver': (stdMinutes: -480, rule: _DstRule.us),
    // No daylight saving.
    'America/Phoenix': (stdMinutes: -420, rule: _DstRule.none),
    'Pacific/Honolulu': (stdMinutes: -600, rule: _DstRule.none),
    'America/Mexico_City': (stdMinutes: -360, rule: _DstRule.none),
    'America/Bogota': (stdMinutes: -300, rule: _DstRule.none),
    'America/Lima': (stdMinutes: -300, rule: _DstRule.none),
    'America/Sao_Paulo': (stdMinutes: -180, rule: _DstRule.none),
    'America/Argentina/Buenos_Aires': (stdMinutes: -180, rule: _DstRule.none),
    'Africa/Johannesburg': (stdMinutes: 120, rule: _DstRule.none),
    'Africa/Lagos': (stdMinutes: 60, rule: _DstRule.none),
    'Africa/Nairobi': (stdMinutes: 180, rule: _DstRule.none),
    'Europe/Moscow': (stdMinutes: 180, rule: _DstRule.none),
    'Europe/Istanbul': (stdMinutes: 180, rule: _DstRule.none),
    'Asia/Dubai': (stdMinutes: 240, rule: _DstRule.none),
    'Asia/Kolkata': (stdMinutes: 330, rule: _DstRule.none),
    'Asia/Jakarta': (stdMinutes: 420, rule: _DstRule.none),
    'Asia/Singapore': (stdMinutes: 480, rule: _DstRule.none),
    'Asia/Hong_Kong': (stdMinutes: 480, rule: _DstRule.none),
    'Asia/Shanghai': (stdMinutes: 480, rule: _DstRule.none),
    'Asia/Manila': (stdMinutes: 480, rule: _DstRule.none),
    'Asia/Tokyo': (stdMinutes: 540, rule: _DstRule.none),
    'Asia/Seoul': (stdMinutes: 540, rule: _DstRule.none),
    'Australia/Brisbane': (stdMinutes: 600, rule: _DstRule.none),
    'Australia/Perth': (stdMinutes: 480, rule: _DstRule.none),
    // European Union summer time (all switch at 01:00 UTC).
    'Europe/London': (stdMinutes: 0, rule: _DstRule.eu),
    'Europe/Dublin': (stdMinutes: 0, rule: _DstRule.eu),
    'Europe/Lisbon': (stdMinutes: 0, rule: _DstRule.eu),
    'Europe/Paris': (stdMinutes: 60, rule: _DstRule.eu),
    'Europe/Berlin': (stdMinutes: 60, rule: _DstRule.eu),
    'Europe/Madrid': (stdMinutes: 60, rule: _DstRule.eu),
    'Europe/Rome': (stdMinutes: 60, rule: _DstRule.eu),
    'Europe/Amsterdam': (stdMinutes: 60, rule: _DstRule.eu),
    'Europe/Brussels': (stdMinutes: 60, rule: _DstRule.eu),
    'Europe/Vienna': (stdMinutes: 60, rule: _DstRule.eu),
    'Europe/Zurich': (stdMinutes: 60, rule: _DstRule.eu),
    'Europe/Stockholm': (stdMinutes: 60, rule: _DstRule.eu),
    'Europe/Copenhagen': (stdMinutes: 60, rule: _DstRule.eu),
    'Europe/Oslo': (stdMinutes: 60, rule: _DstRule.eu),
    'Europe/Prague': (stdMinutes: 60, rule: _DstRule.eu),
    'Europe/Warsaw': (stdMinutes: 60, rule: _DstRule.eu),
    'Europe/Budapest': (stdMinutes: 60, rule: _DstRule.eu),
    'Europe/Athens': (stdMinutes: 120, rule: _DstRule.eu),
    'Europe/Helsinki': (stdMinutes: 120, rule: _DstRule.eu),
    // Southern hemisphere.
    'Australia/Sydney': (stdMinutes: 600, rule: _DstRule.au),
    'Australia/Melbourne': (stdMinutes: 600, rule: _DstRule.au),
    'Pacific/Auckland': (stdMinutes: 720, rule: _DstRule.nz),
  };

  /// Whether [timezoneId] is one the app can convert correctly.
  static bool isSupported(String timezoneId) => _zones.containsKey(timezoneId);

  /// Returns the offset for [timezoneId] at the given UTC [instant] (defaults to now).
  static Duration offsetFor(String timezoneId, [DateTime? instant]) {
    final utc = instant?.toUtc() ?? DateTime.now().toUtc();
    final zone = _zoneFor(timezoneId);
    if (zone == null) {
      // Unrecognized zone: UTC, never silently. [_zoneFor] logged it once, and callers are
      // expected to check [isSupported] and warn instead of saving times in this fallback.
      return Duration.zero;
    }

    final isDst = _isDaylightSaving(zone, utc);
    return Duration(minutes: zone.stdMinutes + (isDst ? 60 : 0));
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
    final zone = _zoneFor(timezoneId);
    if (zone == null) {
      // Unknown zone: UTC fallback (see [isSupported]).
      return wall;
    }

    final standard = Duration(minutes: zone.stdMinutes);
    final daylight = Duration(minutes: zone.stdMinutes + 60);
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
    return formatWallTime(toVenueTime(instant, timezoneId));
  }

  /// Format already-converted venue wall-clock fields without shifting again.
  static String formatWallTime(DateTime vt) {
    final h24 = vt.hour;
    final h12 = h24 == 0 ? 12 : (h24 > 12 ? h24 - 12 : h24);
    final ampm = h24 >= 12 ? 'PM' : 'AM';
    final minuteStr = vt.minute.toString().padLeft(2, '0');
    return '$h12:$minuteStr $ampm';
  }

  /// Formats the short date (e.g., "Oct 10, 2026").
  static String formatShortDate(DateTime instant, String timezoneId) {
    return formatWallDate(toVenueTime(instant, timezoneId));
  }

  static String formatWallDate(DateTime vt) {
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

  /// The table entry for [timezoneId], or null for an id outside it (which is treated as UTC).
  /// Logs each unknown id once so a misconfigured venue is visible in debug output.
  static ({int stdMinutes, _DstRule rule})? _zoneFor(String timezoneId) {
    final zone = _zones[timezoneId];
    if (zone == null && _unknownZonesLogged.add(timezoneId)) {
      debugPrint(
        'VenueTimezone: unsupported timezone "$timezoneId", falling back to UTC.',
      );
    }
    return zone;
  }

  static bool _isDaylightSaving(
    ({int stdMinutes, _DstRule rule}) zone,
    DateTime utc,
  ) {
    switch (zone.rule) {
      case _DstRule.us:
        return _isUsDst(zone.stdMinutes, utc);
      case _DstRule.eu:
        return _isEuDst(utc);
      case _DstRule.au:
        return _isAustraliaDst(utc);
      case _DstRule.nz:
        return _isNewZealandDst(utc);
      case _DstRule.none:
        return false;
    }
  }

  /// US Daylight Saving Time (since 2007): starts at 02:00 local standard time on the 2nd
  /// Sunday of March and ends at 02:00 local daylight time on the 1st Sunday of November.
  /// The UTC instants depend on each zone's standard offset, so they are computed per zone
  /// (e.g. America/Los_Angeles changes at 10:00 UTC in March, not 07:00 UTC).
  static bool _isUsDst(int stdMinutes, DateTime utc) {
    final year = utc.year;
    final std = Duration(minutes: stdMinutes);

    // 02:00 standard time = 02:00 - standard offset (UTC).
    final marchSecondSunday = _nthSundayOfMonth(year, 3, 2);
    final dstStart = DateTime.utc(year, 3, marchSecondSunday, 2).subtract(std);

    // 02:00 daylight time = 02:00 - (standard offset + 1h) (UTC).
    final novFirstSunday = _nthSundayOfMonth(year, 11, 1);
    final dstEnd = DateTime.utc(year, 11, novFirstSunday, 2)
        .subtract(std + const Duration(hours: 1));

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

  /// New Zealand: last Sunday in September (02:00 NZST = 14:00 UTC the day before) to the first
  /// Sunday in April (03:00 NZDT = 14:00 UTC the day before).
  static bool _isNewZealandDst(DateTime utc) {
    final year = utc.year;
    final dstStart = DateTime.utc(year, 9, _lastSundayOfMonth(year, 9) - 1, 14);
    final dstEnd = DateTime.utc(year, 4, _nthSundayOfMonth(year, 4, 1) - 1, 14);
    if (utc.month >= 9) return !utc.isBefore(dstStart);
    if (utc.month <= 4) return utc.isBefore(dstEnd);
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

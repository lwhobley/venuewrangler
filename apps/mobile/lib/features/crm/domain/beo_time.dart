import '../../venues/domain/venue_clock.dart';
import '../../venues/domain/venue_timezone.dart';

/// "Fri, Dec 11 7:00 PM": a BEO's start [instant] on the venue's clock, never the device's, so
/// an owner booking from another time zone and the manager at the venue read the same time.
String beoWhenLabel(DateTime instant, VenueClock clock) =>
    '${VenueTimezone.formatDayAndDate(instant, clock.timezoneId)} '
    '${clock.formatTime(instant)}';

/// The default start offered for a new BEO: 6:00 PM on the venue's calendar, 30 days after
/// [nowWall] (the venue's wall time now). A wall time; convert with [VenueClock.instant].
DateTime defaultBeoStartWall(DateTime nowWall) =>
    DateTime.utc(nowWall.year, nowWall.month, nowWall.day + 30, 18);

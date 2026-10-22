import '../../venues/domain/venue_clock.dart';
import 'schedule_timeline.dart';
import 'shift.dart';

const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _months = [
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

/// "Thu Oct 22" on the venue's clock.
String shiftDayLabel(VenueClock clock, Shift shift) {
  final wall = clock.wall(shift.startTime);
  return '${_weekdays[wall.weekday - 1]} ${_months[wall.month - 1]} ${wall.day}';
}

/// "4:30 PM – 10:30 PM" on the venue's clock.
String shiftTimeRangeLabel(VenueClock clock, Shift shift) =>
    '${clock.formatTime(shift.startTime)} – ${clock.formatTime(shift.endTime)}';

/// "Server · patio", or "Shift" when neither is set.
String shiftRoleLabel(Shift shift) {
  final parts = [
    if (shift.roleLabel?.isNotEmpty ?? false) shift.roleLabel!,
    if (shift.section?.isNotEmpty ?? false) shift.section!,
  ];
  return parts.isEmpty ? 'Shift' : parts.join(' · ');
}

/// "Thu Oct 22 Server shift, 4:30 PM – 10:30 PM" — how a swap or request names its shift.
String shiftSentenceLabel(VenueClock clock, Shift shift) =>
    '${shiftDayLabel(clock, shift)} ${shift.roleLabel?.isNotEmpty ?? false ? '${shift.roleLabel} ' : ''}'
    'shift, ${shiftTimeRangeLabel(clock, shift)}';

/// [userId]'s other live shifts that overlap [target] — what taking [target] would clash with.
List<Shift> overlappingShiftsFor(
  Iterable<Shift> shifts,
  String userId,
  Shift target,
) =>
    [
      for (final s in shifts)
        if (s.id != target.id &&
            s.staffId == userId &&
            s.status != ShiftStatus.cancelled &&
            shiftsOverlap(s, target))
          s,
    ];

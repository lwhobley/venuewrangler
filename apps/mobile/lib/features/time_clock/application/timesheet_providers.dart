import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/supabase_providers.dart';
import '../data/timesheet_repository.dart';
import '../domain/timesheet.dart';

final timesheetRepositoryProvider = Provider<TimesheetRepository>(
  (ref) => SupabaseTimesheetRepository(ref.watch(supabaseClientProvider)),
);

/// Who is on the clock at a venue, by name (supervisors and up).
final venueClockBoardProvider = FutureProvider.autoDispose
    .family<List<ClockBoardRow>, String>((ref, venueId) {
  return ref.watch(timesheetRepositoryProvider).fetchClockBoard(venueId);
});

typedef TimesheetQuery = ({String venueId, TimesheetRange range});

/// Punches for the hours review (managers).
final timesheetProvider = FutureProvider.autoDispose
    .family<List<TimesheetEntry>, TimesheetQuery>((ref, query) {
  return ref.watch(timesheetRepositoryProvider).fetchTimesheet(
        venueId: query.venueId,
        from: query.range.from,
        to: query.range.to,
      );
});

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/supabase_providers.dart';
import '../data/schedules_repository.dart';
import '../domain/shift.dart';
import '../../workforce/domain/workforce_models.dart';

final schedulesRepositoryProvider = Provider<SchedulesRepository>((ref) {
  final client = ref.watch(supabaseClientProvider);
  return SupabaseSchedulesRepository(client);
});

final shiftsForVenueProvider =
    FutureProvider.autoDispose.family<List<Shift>, String>((ref, venueId) {
  return ref.watch(schedulesRepositoryProvider).fetchShiftsForVenue(venueId);
});

final scheduleRosterForVenueProvider = FutureProvider.autoDispose
    .family<List<RosterMember>, String>((ref, venueId) async {
  final rows = await ref.watch(supabaseClientProvider).rpc(
    'venue_schedule_roster',
    params: {'p_venue_id': venueId},
  ) as List<dynamic>;
  return rows.cast<Map<String, dynamic>>().map(RosterMember.fromJson).toList();
});

final shiftSwapsForVenueProvider =
    FutureProvider.autoDispose.family<List<ShiftSwap>, String>((ref, venueId) {
  return ref.watch(schedulesRepositoryProvider).fetchSwapsForVenue(venueId);
});

/// Keeps the venue's shifts and swaps fresh while a schedule screen watches this: any realtime
/// change to them (a teammate's swap, another manager's edit) reloads both, debounced so one
/// swap touching two rows reloads once.
final scheduleLiveUpdatesProvider =
    Provider.autoDispose.family<void, String>((ref, venueId) {
  Timer? debounce;
  final sub = ref
      .watch(schedulesRepositoryProvider)
      .watchScheduleChanges(venueId)
      .listen(
    (_) {
      debounce?.cancel();
      debounce = Timer(const Duration(milliseconds: 400), () {
        ref.invalidate(shiftsForVenueProvider(venueId));
        ref.invalidate(shiftSwapsForVenueProvider(venueId));
      });
    },
    // A dropped realtime connection only costs liveness; screens still refresh on save,
    // pull-to-refresh and app resume.
    onError: (Object _) {},
  );
  ref.onDispose(() {
    debounce?.cancel();
    sub.cancel();
  });
});

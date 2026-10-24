import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../chat/application/chat_providers.dart';
import '../../checklists/application/checklists_providers.dart';
import '../../events/application/events_providers.dart';
import '../../guests_reservations/application/guests_reservations_providers.dart';
import '../../incidents/application/incidents_providers.dart';
import '../../inventory/application/inventory_providers.dart';
import '../../schedules/application/schedules_providers.dart';
import '../../tasks/application/tasks_providers.dart';
import '../../time_clock/application/time_clock_providers.dart';
import '../../time_clock/domain/time_entry.dart';
import '../../venues/application/venue_clock.dart';
import '../../venues/application/venues_providers.dart';
import '../domain/handover_facts.dart';

/// The current instant; tests override it to pin "tonight".
final handoverNowProvider =
    Provider<DateTime Function()>((ref) => DateTime.now);

/// Runs one data source; a failure leaves that section unavailable instead of failing the
/// whole handover (a quiet section must never be confused with one that did not load).
Future<T?> _safe<T>(Future<T> Function() load) async {
  try {
    return await load();
  } catch (_) {
    return null;
  }
}

/// Facts for the active venue's current business day. Re-run by invalidating it.
final handoverFactsProvider = FutureProvider.autoDispose<HandoverFacts>((
  ref,
) async {
  final venue = ref.watch(activeVenueProvider);
  if (venue == null) throw StateError('No venue selected.');
  final clock = ref.watch(venueClockProvider);
  final now = ref.read(handoverNowProvider)();
  final range = clock.businessDayRange(clock.businessDate(now));

  final incidents = _safe(
    () =>
        ref.read(incidentsRepositoryProvider).fetchIncidentsForVenue(venue.id),
  );
  final inventory = _safe(
    () => ref
        .read(inventoryRepositoryProvider)
        .fetchSnapshot(venue.id, venue.organizationId),
  );
  final tasks = _safe(
    () => ref.read(tasksRepositoryProvider).fetchTasksForVenue(venue.id),
  );
  final templates = _safe(
    () =>
        ref.read(checklistsRepositoryProvider).fetchTemplatesForVenue(venue.id),
  );
  final completed = _safe(
    () => ref
        .read(checklistsRepositoryProvider)
        .fetchCompletedTemplateIdsSince(venue.id, range.startUtc),
  );
  final entries = _safe(() async {
    final repo = ref.read(timeClockRepositoryProvider);
    final inWindow = await repo.getVenueEntriesInRange(
      venueId: venue.id,
      from: range.startUtc,
      to: range.endUtc,
    );
    final open = await repo.getVenueEntries(venueId: venue.id);
    final byId = <String, TimeEntry>{
      for (final e in [...open, ...inWindow]) e.id: e,
    };
    return byId.values.toList(growable: false);
  });
  final shifts = _safe(
    () => ref.read(schedulesRepositoryProvider).fetchShiftsForVenue(venue.id),
  );
  final events = _safe(
    () => ref.read(eventsRepositoryProvider).fetchEventsForVenue(venue.id),
  );
  final reservations = _safe(
    () => ref.read(guestsReservationsRepositoryProvider).getReservations(
          venueId: venue.id,
          from: range.startUtc,
          to: range.endUtc,
        ),
  );
  final roster = _safe(
    () => ref.read(scheduleRosterForVenueProvider(venue.id).future),
  );

  final people = await roster ?? const [];
  return HandoverFacts.gather(
    HandoverInputs(
      clock: clock,
      now: now,
      incidents: await incidents,
      inventory: await inventory,
      tasks: await tasks,
      templates: await templates,
      completedTemplateIds: await completed,
      entries: await entries,
      shifts: await shifts,
      events: await events,
      reservations: await reservations,
      staffNames: {
        for (final p in people)
          if (p.displayName != null && p.displayName!.trim().isNotEmpty)
            p.userId: p.displayName!.trim(),
      },
    ),
  );
});

/// Posts [text] to the venue's All Staff conversation. Throws [StateError] when the venue has
/// no such conversation.
Future<void> postHandoverToAllStaff(
  WidgetRef ref, {
  required String venueId,
  required String text,
}) async {
  final repo = ref.read(chatRepositoryProvider);
  final conversations = await repo.getConversations(venueId: venueId);
  final allStaff =
      conversations.where((c) => c.type == 'all_staff').firstOrNull;
  if (allStaff == null) {
    throw StateError('This venue has no All Staff chat.');
  }
  await repo.sendMessage(conversationId: allStaff.id, text: text);
}

import 'package:venuewrangler_mobile/features/checklists/domain/checklist_template.dart';
import 'package:venuewrangler_mobile/features/events/domain/event.dart';
import 'package:venuewrangler_mobile/features/guests_reservations/domain/reservation.dart';
import 'package:venuewrangler_mobile/features/handover/domain/handover_facts.dart';
import 'package:venuewrangler_mobile/features/incidents/domain/incident.dart';
import 'package:venuewrangler_mobile/features/inventory/domain/inventory_item.dart';
import 'package:venuewrangler_mobile/features/inventory/domain/inventory_v2.dart';
import 'package:venuewrangler_mobile/features/schedules/domain/shift.dart';
import 'package:venuewrangler_mobile/features/tasks/domain/operational_task.dart';
import 'package:venuewrangler_mobile/features/time_clock/domain/time_entry.dart';
import 'package:venuewrangler_mobile/features/venues/domain/venue_clock.dart';

/// Saturday night at a UTC venue: the business day runs 06:00 Oct 24 to 06:00 Oct 25.
final handoverNow = DateTime.utc(2026, 10, 25, 0, 30);
const handoverClock = VenueClock('UTC');

Incident incident(
  String id,
  String title,
  IncidentSeverity severity, {
  IncidentStatus status = IncidentStatus.open,
  DateTime? at,
}) =>
    Incident(
      id: id,
      venueId: 'v',
      organizationId: 'o',
      title: title,
      severity: severity,
      status: status,
      createdAt: at ?? DateTime.utc(2026, 10, 24, 21),
    );

OperationalTask task(
  String id,
  String title, {
  TaskStatus status = TaskStatus.open,
  DateTime? due,
}) =>
    OperationalTask(
      id: id,
      venueId: 'v',
      organizationId: 'o',
      title: title,
      status: status,
      dueAt: due,
      createdAt: DateTime.utc(2026, 10, 20),
      updatedAt: DateTime.utc(2026, 10, 20),
    );

TimeEntry entry(
  String id,
  String userId,
  DateTime clockIn, {
  DateTime? clockOut,
  bool open = false,
  String? shiftId,
}) =>
    TimeEntry(
      id: id,
      organizationId: 'o',
      venueId: 'v',
      userId: userId,
      shiftId: shiftId,
      clockInAt: clockIn,
      clockOutAt: clockOut,
      isOpen: open,
      createdAt: clockIn,
      updatedAt: clockIn,
    );

Shift shift(
  String id,
  String? staff,
  DateTime start,
  DateTime end, {
  ShiftStatus status = ShiftStatus.scheduled,
}) =>
    Shift(
      id: id,
      venueId: 'v',
      staffId: staff,
      startTime: start,
      endTime: end,
      status: status,
    );

Reservation reservation(
  String id,
  DateTime at,
  int party, {
  String status = 'confirmed',
  String? beoId,
}) =>
    Reservation(
      id: id,
      organizationId: 'o',
      venueId: 'v',
      guestName: 'Secret Guest $id',
      guestPhone: '555-0100',
      partySize: party,
      reservationTime: at,
      status: status,
      beoId: beoId,
      createdAt: at,
      updatedAt: at,
    );

VenueEvent event(
  String id,
  String name,
  DateTime start,
  DateTime end, {
  EventStatus status = EventStatus.confirmed,
}) =>
    VenueEvent(
      id: id,
      venueId: 'v',
      name: name,
      startTime: start,
      endTime: end,
      status: status,
    );

InventorySnapshot stockSnapshot() {
  Map<String, dynamic> item(String id, String name) => {
        'id': id,
        'venue_id': 'v',
        'name': name,
        'updated_at': '2026-10-01T00:00:00Z',
      };
  Map<String, dynamic> stock(String id, String itemId, num qty, num par) => {
        'id': id,
        'inventory_item_id': itemId,
        'area_id': 'bar',
        'quantity': qty,
        'par_level': par,
      };
  return InventorySnapshot(
    items: [
      InventoryItem.fromJson(item('i1', 'Tito\'s Vodka')),
      InventoryItem.fromJson(item('i2', 'Limes')),
      InventoryItem.fromJson(item('i3', 'Napkins')),
    ],
    categories: const [],
    subcategories: const [],
    areas: [
      InventoryArea.fromJson({'id': 'bar', 'name': 'Bar', 'is_active': true}),
    ],
    subAreas: const [],
    stock: [
      InventoryStock.fromJson(stock('s1', 'i1', 0, 4)),
      InventoryStock.fromJson(stock('s2', 'i2', 1, 5)),
      InventoryStock.fromJson(stock('s3', 'i3', 50, 20)),
    ],
    counts: const [],
    history: const [],
  );
}

/// A busy night with something in every section.
HandoverFacts busyFacts() => HandoverFacts.gather(
      HandoverInputs(
        clock: handoverClock,
        now: handoverNow,
        incidents: [
          incident('1', 'Spill near stage', IncidentSeverity.low),
          incident('2', 'Fight at the bar', IncidentSeverity.high),
        ],
        inventory: stockSnapshot(),
        tasks: [
          task('t1', 'Deep clean fryer', due: DateTime.utc(2026, 10, 24, 22)),
          task('t2', 'Order limes'),
        ],
        templates: const [
          ChecklistTemplate(id: 'c1', venueId: 'v', title: 'Closing checklist'),
          ChecklistTemplate(id: 'c2', venueId: 'v', title: 'Opening checklist'),
        ],
        completedTemplateIds: {'c2'},
        entries: [
          entry(
            'e1',
            'u1',
            DateTime.utc(2026, 10, 24, 17),
            open: true,
            shiftId: 's1',
          ),
        ],
        shifts: [
          shift(
            's1',
            'u1',
            DateTime.utc(2026, 10, 24, 17),
            DateTime.utc(2026, 10, 24, 23),
          ),
        ],
        events: [
          event(
            'ev1',
            'Whitmore party',
            DateTime.utc(2026, 10, 24, 19),
            DateTime.utc(2026, 10, 24, 23),
          ),
        ],
        reservations: [
          reservation('r1', DateTime.utc(2026, 10, 24, 19, 30), 12),
          reservation('r2', DateTime.utc(2026, 10, 24, 20), 2),
        ],
        staffNames: const {'u1': 'Maya Lopez'},
      ),
    );
